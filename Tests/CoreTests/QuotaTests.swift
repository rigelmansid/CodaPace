import Foundation
import CodaPaceCore

/// 造一条额度桶。**跨文件共用**(额度、通知、快照、重置四处的用例都要造桶),
/// 所以不加 private —— 各文件各抄一份迟早会分岔。
///
/// 放在这里而不是 TestSupport.swift:那个文件是可丢弃的测试框架层
/// (文件头写明装了 Xcode 就删掉它),塞进领域代码会让它删不掉。
///
/// 名称和单位给默认值,是因为绝大多数用例只关心 id / 用量 / 上限 ——
/// 让断言那一行保持原来的可读性,不被两个与本例无关的参数撑开。
func bucket(_ id: String, used: Double, limit: Double,
            unit: QuotaUnit = .money(currency: "USD"),
            window: TimeWindow? = nil, rule: ResetRule? = nil) -> QuotaBucket {
    QuotaBucket(id: id, title: .provider(id), used: used, limit: limit,
                unit: unit, window: window, rule: rule)
}

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

        let g = bucket("window", used: 3.80129775, limit: 20,
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
        let g = bucket("window", used: 70, limit: 100,
                      window: TimeWindow(start: start, end: end))

        guard case .overPace(let delta) = g.pace(now: now) else {
            return XCTFail("应判定为超速")
        }
        XCTAssertEqual(delta, 0.3 - 0.5, accuracy: 1e-9)
        XCTAssertEqual(g.status(now: now), .warning)
    }

    /// 关键规则:没有时间窗口就不做速度判断,绝不臆造
    func testNoWindowMeansNoPaceVerdict() {
        let g = bucket("total", used: 2432.69, limit: 3000, window: nil)
        XCTAssertEqual(g.pace(now: makeDate(2026, 9, 8)), .unavailable)
    }

    func testUnlimitedGaugeHasNoPaceAndIsNeverCritical() {
        let start = makeDate(2026, 9, 8, 0, 0)
        let g = bucket("daily", used: 500, limit: 0,
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
        let g = bucket("window", used: 95, limit: 100,
                      window: TimeWindow(start: start, end: end))

        XCTAssertTrue(g.pace(now: now).isOverPace)
        XCTAssertEqual(g.status(now: now), .critical)
    }

    func testRemainingAndUsedRatioAreClamped() {
        // 超额使用不应产生负剩余或 >1 的比例
        let g = bucket("daily", used: 150, limit: 100)
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

// MARK: - 学到的日重置规则:按账户隔离与后续更新

private let newYork = TimeZone(identifier: "America/New_York")!
private let testProvider = "test-provider"

private func observation(hour: Int, uncertainty: TimeInterval = 60) -> DailyResetLearner.Observation {
    // 通过真实的 observe 造观测,避免测试绕开它自己拼一个不可能出现的值
    let after = makeDate(2026, 9, 9, hour, 0, 30)
    let before = after.addingTimeInterval(-uncertainty)
    return DailyResetLearner.observe(previous: (value: 42, at: before),
                                     current: (value: 0.1, at: after),
                                     timeZone: shanghai)!
}

final class LearnedDailyResetTests: XCTestCase {

    /// 本地小时脱离时区没有意义 —— 时区是结论成立的前提
    func testRecordOnlyAppliesInTheZoneItWasLearnedIn() {
        let record = LearnedDailyReset(hour: 4, timeZoneIdentifier: shanghai.identifier,
                                       uncertainty: 60)
        XCTAssertTrue(record.applies(in: shanghai))
        XCTAssertFalse(record.applies(in: newYork))
    }

    func testFirstObservationIsAdopted() {
        let updated = DailyResetLearner.reconcile(stored: nil,
                                                 observation: observation(hour: 4),
                                                 timeZone: shanghai)
        XCTAssertEqual(updated?.hour, 4)
        XCTAssertEqual(updated?.timeZoneIdentifier, shanghai.identifier)
    }

    /// 同一个小时不必反复写盘 —— 每天重置一次就写一次太吵
    func testSameHourNeedsNoWrite() {
        let stored = LearnedDailyReset(hour: 4, timeZoneIdentifier: shanghai.identifier,
                                       uncertainty: 60)
        XCTAssertNil(DailyResetLearner.reconcile(stored: stored,
                                                 observation: observation(hour: 4),
                                                 timeZone: shanghai))
    }

    /// 计数器归零是没有歧义的事件:现在发生在 14 点,重置时刻现在就是 14 点。
    /// 从前学到一次就封存,错了也一直错下去。
    func testContradictingObservationUpdatesTheRule() {
        let stored = LearnedDailyReset(hour: 4, timeZoneIdentifier: shanghai.identifier,
                                       uncertainty: 60)
        let updated = DailyResetLearner.reconcile(stored: stored,
                                                 observation: observation(hour: 14),
                                                 timeZone: shanghai)
        XCTAssertEqual(updated?.hour, 14)
    }

    /// 换了时区,旧结论的前提不成立 —— 直接采纳新观测,不拿旧值算倒计时
    func testTimeZoneChangeDiscardsTheOldRule() {
        let stored = LearnedDailyReset(hour: 4, timeZoneIdentifier: shanghai.identifier,
                                       uncertainty: 60)
        let updated = DailyResetLearner.reconcile(stored: stored,
                                                 observation: observation(hour: 4),
                                                 timeZone: newYork)
        XCTAssertEqual(updated?.timeZoneIdentifier, newYork.identifier)
        XCTAssertEqual(updated?.hour, 4)
    }

    /// 没学到规则时,日窗口必须仍然标注为推算
    func testUnknownRuleKeepsTheInferredMarker() {
        let inferred = ResetSchedule(timeZone: shanghai, dailyResetHour: 0,
                                     dailyResetHourIsObserved: false)
        XCTAssertTrue(inferred.dailyInterval(now: makeDate(2026, 9, 8, 12))!.isInferred)

        let learned = ResetSchedule(timeZone: shanghai, dailyResetHour: 4,
                                    dailyResetHourIsObserved: true)
        XCTAssertFalse(learned.dailyInterval(now: makeDate(2026, 9, 8, 12))!.isInferred)
    }
}

// MARK: - 账户的两个分区键

final class AccountKeyScopeTests: XCTestCase {

    private let a = AccountIdentity(providerID: testProvider, baseURL: "https://a.example.com", apiId: "id-1")

    /// 历史分区键只看 apiId:中继换网址,用量还是同一份,曲线不该被割成两半
    func testStorageKeyIgnoresTheEndpoint() {
        let moved = AccountIdentity(providerID: testProvider, baseURL: "https://b.example.com", apiId: "id-1")
        XCTAssertEqual(a.storageKey, moved.storageKey)
    }

    /// 偏好分区键连网址一起算:「日重置在几点」是那个部署的配置,换地址不能假定照旧
    func testPreferenceKeyDistinguishesTheEndpoint() {
        let moved = AccountIdentity(providerID: testProvider, baseURL: "https://b.example.com", apiId: "id-1")
        XCTAssertFalse(a.preferenceKey == moved.preferenceKey)
    }

    func testPreferenceKeyDistinguishesTheAccount() {
        let other = AccountIdentity(providerID: testProvider, baseURL: a.baseURL, apiId: "id-2")
        XCTAssertFalse(a.preferenceKey == other.preferenceKey)
    }

    func testNeitherKeyLeaksRawCredentials() {
        for key in [a.storageKey, a.preferenceKey] {
            XCTAssertFalse(key.contains("id-1"))
            XCTAssertFalse(key.contains("example.com"))
        }
    }

    /// 单段派生必须和老的 derive(apiId:) 完全一致 ——
    /// 它是历史表的分区键,一变就等于把所有老用户的历史丢掉
    func testSinglePartDeriveMatchesTheLegacyAccountKey() {
        XCTAssertEqual(AccountKey.derive(["id-1"]), AccountKey.derive(apiId: "id-1"))
    }

    /// 用 \n 连接,避免「a+bc 和 ab+c 撞成同一个键」
    func testMultiPartDeriveHasNoConcatenationAmbiguity() {
        XCTAssertFalse(AccountKey.derive(["a", "bc"]) == AccountKey.derive(["ab", "c"]))
    }
}
