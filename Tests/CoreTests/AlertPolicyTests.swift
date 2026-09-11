import Foundation
import CodaPaceCore

private let alertTZ = TimeZone(identifier: "Asia/Shanghai")!

private func alertDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = alertTZ
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

/// 造一个只关心某几条额度的快照,其余留成「不限」以免干扰
private func alertSnapshot(_ gauges: [Gauge], at now: Date) -> Snapshot {
    Snapshot(name: "eva", isActive: true, gauges: gauges,
             totalCost: 0, totalRequests: 0, totalTokens: 0,
             monthlyCost: nil, monthlyRequests: nil, fetchedAt: now)
}

final class AlertPolicyTests: XCTestCase {

    // MARK: 额度不足

    func testLowQuotaFires() {
        let now = alertDate(2026, 9, 8, 12)
        // 剩 5%,低于 10% 阈值
        let snap = alertSnapshot([Gauge(kind: .total, used: 95, limit: 100)], at: now)

        let alerts = AlertPolicy.candidates(for: snap, now: now, timeZone: alertTZ)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].kind, .lowQuota)
        XCTAssertEqual(alerts[0].quota, .total)
    }

    func testComfortableQuotaDoesNotFire() {
        let now = alertDate(2026, 9, 8, 12)
        let snap = alertSnapshot([Gauge(kind: .total, used: 30, limit: 100)], at: now)
        XCTAssertEqual(AlertPolicy.candidates(for: snap, now: now, timeZone: alertTZ).count, 0)
    }

    /// 不限额度永远不提醒
    func testUnlimitedQuotaNeverFires() {
        let now = alertDate(2026, 9, 8, 12)
        let snap = alertSnapshot([Gauge(kind: .daily, used: 9999, limit: 0)], at: now)
        XCTAssertEqual(AlertPolicy.candidates(for: snap, now: now, timeZone: alertTZ).count, 0)
    }

    // MARK: 超速

    func testOverPaceFiresAfterWindowHasProgressed() {
        let start = alertDate(2026, 9, 8, 0)
        let now = start.addingTimeInterval(3600 * 0.5)          // 窗口过半
        let window = TimeWindow(start: start, end: start.addingTimeInterval(3600))

        // 时间过半,额度只剩 40% → 超速,且剩余在提醒区间内
        let snap = alertSnapshot([Gauge(kind: .window, used: 60, limit: 100, window: window)],
                                 at: now)

        let alerts = AlertPolicy.candidates(for: snap, now: now, timeZone: alertTZ)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].kind, .overPace)
    }

    /// 窗口刚开始就判超速没有意义 —— 前几分钟用一点点都会触发
    func testOverPaceIsSuppressedEarlyInWindow() {
        let start = alertDate(2026, 9, 8, 0)
        let now = start.addingTimeInterval(3600 * 0.05)         // 才过 5%
        let window = TimeWindow(start: start, end: start.addingTimeInterval(3600))

        let snap = alertSnapshot([Gauge(kind: .window, used: 30, limit: 100, window: window)],
                                 at: now)
        XCTAssertEqual(AlertPolicy.candidates(for: snap, now: now, timeZone: alertTZ).count, 0)
    }

    /// 额度还很充裕时,即便算出超速也不打扰
    func testOverPaceIsSuppressedWhenPlentyRemains() {
        let start = alertDate(2026, 9, 8, 0)
        let now = start.addingTimeInterval(3600 * 0.3)
        let window = TimeWindow(start: start, end: start.addingTimeInterval(3600))

        // 剩 75%,高于 60% 的提醒门槛
        let snap = alertSnapshot([Gauge(kind: .window, used: 25, limit: 100, window: window)],
                                 at: now)
        XCTAssertEqual(AlertPolicy.candidates(for: snap, now: now, timeZone: alertTZ).count, 0)
    }

    /// 额度已经不足时不再叠加超速提醒 —— 两条说的是同一件事
    func testLowQuotaSupersedesOverPace() {
        let start = alertDate(2026, 9, 8, 0)
        let now = start.addingTimeInterval(3600 * 0.5)
        let window = TimeWindow(start: start, end: start.addingTimeInterval(3600))

        let snap = alertSnapshot([Gauge(kind: .window, used: 96, limit: 100, window: window)],
                                 at: now)

        let alerts = AlertPolicy.candidates(for: snap, now: now, timeZone: alertTZ)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].kind, .lowQuota)
    }

    // MARK: 去重

    /// 同一周期内只提醒一次,否则每 60 秒一次刷新就是每 60 秒一次骚扰
    func testAlertIsNotRepeatedWithinSameCycle() {
        let now = alertDate(2026, 9, 8, 12)
        let snap = alertSnapshot([Gauge(kind: .total, used: 95, limit: 100)], at: now)

        let first = AlertPolicy.newAlerts(for: snap, now: now,
                                          alreadySent: [], timeZone: alertTZ)
        XCTAssertEqual(first.count, 1)

        let sent: Set<String> = [first[0].dedupeKey]
        let later = AlertPolicy.newAlerts(for: snap, now: now.addingTimeInterval(60),
                                          alreadySent: sent, timeZone: alertTZ)
        XCTAssertEqual(later.count, 0)
    }

    /// 跨过重置边界后允许再提醒一次
    func testNewCycleAllowsAlertAgain() {
        let firstStart = alertDate(2026, 9, 8, 0)
        let secondStart = alertDate(2026, 9, 8, 1)

        func snap(_ start: Date) -> Snapshot {
            let window = TimeWindow(start: start, end: start.addingTimeInterval(3600))
            return alertSnapshot([Gauge(kind: .window, used: 95, limit: 100, window: window)],
                                 at: start.addingTimeInterval(1800))
        }

        let a = AlertPolicy.candidates(for: snap(firstStart),
                                       now: firstStart.addingTimeInterval(1800),
                                       timeZone: alertTZ)[0]
        let b = AlertPolicy.candidates(for: snap(secondStart),
                                       now: secondStart.addingTimeInterval(1800),
                                       timeZone: alertTZ)[0]

        XCTAssertTrue(a.dedupeKey != b.dedupeKey)

        let stillNew = AlertPolicy.newAlerts(for: snap(secondStart),
                                             now: secondStart.addingTimeInterval(1800),
                                             alreadySent: [a.dedupeKey], timeZone: alertTZ)
        XCTAssertEqual(stillNew.count, 1)
    }

    /// 没有时间窗口的额度按天去重 —— 不然一旦低于阈值就再也不提醒了
    func testWindowlessQuotaDedupesPerDay() {
        let day1 = alertDate(2026, 9, 8, 12)
        let day2 = alertDate(2026, 9, 9, 12)

        let a = AlertPolicy.candidates(
            for: alertSnapshot([Gauge(kind: .total, used: 95, limit: 100)], at: day1),
            now: day1, timeZone: alertTZ)[0]
        let b = AlertPolicy.candidates(
            for: alertSnapshot([Gauge(kind: .total, used: 95, limit: 100)], at: day2),
            now: day2, timeZone: alertTZ)[0]

        XCTAssertTrue(a.dedupeKey != b.dedupeKey)
    }

    /// 多条额度同时告警时各自独立,互不覆盖
    func testMultipleQuotasAlertIndependently() {
        let now = alertDate(2026, 9, 8, 12)
        let snap = alertSnapshot([
            Gauge(kind: .total, used: 95, limit: 100),
            Gauge(kind: .daily, used: 96, limit: 100),
        ], at: now)

        let alerts = AlertPolicy.candidates(for: snap, now: now, timeZone: alertTZ)
        XCTAssertEqual(alerts.count, 2)
        XCTAssertTrue(alerts[0].dedupeKey != alerts[1].dedupeKey)
    }
}
