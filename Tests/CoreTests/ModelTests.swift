import Foundation
import CodaPaceCore

private func json(_ s: String) -> Data { Data(s.utf8) }

// MARK: - 宽松解码

final class DecodingTests: XCTestCase {

    /// 换一个中转站部署、对方少给几个字段,也不能整个崩掉
    func testMissingFieldsFallBackToZero() {
        let limits = try! JSONDecoder().decode(Limits.self, from: json("{}"))
        XCTAssertEqual(limits.totalCostLimit, 0, accuracy: 1e-12)
        XCTAssertEqual(limits.currentDailyCost, 0, accuracy: 1e-12)
        XCTAssertEqual(limits.rateLimitWindow, 0)
    }

    func testNullValuesFallBackToZero() {
        let limits = try! JSONDecoder().decode(
            Limits.self,
            from: json(#"{"dailyCostLimit": null, "currentDailyCost": null}"#)
        )
        XCTAssertEqual(limits.dailyCostLimit, 0, accuracy: 1e-12)
    }

    /// 周重置日可以合法地为 0(周日),所以「缺失」必须能和「0」区分开
    func testMissingWeeklyResetIsMinusOneNotZero() {
        let absent = try! JSONDecoder().decode(Limits.self, from: json("{}"))
        XCTAssertEqual(absent.weeklyResetDay, -1)
        XCTAssertEqual(absent.weeklyResetHour, -1)

        let sunday = try! JSONDecoder().decode(
            Limits.self,
            from: json(#"{"weeklyResetDay": 0, "weeklyResetHour": 0}"#)
        )
        XCTAssertEqual(sunday.weeklyResetDay, 0)
        XCTAssertEqual(sunday.weeklyResetHour, 0)
    }

    /// 按实测响应的结构解一遍
    func testDecodesRealResponseShape() {
        let payload = #"""
        {
          "name": "eva",
          "isActive": true,
          "usage": {
            "total": { "allTokens": 2152951760, "requests": 25024, "cost": 2432.68887395 }
          },
          "limits": {
            "rateLimitWindow": 60, "rateLimitCost": 20,
            "dailyCostLimit": 70, "totalCostLimit": 3000, "weeklyOpusCostLimit": 500,
            "weeklyResetDay": 1, "weeklyResetHour": 0,
            "currentWindowCost": 3.80129775, "currentDailyCost": 3.80129775,
            "currentTotalCost": 2432.68887395, "weeklyOpusCost": 11.2342345,
            "windowStartTime": 1788797068749, "windowEndTime": 1788800668749,
            "windowRemainingSeconds": 1317
          }
        }
        """#

        let stats = try! JSONDecoder().decode(UserStats.self, from: json(payload))
        XCTAssertEqual(stats.name, "eva")
        XCTAssertTrue(stats.isActive)
        XCTAssertEqual(stats.total.requests, 25024)
        XCTAssertEqual(stats.total.allTokens, 2152951760, accuracy: 1)
        XCTAssertEqual(stats.limits.totalCostLimit, 3000, accuracy: 1e-9)
        XCTAssertEqual(stats.limits.weeklyResetDay, 1)
    }

    func testMissingUsageBlockDoesNotFail() {
        let stats = try! JSONDecoder().decode(UserStats.self, from: json(#"{"name": "x"}"#))
        XCTAssertEqual(stats.total.requests, 0)
        XCTAssertEqual(stats.name, "x")
    }
}

// MARK: - 信封

final class EnvelopeTests: XCTestCase {

    func testUnwrapsSuccessfulPayload() {
        let block = try! ResponseDecoder.unwrap(
            UsageBlock.self,
            from: json(#"{"success": true, "data": {"cost": 12.5, "requests": 3}}"#)
        )
        XCTAssertEqual(block.cost, 12.5, accuracy: 1e-9)
        XCTAssertEqual(block.requests, 3)
    }

    func testSuccessFalseSurfacesServerMessage() {
        let data = json(#"{"success": false, "message": "apiId not found"}"#)
        XCTAssertThrowsError(try ResponseDecoder.unwrap(UsageBlock.self, from: data)) { error in
            XCTAssertEqual((error as? APIError)?.message, "apiId not found")
        }
    }

    func testGarbageResponseGivesAReadableError() {
        // 比如网址填错,指到了一个返回 HTML 的页面
        let data = json("<html>404</html>")
        XCTAssertThrowsError(try ResponseDecoder.unwrap(UsageBlock.self, from: data)) { error in
            XCTAssertNotNil((error as? APIError)?.message)
        }
    }
}

// MARK: - 格式化

final class FormatTests: XCTestCase {

    func testMoneyShedsDecimalsAsNumbersGrow() {
        XCTAssertEqual(Fmt.money(1234.7), "$1235")
        XCTAssertEqual(Fmt.money(123.46), "$123.5")
        XCTAssertEqual(Fmt.money(1.234), "$1.23")
    }

    func testMoneyThresholds() {
        XCTAssertEqual(Fmt.money(1000), "$1000")
        XCTAssertEqual(Fmt.money(999.9), "$999.9")
        XCTAssertEqual(Fmt.money(100), "$100.0")
        XCTAssertEqual(Fmt.money(99.99), "$99.99")
    }

    func testMoney2AlwaysGroupsAndKeepsTwoDecimals() {
        XCTAssertEqual(Fmt.money2(2432.68887395), "$2,432.69")
        XCTAssertEqual(Fmt.money2(5), "$5.00")
    }

    func testCountUsesCompactUnitsNotScientificNotation() {
        XCTAssertEqual(Fmt.count(2152951760), "2.15B")
        XCTAssertEqual(Fmt.count(1_500_000), "1.5M")
        XCTAssertEqual(Fmt.count(2400), "2.4K")
        XCTAssertEqual(Fmt.count(42), "42")
    }

    func testIntGrouping() {
        XCTAssertEqual(Fmt.int(25024), "25,024")
    }

    func testPercentRounds() {
        XCTAssertEqual(Fmt.percent(0.8099), "81%")
        XCTAssertEqual(Fmt.percent(0), "0%")
        XCTAssertEqual(Fmt.percent(1), "100%")
    }

    /// 倒计时只保留两个量级
    func testDurationKeepsTwoMagnitudes() {
        XCTAssertEqual(Fmt.duration(3 * 86400 + 14 * 3600 + 30 * 60, .zhHans), "3 天 14 小时")
        XCTAssertEqual(Fmt.duration(81 * 60, .zhHans), "1 小时 21 分")
        XCTAssertEqual(Fmt.duration(22 * 60, .zhHans), "22 分钟")
        XCTAssertEqual(Fmt.duration(45, .zhHans), "45 秒")
        XCTAssertEqual(Fmt.duration(0, .zhHans), "即将重置")
        XCTAssertEqual(Fmt.duration(-10, .zhHans), "即将重置")
    }

    func testExactMagnitudesDropTheEmptyRemainder() {
        XCTAssertEqual(Fmt.duration(2 * 86400, .zhHans), "2 天")
        XCTAssertEqual(Fmt.duration(3600, .zhHans), "1 小时")
    }

    /// 同一个时长换个语言应该给出该语言的写法,单位不能残留中文
    func testDurationIsLocalised() {
        XCTAssertEqual(Fmt.duration(3 * 86400 + 14 * 3600, .en), "3 d 14 h")
        XCTAssertEqual(Fmt.duration(22 * 60, .en), "22 min")
        XCTAssertEqual(Fmt.duration(0, .en), "Resetting soon")
        XCTAssertEqual(Fmt.duration(81 * 60, .zhHant), "1 小時 21 分")
    }

    func testResetsIn() {
        XCTAssertEqual(Fmt.resetsIn(22 * 60, .zhHans), "22 分钟后重置")
        XCTAssertEqual(Fmt.resetsIn(0, .zhHans), "即将重置")
        XCTAssertEqual(Fmt.resetsIn(22 * 60, .en), "Resets in 22 min")
    }
}

// MARK: - 菜单栏选哪条额度

final class MenuBarSourceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_788_800_000)

    private func snapshot(total: Gauge, daily: Gauge, weekly: Gauge, window: Gauge) -> Snapshot {
        Snapshot(name: "eva", isActive: true,
                 gauges: [total, daily, weekly, window],
                 totalCost: 0, totalRequests: 0, totalTokens: 0,
                 monthlyCost: nil, monthlyRequests: nil, fetchedAt: now)
    }

    /// 自动模式取最紧张的一条,但要排除每小时重置的限流窗口
    func testAutoPicksTightestExcludingWindow() {
        let snap = snapshot(
            total:  Gauge(kind: .total, used: 2432, limit: 3000),        // 剩 19%
            daily:  Gauge(kind: .daily, used: 3.8, limit: 70),           // 剩 95%
            weekly: Gauge(kind: .weeklyOpus, used: 11, limit: 500),      // 剩 98%
            window: Gauge(kind: .window, used: 10, limit: 20)            // 剩 50%
        )
        XCTAssertEqual(snap.menuBarGauge(source: .auto)?.kind, .total)
    }

    func testWindowIsNormallyIgnoredEvenWhenItIsTheTightest() {
        let snap = snapshot(
            total:  Gauge(kind: .total, used: 100, limit: 3000),         // 剩 97%
            daily:  Gauge(kind: .daily, used: 20, limit: 70),            // 剩 71%
            weekly: Gauge(kind: .weeklyOpus, used: 11, limit: 500),
            window: Gauge(kind: .window, used: 8, limit: 20)             // 剩 60%,比 daily 高
        )
        XCTAssertEqual(snap.menuBarGauge(source: .auto)?.kind, .daily)
    }

    /// 例外:限流窗口快满了,马上要被限流,该顶上来
    func testCriticalWindowTakesOver() {
        let snap = snapshot(
            total:  Gauge(kind: .total, used: 100, limit: 3000),
            daily:  Gauge(kind: .daily, used: 20, limit: 70),
            weekly: Gauge(kind: .weeklyOpus, used: 11, limit: 500),
            window: Gauge(kind: .window, used: 19, limit: 20)            // 剩 5%
        )
        XCTAssertEqual(snap.menuBarGauge(source: .auto)?.kind, .window)
    }

    func testFixedSelectionIsHonoured() {
        let snap = snapshot(
            total:  Gauge(kind: .total, used: 2432, limit: 3000),
            daily:  Gauge(kind: .daily, used: 3.8, limit: 70),
            weekly: Gauge(kind: .weeklyOpus, used: 11, limit: 500),
            window: Gauge(kind: .window, used: 10, limit: 20)
        )
        XCTAssertEqual(snap.menuBarGauge(source: .fixed(.weeklyOpus))?.kind, .weeklyOpus)
    }

    /// 选中的那条没有上限时,退回自动
    func testFixedSelectionFallsBackWhenUnlimited() {
        let snap = snapshot(
            total:  Gauge(kind: .total, used: 2432, limit: 3000),
            daily:  Gauge(kind: .daily, used: 3.8, limit: 0),            // 不限
            weekly: Gauge(kind: .weeklyOpus, used: 11, limit: 500),
            window: Gauge(kind: .window, used: 10, limit: 20)
        )
        XCTAssertEqual(snap.menuBarGauge(source: .fixed(.daily))?.kind, .total)
    }
}

// MARK: - 组装快照

final class SnapshotBuilderTests: XCTestCase {

    func testBuildsFourGaugesInDisplayOrder() {
        var stats = UserStats()
        stats.name = "eva"
        stats.limits.totalCostLimit = 3000
        stats.limits.currentTotalCost = 2432.69
        stats.limits.dailyCostLimit = 70
        stats.limits.weeklyOpusCostLimit = 500
        stats.limits.rateLimitCost = 20

        let snap = SnapshotBuilder.build(
            stats: stats, monthly: nil,
            schedule: ResetSchedule(timeZone: TimeZone(identifier: "Asia/Shanghai")!),
            now: Date(timeIntervalSince1970: 1_788_800_000)
        )

        XCTAssertEqual(snap.gauges.map(\.kind), [.total, .daily, .weeklyOpus, .window])
        XCTAssertEqual(snap.gauge(.total)?.remaining ?? -1, 3000 - 2432.69, accuracy: 0.01)
    }

    /// 总额度没有重置周期,不应被安上时间窗口
    func testTotalGaugeNeverGetsAWindow() {
        let snap = SnapshotBuilder.build(
            stats: UserStats(), monthly: nil,
            schedule: ResetSchedule(), now: Date()
        )
        XCTAssertNil(snap.gauge(.total)?.window)
    }

    func testEmptyNameFallsBackToPlaceholder() {
        let snap = SnapshotBuilder.build(
            stats: UserStats(), monthly: nil, schedule: ResetSchedule(), now: Date()
        )
        XCTAssertEqual(snap.name, "API Key")
    }
}
