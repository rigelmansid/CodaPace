import Foundation
import CodaPaceCore

private let ny = TimeZone(identifier: "America/New_York")!
private let sh = TimeZone(identifier: "Asia/Shanghai")!

private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0,
                _ tz: TimeZone = ny) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = tz
    return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

/// 把一个时刻还原成某时区的 (时, 分)，用来断言「当地几点」而不是绝对秒
private func localTime(_ date: Date, _ tz: TimeZone) -> (hour: Int, minute: Int) {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = tz
    let p = c.dateComponents([.hour, .minute], from: date)
    return (p.hour ?? -1, p.minute ?? -1)
}

private func daily(_ h: Int, _ m: Int = 0, _ tz: TimeZone = ny) -> ResetRule {
    ResetRule(.calendarDaily(timeZone: tz, hour: h, minute: m), provenance: .observed)
}

// MARK: - 自然日与非整点

final class CalendarDailyTests: XCTestCase {

    func testPeriodStartsAtTheConfiguredLocalHour() {
        let w = daily(0).period(containing: at(2026, 6, 15, 13))!
        XCTAssertEqual(w.start, at(2026, 6, 15, 0))
        XCTAssertEqual(w.end, at(2026, 6, 16, 0))
    }

    /// 验收标准点名的「非整点购买时间」:每天当地 14:35 重置
    func testNonIntegerHourResetTime() {
        let rule = daily(14, 35)
        let w = rule.period(containing: at(2026, 6, 15, 20))!
        XCTAssertEqual(w.start, at(2026, 6, 15, 14, 35))
        XCTAssertEqual(w.end, at(2026, 6, 16, 14, 35))

        // 14:35 之前属于前一天那个周期
        let earlier = rule.period(containing: at(2026, 6, 15, 9))!
        XCTAssertEqual(earlier.start, at(2026, 6, 14, 14, 35))
    }

    func testMomentExactlyOnTheBoundaryStartsTheNewPeriod() {
        let w = daily(0).period(containing: at(2026, 6, 15, 0))!
        XCTAssertEqual(w.start, at(2026, 6, 15, 0))
    }
}

// MARK: - 夏令时

/// OPT-011 的场景:纽约 2026-03-08 春季切换日只有 23 小时。
/// 旧实现按 86400 秒往回减,把那天的起点算成当地 01:00。
final class DaylightSavingTests: XCTestCase {

    func testSpringForwardDayIsTwentyThreeHoursButStillStartsAtMidnight() {
        let w = daily(0).period(containing: at(2026, 3, 8, 12))!
        XCTAssertEqual(localTime(w.start, ny).hour, 0)
        XCTAssertEqual(w.duration, 23 * 3600, accuracy: 1)
    }

    func testFallBackDayIsTwentyFiveHoursButStillStartsAtMidnight() {
        let w = daily(0).period(containing: at(2026, 11, 1, 12))!
        XCTAssertEqual(localTime(w.start, ny).hour, 0)
        XCTAssertEqual(w.duration, 25 * 3600, accuracy: 1)
    }

    /// 跨过切换日往回推,每一天的起点都必须仍是当地 0 点
    func testSteppingBackAcrossTheTransitionKeepsTheLocalHour() {
        let rule = daily(0)
        for day in 6...10 {
            let w = rule.period(containing: at(2026, 3, day, 12))!
            XCTAssertEqual(localTime(w.start, ny).hour, 0, "3 月 \(day) 日")
        }
    }

    /// **日历规则与固定时长分道扬镳** —— 正是两者不能混用的原因。
    ///
    /// 注意错位出现在切换日的**次日**:3/8 那段仍从当地 0 点开始(+86400 秒还落在
    /// 切换生效之前),但那一天只有 23 小时,于是下一段固定时长漂到了当地 1 点。
    /// 「每天 0 点」则照旧是 0 点。
    func testCalendarAndFixedDurationDivergeAfterTheTransition() {
        let anchor = at(2026, 3, 7, 0)
        let fixed = ResetRule(.fixedDuration(anchor: anchor, seconds: 86400), provenance: .server)

        let moment = at(2026, 3, 9, 12)
        let calendarStart = daily(0).period(containing: moment)!.start
        let fixedStart = fixed.period(containing: moment)!.start

        XCTAssertEqual(localTime(calendarStart, ny).hour, 0)
        XCTAssertEqual(localTime(fixedStart, ny).hour, 1)
        XCTAssertFalse(calendarStart == fixedStart)
    }

