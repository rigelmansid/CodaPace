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

        let first = AlertPolicy.candidates(for: snap, now: now, timeZone: alertTZ)
        XCTAssertEqual(first.count, 1)

        var ledger = AlertLedger(namespace: "acct-a")
        XCTAssertTrue(ledger.isPending(first[0]))
        ledger.confirm(first[0])

        let later = AlertPolicy.candidates(for: snap, now: now.addingTimeInterval(60),
                                           timeZone: alertTZ)
        XCTAssertEqual(later.filter { ledger.isPending($0) }.count, 0)
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

        // 上一个周期发过了,新周期照样该发
        var ledger = AlertLedger(namespace: "acct-a")
        ledger.confirm(a)
        XCTAssertFalse(ledger.isPending(a))
        XCTAssertTrue(ledger.isPending(b))
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

// MARK: - 已发送账本

private func lowAlert(_ quota: QuotaKind = .total, cycle: Date = alertDate(2026, 9, 8, 0)) -> QuotaAlert {
    QuotaAlert(kind: .lowQuota, quota: quota, cycleStart: cycle,
               remainingRatio: 0.05, remaining: 3.5)
}

private let accountA = AccountIdentity(providerID: "p", baseURL: "https://a.example.com", apiId: "id-a")
private let accountB = AccountIdentity(providerID: "p", baseURL: "https://b.example.com", apiId: "id-b")

/// OPT-006：去重要按账户分开
final class AlertLedgerAccountScopeTests: XCTestCase {

    /// A 在某周期收到低额度通知后切到 B，B 的同类告警**不该**被静默掉
    func testTwoAccountsAlertIndependentlyInTheSameCycle() {
        let alert = lowAlert()
        var a = AlertLedger(namespace: accountA.notificationNamespace)
        var b = AlertLedger(namespace: accountB.notificationNamespace)

        a.confirm(alert)
        XCTAssertFalse(a.isPending(alert))
        XCTAssertTrue(b.isPending(alert), "B 的账本不该被 A 的记录影响")

        b.confirm(alert)
        XCTAssertFalse(b.isPending(alert))
    }

    /// 切回原账户后，它已成功发过的告警仍然去重 ——
    /// 这是「切换时清空账本」那个缓解做不到的
    func testSwitchingBackKeepsTheOriginalAccountsRecords() {
        let alert = lowAlert()
        var a = AlertLedger(namespace: accountA.notificationNamespace)
        a.confirm(alert)

        // 换到 B 再换回来：从落盘内容重建
        let restored = AlertLedger(namespace: accountA.notificationNamespace, sent: a.storedKeys)
        XCTAssertFalse(restored.isPending(alert))
    }

    /// **这条才真正对应 OPT-006 的现场**：旧实现两个账户共用一份全局存储。
    /// 账本自带命名空间，所以哪怕记录落进同一份存储也不会互相静默 ——
    /// 落盘键如今也按账户分开了，但账本不该依赖外部存储替它做隔离。
    func testRecordsFromAnotherAccountDoNotSilenceThisOne() {
        let alert = lowAlert()
        var a = AlertLedger(namespace: accountA.notificationNamespace)
        a.confirm(alert)

        // 把 A 的记录原样喂给 B 的账本，模拟共用存储
        let b = AlertLedger(namespace: accountB.notificationNamespace, sent: a.storedKeys)
        XCTAssertTrue(b.isPending(alert), "A 的记录不该让 B 静默")
    }

    /// 命名空间取完整身份：供应商、服务地址、账户标识任一不同即不同账本
    func testNamespaceCoversTheWholeIdentity() {
        let sameId = AccountIdentity(providerID: "p", baseURL: "https://other.example.com",
                                     apiId: accountA.apiId)
        let otherProvider = AccountIdentity(providerID: "q", baseURL: accountA.baseURL,
                                            apiId: accountA.apiId)
        XCTAssertFalse(accountA.notificationNamespace == sameId.notificationNamespace)
        XCTAssertFalse(accountA.notificationNamespace == otherProvider.notificationNamespace)
    }

