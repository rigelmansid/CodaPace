import Foundation
import CodaPaceCore

// 全部用固定时区 + 固定时刻,保证在任何机器上结果一致
private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

private func makeDate(_ y: Int, _ mo: Int, _ d: Int,
                      _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0,
                      tz: TimeZone = shanghai) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    return cal.date(from: DateComponents(year: y, month: mo, day: d,
                                         hour: h, minute: mi, second: s))!
}

// MARK: - 时间窗口

final class TimeWindowTests: XCTestCase {

    func testElapsedAndRemainingRatio() {
        let start = makeDate(2026, 9, 8, 0, 0)
        let end = makeDate(2026, 9, 9, 0, 0)
        let w = TimeWindow(start: start, end: end)

        XCTAssertEqual(w.duration, 86400, accuracy: 0.001)
        XCTAssertEqual(w.elapsedRatio(now: makeDate(2026, 9, 8, 12, 0)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(w.remainingRatio(now: makeDate(2026, 9, 8, 12, 0)), 0.5, accuracy: 1e-9)
    }

    func testRatiosAreClampedOutsideTheWindow() {
        let w = TimeWindow(start: makeDate(2026, 9, 8, 0, 0), end: makeDate(2026, 9, 9, 0, 0))

        // 窗口之前
        XCTAssertEqual(w.elapsedRatio(now: makeDate(2026, 9, 7, 12, 0)), 0, accuracy: 1e-9)
        // 窗口之后
        XCTAssertEqual(w.elapsedRatio(now: makeDate(2026, 9, 10, 0, 0)), 1, accuracy: 1e-9)
        XCTAssertEqual(w.remainingSeconds(now: makeDate(2026, 9, 10, 0, 0)), 0, accuracy: 1e-9)
    }

    func testZeroDurationDoesNotDivideByZero() {
        let t = makeDate(2026, 9, 8)
        let w = TimeWindow(start: t, end: t)
        XCTAssertEqual(w.elapsedRatio(now: t), 0, accuracy: 1e-12)
        XCTAssertEqual(w.remainingRatio(now: t), 1, accuracy: 1e-12)
    }
}

// MARK: - 消费速度

final class PaceTests: XCTestCase {

    /// 复现实测数据:限流窗口 1 小时、上限 $20、已用 $3.80、剩 1317 秒
    /// 额度剩 81%,时间剩 36.6% → 明显没超速
    func testRealWorldWindowIsOnPace() {
        let start = makeDate(2026, 9, 8, 0, 5)
        let end = start.addingTimeInterval(3600)
        let now = end.addingTimeInterval(-1317)

        let g = Gauge(kind: .window, used: 3.80129775, limit: 20,
                      window: TimeWindow(start: start, end: end))

        XCTAssertEqual(g.remainingRatio, 0.8099, accuracy: 0.001)

        guard case .onPace(let delta) = g.pace(now: now) else {
            return XCTFail("应判定为正常速度")
        }
        XCTAssertEqual(delta, 0.8099 - 1317.0 / 3600.0, accuracy: 0.001)
        XCTAssertEqual(g.status(now: now), .normal)
    }

    func testOverPaceWhenQuotaDropsFasterThanTime() {
        let start = makeDate(2026, 9, 8, 0, 0)
        let end = start.addingTimeInterval(3600)
        let now = start.addingTimeInterval(1800)      // 时间过半

        // 时间才过一半,额度已经用掉 70% → 超速。
        // 剩余 30% 仍高于 20% 的危险线,所以状态应停在 warning 而不是 critical。
        let g = Gauge(kind: .window, used: 70, limit: 100,
                      window: TimeWindow(start: start, end: end))

        guard case .overPace(let delta) = g.pace(now: now) else {
            return XCTFail("应判定为超速")
        }
        XCTAssertEqual(delta, 0.3 - 0.5, accuracy: 1e-9)
        XCTAssertEqual(g.status(now: now), .warning)
    }

    /// 关键规则:没有时间窗口就不做速度判断,绝不臆造
    func testNoWindowMeansNoPaceVerdict() {
        let g = Gauge(kind: .total, used: 2432.69, limit: 3000, window: nil)
        XCTAssertEqual(g.pace(now: makeDate(2026, 9, 8)), .unavailable)
    }

    func testUnlimitedGaugeHasNoPaceAndIsNeverCritical() {
        let start = makeDate(2026, 9, 8, 0, 0)
        let g = Gauge(kind: .daily, used: 500, limit: 0,
                      window: TimeWindow(start: start, end: start.addingTimeInterval(86400)))

        XCTAssertTrue(g.unlimited)
        XCTAssertEqual(g.pace(now: start), .unavailable)
        XCTAssertEqual(g.status(now: start), .normal)
    }

    /// 颜色优先级:剩余不足要盖过超速
    func testCriticalOutranksOverPace() {
        let start = makeDate(2026, 9, 8, 0, 0)
        let end = start.addingTimeInterval(3600)
        let now = start.addingTimeInterval(60)        // 时间才过 1.7%

        // 剩余 5% —— 既超速又吃紧,应判为 critical
        let g = Gauge(kind: .window, used: 95, limit: 100,
                      window: TimeWindow(start: start, end: end))

        XCTAssertTrue(g.pace(now: now).isOverPace)
        XCTAssertEqual(g.status(now: now), .critical)
    }

    func testRemainingAndUsedRatioAreClamped() {
        // 超额使用不应产生负剩余或 >1 的比例
        let g = Gauge(kind: .daily, used: 150, limit: 100)
        XCTAssertEqual(g.usedRatio, 1, accuracy: 1e-12)
        XCTAssertEqual(g.remainingRatio, 0, accuracy: 1e-12)
        XCTAssertEqual(g.remaining, 0, accuracy: 1e-12)
    }
}

// MARK: - 重置周期推算

final class ResetScheduleTests: XCTestCase {

    func testWindowUsesExactTimestampsWhenPresent() {
        var limits = Limits()
        limits.windowStartTime = 1788797068749
        limits.windowEndTime = 1788800668749

        let schedule = ResetSchedule(timeZone: shanghai)
        let w = schedule.windowInterval(limits: limits, now: makeDate(2026, 9, 8, 0, 30))

        XCTAssertNotNil(w)
        XCTAssertEqual(w!.duration, 3600, accuracy: 0.001)
        XCTAssertFalse(w!.isInferred)
    }

    func testWindowFallsBackToRemainingSeconds() {
        var limits = Limits()
        limits.rateLimitWindow = 60           // 分钟
        limits.windowRemainingSeconds = 1317

        let now = makeDate(2026, 9, 8, 0, 38)
        let w = ResetSchedule(timeZone: shanghai).windowInterval(limits: limits, now: now)

        XCTAssertNotNil(w)
        XCTAssertEqual(w!.duration, 3600, accuracy: 0.001)
        XCTAssertEqual(w!.remainingSeconds(now: now), 1317, accuracy: 0.001)
    }

    func testWindowIsNilWhenNoTimingDataAtAll() {
        let w = ResetSchedule(timeZone: shanghai)
            .windowInterval(limits: Limits(), now: makeDate(2026, 9, 8))
        XCTAssertNil(w)
    }

    /// weeklyResetDay 用服务端 JS getDay() 约定:1 = 周一
    /// 2026-09-08 是周二,上一个周一 00:00 应是 09-07
    func testWeeklyIntervalResolvesToPreviousMonday() {
        var limits = Limits()
        limits.weeklyResetDay = 1
        limits.weeklyResetHour = 0

        let schedule = ResetSchedule(timeZone: shanghai)
        let w = schedule.weeklyInterval(limits: limits, now: makeDate(2026, 9, 8, 12, 0))

        XCTAssertNotNil(w)
        XCTAssertEqual(w!.start, makeDate(2026, 9, 7, 0, 0))
        XCTAssertEqual(w!.end, makeDate(2026, 9, 14, 0, 0))
    }

    func testWeeklyIntervalIsNilWhenFieldsMissing() {
        // Limits() 默认 -1,表示接口没给
        let w = ResetSchedule(timeZone: shanghai)
            .weeklyInterval(limits: Limits(), now: makeDate(2026, 9, 8))
        XCTAssertNil(w)
    }

    func testDailyIntervalSpansLocalMidnightAndIsMarkedInferred() {
        let schedule = ResetSchedule(timeZone: shanghai, dailyResetHour: 0)
        let w = schedule.dailyInterval(now: makeDate(2026, 9, 8, 12, 0))

        XCTAssertNotNil(w)
        XCTAssertEqual(w!.start, makeDate(2026, 9, 8, 0, 0))
        XCTAssertEqual(w!.end, makeDate(2026, 9, 9, 0, 0))
        // 还没从历史里观测到,必须如实标为推断
        XCTAssertTrue(w!.isInferred)
    }

    func testObservedDailyResetHourIsNotMarkedInferred() {
        let schedule = ResetSchedule(timeZone: shanghai,
                                     dailyResetHour: 4,
                                     dailyResetHourIsObserved: true)
        let w = schedule.dailyInterval(now: makeDate(2026, 9, 8, 12, 0))

        XCTAssertEqual(w!.start, makeDate(2026, 9, 8, 4, 0))
        XCTAssertFalse(w!.isInferred)
    }

    /// 边界:此刻正好落在重置时刻上,窗口应从此刻开始,而不是退回前一个周期
    func testNowExactlyOnBoundaryStartsNewWindow() {
        let schedule = ResetSchedule(timeZone: shanghai, dailyResetHour: 0)
        let midnight = makeDate(2026, 9, 8, 0, 0)
        let w = schedule.dailyInterval(now: midnight)

        XCTAssertEqual(w!.start, midnight)
    }
}

// MARK: - 从历史学习日重置时刻

final class DailyResetLearnerTests: XCTestCase {

    func testCounterDroppingSignalsAReset() {
        let before = makeDate(2026, 9, 8, 23, 59, 30)
        let after = makeDate(2026, 9, 9, 0, 0, 30)

        let obs = DailyResetLearner.observe(previous: (value: 42.5, at: before),
                                            current: (value: 0.0, at: after),
                                            timeZone: shanghai)

        XCTAssertEqual(obs?.hour, 0)
        XCTAssertEqual(obs?.uncertainty ?? -1, 60, accuracy: 0.001)
    }

    func testRisingCounterIsNotAReset() {
        let t = makeDate(2026, 9, 8, 10, 0)
        let obs = DailyResetLearner.observe(previous: (value: 10, at: t),
                                            current: (value: 12, at: t.addingTimeInterval(60)),
                                            timeZone: shanghai)
        XCTAssertNil(obs)
    }

    /// 采样间隔太大时,说不准这次下降发生在哪一刻 —— 不予采信
    func testWideSamplingGapIsRejected() {
        let before = makeDate(2026, 9, 8, 22, 0)
        let after = makeDate(2026, 9, 9, 3, 0)

        let obs = DailyResetLearner.observe(previous: (value: 42.5, at: before),
                                            current: (value: 0.0, at: after),
                                            timeZone: shanghai)
        XCTAssertNil(obs)
    }

    func testResetAtNonMidnightHourIsLearned() {
        let before = makeDate(2026, 9, 8, 3, 59, 30)
        let after = makeDate(2026, 9, 8, 4, 0, 30)

        let obs = DailyResetLearner.observe(previous: (value: 9, at: before),
                                            current: (value: 0.1, at: after),
                                            timeZone: shanghai)
        XCTAssertEqual(obs?.hour, 4)
    }
}