    /// 固定时长本就该不受夏令时影响:每一段都精确 24 小时
    func testFixedDurationKeepsItsExactLengthAcrossTheTransition() {
        let fixed = ResetRule(.fixedDuration(anchor: at(2026, 3, 7, 0), seconds: 86400),
                              provenance: .server)
        XCTAssertEqual(fixed.period(containing: at(2026, 3, 8, 12))!.duration, 86400, accuracy: 0.001)
    }
}

// MARK: - 时区变化

/// OPT-023:周期首尾相接、每个时刻都落在自己的周期里 —— 跨夏令时切换也一样。
///
/// 从前终点是「起点 + 一天」:重置时刻落在跳过的那一小时里(纽约 3/8 的 02:30),
/// 起点被挪到 03:00,终点跟着成了 3/9 03:00,而 3/9 02:30 已经是下一个周期 ——
/// 两个周期重叠半小时。另外为了让「恰好在边界上」返回自己,查询时刻 +1 秒,
/// 于是边界前不到一秒(23:59:59.5)就被算进了下一个周期。
final class CalendarBoundaryTests: XCTestCase {

    /// 逐个时刻扫一遍:周期必须包含它,并且这个周期的终点恰好是下一个周期的起点
    private func assertSeamless(_ rule: ResetRule, from: Date, hours: Int,
                                file: StaticString = #filePath, line: UInt = #line) {
        for step in 0..<(hours * 6) {
            let moment = from.addingTimeInterval(Double(step) * 600 + 0.5)
            guard let period = rule.period(containing: moment) else {
                return XCTFail("\(moment) 算不出周期", file: file, line: line)
            }
            // 只报第一处:一处断开后面会连着错一大片,刷屏反而看不出是哪儿
            guard period.start <= moment && moment < period.end else {
                return XCTFail("\(moment) 不在 \(period.start)…\(period.end) 里", file: file, line: line)
            }
            guard rule.period(containing: period.end)?.start == period.end else {
                return XCTFail("\(period.end) 之后的周期没有接上", file: file, line: line)
            }
        }
    }

    /// 本条的起因:重置时刻落在春季跳过的那一小时里
    func testAResetInsideTheSkippedHourDoesNotOverlapTheNextDay() {
        let rule = daily(2, 30)
        guard let period = rule.period(containing: at(2026, 3, 8, 12)) else { return XCTFail("算不出周期") }
        XCTAssertEqual(period.end, at(2026, 3, 9, 2, 30))
        XCTAssertEqual(rule.period(containing: at(2026, 3, 9, 2, 31))?.start, at(2026, 3, 9, 2, 30))
    }

    func testDailyPeriodsAreSeamlessAcrossSpringForward() {
        assertSeamless(daily(2, 30), from: at(2026, 3, 6), hours: 96)
        assertSeamless(daily(0), from: at(2026, 3, 6), hours: 96)
    }

    /// 秋季那一小时走两遍:重置时刻在重复的那一小时里,也不能切出一个一小时长的周期
    func testDailyPeriodsAreSeamlessAcrossFallBack() {
        assertSeamless(daily(1, 30), from: at(2026, 10, 30), hours: 96)
        guard let period = daily(1, 30).period(containing: at(2026, 11, 1, 12)) else { return XCTFail("算不出周期") }
        XCTAssertTrue(period.end.timeIntervalSince(period.start) >= 23 * 3600, "周期只有 \(period.end.timeIntervalSince(period.start)) 秒")
    }

    func testWeeklyPeriodsAreSeamlessAcrossTheTransition() {
        let weekly = ResetRule(.calendarWeekly(timeZone: ny, weekday: 1, hour: 2, minute: 30), provenance: .configured)
        assertSeamless(weekly, from: at(2026, 3, 1), hours: 24 * 15)
    }

    /// 边界前半秒还是旧周期
    func testHalfASecondBeforeTheBoundaryIsStillTheOldPeriod() {
        let utc = TimeZone(identifier: "UTC")!
        let rule = daily(0, 0, utc)
        let moment = at(2026, 9, 29, 0, 0, utc).addingTimeInterval(-0.5)
        guard let period = rule.period(containing: moment) else { return XCTFail("算不出周期") }
        XCTAssertEqual(period.start, at(2026, 9, 28, 0, 0, utc))
        XCTAssertEqual(period.end, at(2026, 9, 29, 0, 0, utc))
    }
}

final class ResetTimeZoneTests: XCTestCase {