    func testNamespaceDoesNotLeakRawCredentials() {
        let ns = accountA.notificationNamespace
        XCTAssertFalse(ns.contains("id-a"))
        XCTAssertFalse(ns.contains("example.com"))
    }
}

/// OPT-005：只有系统确实收下才记账
final class AlertLedgerDeliveryTests: XCTestCase {

    private var ledger: AlertLedger { AlertLedger(namespace: "acct") }

    func testConfirmedAlertIsNotSentAgain() {
        var book = ledger
        let alert = lowAlert()

        XCTAssertTrue(book.beginDelivery(alert))
        book.confirm(alert)
        XCTAssertFalse(book.isPending(alert))
        XCTAssertEqual(book.storedKeys.count, 1)
    }

    /// 权限被拒 / 提交失败 —— **不留成功记录**，同周期内下次刷新还能重试
    func testAbandonedAlertLeavesNoRecordAndCanRetry() {
        var book = ledger
        let alert = lowAlert()

        XCTAssertTrue(book.beginDelivery(alert))
        book.abandon(alert)

        XCTAssertTrue(book.isPending(alert), "失败的告警必须能重试")
        XCTAssertEqual(book.storedKeys, [])
    }

    func testRetryAfterFailureCanSucceed() {
        var book = ledger
        let alert = lowAlert()

        _ = book.beginDelivery(alert)
        book.abandon(alert)

        XCTAssertTrue(book.beginDelivery(alert))
        book.confirm(alert)
        XCTAssertFalse(book.isPending(alert))
    }

    /// 投递是异步的，期间下一次刷新会算出同一条告警 —— 不能重复提交
    func testInFlightAlertIsNotSubmittedTwice() {
        var book = ledger
        let alert = lowAlert()

        XCTAssertTrue(book.beginDelivery(alert))
        XCTAssertFalse(book.beginDelivery(alert), "还在途中就不该再提交一次")
        XCTAssertFalse(book.isPending(alert))
    }

    /// 在途状态只活在内存里：落盘内容不该包含它，否则进程挂掉后它会永远卡住
    func testInFlightStateIsNotPersisted() {
        var book = ledger
        _ = book.beginDelivery(lowAlert())
        XCTAssertEqual(book.storedKeys, [])

        let reloaded = AlertLedger(namespace: "acct", sent: book.storedKeys)
        XCTAssertTrue(reloaded.isPending(lowAlert()), "重启后那条该能重新投递")
    }

    func testConfirmIsIdempotent() {
        var book = ledger
        let alert = lowAlert()
        book.confirm(alert)
        book.confirm(alert)
        XCTAssertEqual(book.storedKeys.count, 1)
    }

    /// 重新打开通知时清账，好让当前周期能再提醒一次
    func testClearAllowsAlertingAgain() {
        var book = ledger
        let alert = lowAlert()
        book.confirm(alert)
        book.clear()
        XCTAssertTrue(book.isPending(alert))
    }

    /// 周期键随时间单调增长，不裁剪会无限膨胀；裁的是最旧的
    func testLedgerIsCappedAndDropsTheOldest() {
        var book = ledger
        for i in 0..<(AlertLedger.capacity + 10) {
            book.confirm(lowAlert(cycle: alertDate(2026, 9, 8, 0).addingTimeInterval(Double(i) * 3600)))
        }
        XCTAssertEqual(book.storedKeys.count, AlertLedger.capacity)

        // 最早那条已被挤掉，最新那条还在
        let oldest = lowAlert(cycle: alertDate(2026, 9, 8, 0))
        let newest = lowAlert(cycle: alertDate(2026, 9, 8, 0)
            .addingTimeInterval(Double(AlertLedger.capacity + 9) * 3600))
        XCTAssertTrue(book.isPending(oldest))
        XCTAssertFalse(book.isPending(newest))
    }

    func testLoadingMoreThanCapacityIsTrimmed() {
        let keys = (0..<(AlertLedger.capacity + 50)).map { "k\($0)" }
        XCTAssertEqual(AlertLedger(namespace: "acct", sent: keys).storedKeys.count,
                       AlertLedger.capacity)
    }
}