    /// 同一条「当地 0 点」规则,换个时区指的就是另一个瞬间
    func testSameLocalHourInAnotherZoneIsADifferentInstant() {
        let moment = at(2026, 6, 15, 13)
        let inNY = daily(0, 0, ny).period(containing: moment)!.start
        let inSH = daily(0, 0, sh).period(containing: moment)!.start
        XCTAssertFalse(inNY == inSH)
        XCTAssertEqual(localTime(inNY, ny).hour, 0)
        XCTAssertEqual(localTime(inSH, sh).hour, 0)
    }
}

// MARK: - 每周

final class CalendarWeeklyTests: XCTestCase {

    /// 2026-06-15 是周一;weekday 用 Foundation 约定 2=周一
    func testWeeklyPeriodSpansSevenDays() {
        let rule = ResetRule(.calendarWeekly(timeZone: ny, weekday: 2, hour: 0, minute: 0),
                             provenance: .server)
        let w = rule.period(containing: at(2026, 6, 17, 10))!
        XCTAssertEqual(w.start, at(2026, 6, 15, 0))
        XCTAssertEqual(w.end, at(2026, 6, 22, 0))
    }

    func testInvalidWeekdayHasNoPeriod() {
        let rule = ResetRule(.calendarWeekly(timeZone: ny, weekday: 9, hour: 0, minute: 0),
                             provenance: .server)
        XCTAssertNil(rule.period(containing: at(2026, 6, 17)))
    }
}

// MARK: - 日历月(订阅周年)

final class SubscriptionAnniversaryTests: XCTestCase {

    private func monthly(_ day: Int) -> ResetRule {
        ResetRule(.subscriptionAnniversary(timeZone: ny, day: day, hour: 9, minute: 30),
                  provenance: .configured)
    }

    func testMonthlyPeriodFollowsTheCalendarNotThirtyDays() {
        let w = monthly(10).period(containing: at(2026, 1, 20))!
        XCTAssertEqual(w.start, at(2026, 1, 10, 9, 30))
        XCTAssertEqual(w.end, at(2026, 2, 10, 9, 30))
        // 一月有 31 天,按「30 天」算就会错
        XCTAssertEqual(w.duration, 31 * 86400, accuracy: 1)
    }

    func testBeforeTheAnniversaryBelongsToThePreviousMonth() {
        let w = monthly(10).period(containing: at(2026, 1, 3))!
        XCTAssertEqual(w.start, at(2025, 12, 10, 9, 30))
        XCTAssertEqual(w.end, at(2026, 1, 10, 9, 30))
    }

    /// 31 号的订阅在 2 月落在月末 —— 这个夹取方式是本实现的选择,已在代码里注明
    func testDayIsClampedToShortMonths() {
        let w = monthly(31).period(containing: at(2026, 3, 1))!
        XCTAssertEqual(w.start, at(2026, 2, 28, 9, 30))
    }

    /// 夹取之前那一天仍属于上一个周期 —— 2 月 15 日时,2 月 28 日那次还没到
    func testClampedAnniversaryHasNotHappenedYetEarlierInTheMonth() {
        let w = monthly(31).period(containing: at(2026, 2, 15))!
        XCTAssertEqual(w.start, at(2026, 1, 31, 9, 30))
        XCTAssertEqual(w.end, at(2026, 2, 28, 9, 30))
    }

    func testInvalidDayHasNoPeriod() {
        XCTAssertNil(monthly(0).period(containing: at(2026, 2, 15)))
    }
}

// MARK: - 算不出周期的那些

final class UncomputablePeriodTests: XCTestCase {

    /// 滑动窗口没有统一归零时刻 —— **不能冒充定时重置**,
    /// 否则界面上会出现一个凭空生成的倒计时
    func testRollingWindowHasNoPeriodAndNoCountdown() {
        let rule = ResetRule(.rollingWindow(seconds: 3600), provenance: .server)
        XCTAssertFalse(rule.hasPeriods)
        XCTAssertNil(rule.period(containing: Date()))
        XCTAssertNil(rule.periodID(containing: Date()))
    }

    func testUnknownProducesNoFabricatedPeriod() {
        XCTAssertFalse(ResetRule.unknown.hasPeriods)
        XCTAssertNil(ResetRule.unknown.period(containing: Date()))
    }

    /// 服务端只说了这一段,就只认这一段 —— 不往外推
    func testServerProvidedIsNotExtrapolated() {
        let start = at(2026, 6, 15, 10)
        let rule = ResetRule(.serverProvided(start: start, end: start.addingTimeInterval(3600)),
                             provenance: .server)
        XCTAssertNotNil(rule.period(containing: start.addingTimeInterval(600)))
        XCTAssertNil(rule.period(containing: start.addingTimeInterval(-600)))
        XCTAssertNil(rule.period(containing: start.addingTimeInterval(7200)))
    }
}

// MARK: - 周期 ID 与来源标注

final class PeriodIdentityTests: XCTestCase {

    /// 同一个周期无论什么时候算,ID 都得一样 —— 历史分段和告警去重都靠它
    func testPeriodIDIsStableAcrossMomentsInTheSamePeriod() {
        let rule = daily(0)
        let a = rule.periodID(containing: at(2026, 6, 15, 1))
        let b = rule.periodID(containing: at(2026, 6, 15, 23))
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    func testDifferentPeriodsHaveDifferentIDs() {
        let rule = daily(0)
        XCTAssertFalse(rule.periodID(containing: at(2026, 6, 15, 1))
                       == rule.periodID(containing: at(2026, 6, 16, 1)))
    }

    /// 不同规则算出同一个起点时,ID 不该撞在一起
    func testDifferentPoliciesDoNotCollide() {
        let moment = at(2026, 6, 15, 12)
        let calendar = daily(0)
        let fixed = ResetRule(.fixedDuration(anchor: at(2026, 6, 15, 0), seconds: 86400),
                              provenance: .server)
        XCTAssertEqual(calendar.period(containing: moment)!.start,
                       fixed.period(containing: moment)!.start)
        XCTAssertFalse(calendar.periodID(containing: moment) == fixed.periodID(containing: moment))
    }

    /// 观测到的重置事件算确定;默认假设才标「推算」
    func testProvenanceDecidesTheInferredLabel() {
        XCTAssertFalse(daily(0).period(containing: at(2026, 6, 15, 12))!.isInferred)

        let assumed = ResetRule(.calendarDaily(timeZone: ny, hour: 0, minute: 0),
                                provenance: .inferred)
        XCTAssertTrue(assumed.period(containing: at(2026, 6, 15, 12))!.isInferred)
    }

    /// 优先级顺序即文档里写的那条:服务端 > 协议/配置 > 观测 > 默认假设 > 未知
    func testProvenanceOrdering() {
        XCTAssertTrue(ResetProvenance.server < .configured)
        XCTAssertTrue(ResetProvenance.configured < .observed)
        XCTAssertTrue(ResetProvenance.observed < .inferred)
        XCTAssertTrue(ResetProvenance.inferred < .unknown)
        XCTAssertTrue(ResetProvenance.observed.isCertain)
        XCTAssertFalse(ResetProvenance.inferred.isCertain)
    }
}

// MARK: - 过期窗口不给速度判断(OPT-010)

final class ExpiredWindowPaceTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_788_800_000)
    private var window: TimeWindow { TimeWindow(start: start, end: start.addingTimeInterval(3600)) }

    private func gauge(used: Double) -> QuotaBucket {
        bucket("window", used: used, limit: 100, window: window)
    }

    func testInsideTheWindowStillGivesAVerdict() {
        XCTAssertFalse(gauge(used: 30).pace(now: start.addingTimeInterval(1800)) == .unavailable)
    }

    /// 断网跨过重置时刻就是这个情形:窗口走完,剩余时间归零,
    /// 于是已用 70% 的旧采样也会算成「正常速度」—— 那句话没有任何当期数据支撑
    func testExpiredWindowGivesNoVerdict() {
        XCTAssertEqual(gauge(used: 70).pace(now: start.addingTimeInterval(7200)), .unavailable)
    }

    /// 恰好走到终点就已经属于下一个周期了
    func testTheEndInstantIsAlreadyOutside() {
        XCTAssertEqual(gauge(used: 70).pace(now: start.addingTimeInterval(3600)), .unavailable)
    }

    func testBeforeTheWindowGivesNoVerdict() {
        XCTAssertEqual(gauge(used: 10).pace(now: start.addingTimeInterval(-60)), .unavailable)
    }

    /// 拿不到判断时状态也不该报「超速」,但「剩余不足」是纯额度判断,仍然成立
    func testExpiredWindowStillReportsCriticalOnQuotaAlone() {
        XCTAssertEqual(gauge(used: 95).status(now: start.addingTimeInterval(7200)), .critical)
        XCTAssertEqual(gauge(used: 50).status(now: start.addingTimeInterval(7200)), .normal)
    }
}
