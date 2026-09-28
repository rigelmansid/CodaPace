import Foundation
import CodaPaceCore

//
//  Sub2APIProviderTests.swift — sub2api 适配器
//
//  下面几份 payload 的**形状**照抄 2026-09-28 本机部署 v0.2.9 实测拿到的真实响应
//  (字段名、嵌套、为 null 的窗口起点、带微秒和 +08:00 的时间戳都原样保留),
//  数值是编的。三种形态各一份:key 自带限额、订阅分组、钱包余额。
//

private let sub2api = Sub2APIProvider()

/// key 自带限额(`quota_limited`),三个窗口都用过 —— 服务端给了起点和 reset_at
private let quotaLimited = #"""
{
  "daily_usage": [],
  "isValid": true,
  "mode": "quota_limited",
  "quota": {"limit": 50, "remaining": 37.5, "unit": "USD", "used": 12.5},
  "rate_limits": [
    {"limit": 5, "remaining": 3.75, "reset_at": "2026-09-28T19:23:26.666648+08:00",
     "used": 1.25, "window": "5h", "window_start": "2026-09-28T14:23:26.666648+08:00"},
    {"limit": 20, "remaining": 15.2, "reset_at": "2026-09-29T09:23:26.666648+08:00",
     "used": 4.8, "window": "1d", "window_start": "2026-09-28T09:23:26.666648+08:00"},
    {"limit": 100, "remaining": 70, "reset_at": "2026-10-02T15:23:26.666648+08:00",
     "used": 30, "window": "7d", "window_start": "2026-09-25T15:23:26.666648+08:00"}
  ],
  "remaining": 37.5,
  "status": "active",
  "unit": "USD",
  "usage": {
    "average_duration_ms": 0, "rpm": 0, "tpm": 0,
    "today": {"actual_cost": 0.4, "cost": 0.4, "requests": 3, "total_tokens": 1200},
    "total": {"actual_cost": 12.5, "cost": 12.5, "requests": 90, "total_tokens": 450000}
  }
}
"""#

/// 同一把 key 还没用过:窗口起点和 reset_at 都是 null
private let quotaLimitedUnused = #"""
{"isValid": true, "mode": "quota_limited", "status": "active",
 "quota": {"limit": 50, "remaining": 50, "unit": "USD", "used": 0},
 "rate_limits": [{"limit": 5, "remaining": 5, "used": 0, "window": "5h", "window_start": null}]}
"""#

/// 订阅分组。只给 weekly_window_start,没有日窗和月窗的起点
private let subscription = #"""
{
  "daily_usage": [],
  "isValid": true,
  "mode": "unrestricted",
  "planName": "lab-subscription",
  "remaining": 6.8,
  "subscription": {
    "daily_limit_usd": 10, "daily_usage_usd": 3.2,
    "expires_at": "2026-10-28T15:22:08.392101+08:00",
    "monthly_limit_usd": 150, "monthly_usage_usd": 60,
    "weekly_limit_usd": 50, "weekly_usage_usd": 18,
    "weekly_window_start": "2026-09-26T15:23:26.719278+08:00"
  },
  "unit": "USD",
  "usage": {"total": {"actual_cost": 81.2, "requests": 400, "total_tokens": 2000000}}
}
"""#

/// 钱包余额:没有任何周期额度
private let wallet = #"""
{"balance": 0, "daily_usage": [], "isValid": true, "mode": "unrestricted",
 "planName": "钱包余额", "remaining": 0, "unit": "USD"}
"""#

private let site = URLComponents(string: "https://relay.example.com/v1")!

private func stamp(_ text: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: text)!
}

/// 解码失败就报失败并返回 nil —— 这套框架的断言不中止用例,不能让后面对着空值崩掉
private func snapshot(_ json: String, now: String,
                      file: StaticString = #filePath, line: UInt = #line) -> Snapshot? {
    do {
        let usage = try Sub2APIUsage.decode(Data(json.utf8), language: .zhHans)
        return sub2api.buildSnapshot(usage, now: stamp(now))
    } catch {
        XCTFail("解码失败:\(error)", file: file, line: line)
        return nil
    }
}

final class Sub2APIProviderTests: XCTestCase {

    // ── key 自带限额 ──────────────────────────────────────

    /// 三个窗口的起止都来自服务端,原样用,不外推
    func testKeyWindowsUseTheServersResetTimes() {
        guard let snap = snapshot(quotaLimited, now: "2026-09-28T15:30:00.000000+08:00") else { return }
        XCTAssertEqual(snap.gauges.map(\.id), ["total", "window_5h", "window_1d", "window_7d"])

        let fiveHours = snap.gauges.first { $0.id == "window_5h" }
        XCTAssertEqual(fiveHours?.used, 1.25)
        XCTAssertEqual(fiveHours?.limit, 5)
        XCTAssertEqual(fiveHours?.window?.start, stamp("2026-09-28T14:23:26.666648+08:00"))
        XCTAssertEqual(fiveHours?.window?.end, stamp("2026-09-28T19:23:26.666648+08:00"))
        XCTAssertEqual(fiveHours?.window?.isInferred, false)
        XCTAssertEqual(fiveHours?.rule?.provenance, .server)
    }

    /// 窗口从第一次使用起算,不是自然日 —— 标题不能写「今日」
    func testKeyWindowTitlesDoNotClaimCalendarPeriods() {
        guard let snap = snapshot(quotaLimited, now: "2026-09-28T15:30:00.000000+08:00") else { return }
        XCTAssertEqual(snap.gauges.first { $0.id == "window_1d" }?.title, .localized(.quotaOneDay))
        XCTAssertEqual(snap.gauges.first { $0.id == "window_7d" }?.title, .localized(.quotaSevenDays))
    }

    /// 总额没有周期,只显示,不给 pace
    func testTheTotalQuotaHasNoPeriod() {
        guard let snap = snapshot(quotaLimited, now: "2026-09-28T15:30:00.000000+08:00") else { return }
        let total = snap.gauges.first { $0.id == "total" }
        XCTAssertEqual(total?.used, 12.5)
        XCTAssertEqual(total?.limit, 50)
        XCTAssertNil(total?.window)
    }

    /// 没用过的窗口起点是 null:没有周期,而不是拿「现在 + 5 小时」编一个
    func testAnUnusedWindowHasNoPeriod() {
        guard let snap = snapshot(quotaLimitedUnused, now: "2026-09-28T15:30:00.000000+08:00") else { return }
        let fiveHours = snap.gauges.first { $0.id == "window_5h" }
        XCTAssertEqual(fiveHours?.limit, 5)
        XCTAssertNil(fiveHours?.window)
        XCTAssertNil(fiveHours?.rule)
    }

    /// 累计值取 actual_cost(按倍率算过、用户真正付的那个)
    func testTotalsComeFromUsageTotal() {
        guard let snap = snapshot(quotaLimited, now: "2026-09-28T15:30:00.000000+08:00") else { return }
        XCTAssertEqual(snap.totalCost, 12.5)
        XCTAssertEqual(snap.totalRequests, 90)
        XCTAssertEqual(snap.totalTokens, 450000)
    }

    // ── 订阅分组 ──────────────────────────────────────────

    /// 日重置按服务端时区的 0 点推算,时区取自时间戳的 +08:00 —— 标为推算
    func testSubscriptionDailyResetIsInferredAtTheServersMidnight() {
        guard let snap = snapshot(subscription, now: "2026-09-28T15:30:00.000000+08:00") else { return }
        let daily = snap.gauges.first { $0.id == "daily" }
        XCTAssertEqual(daily?.used, 3.2)
        XCTAssertEqual(daily?.window?.start, stamp("2026-09-28T00:00:00.000000+08:00"))
        XCTAssertEqual(daily?.window?.end, stamp("2026-09-29T00:00:00.000000+08:00"))
        XCTAssertEqual(daily?.window?.isInferred, true)
    }

    /// 周窗口 = 服务端给的起点 + 7×24h,不是自然周
    func testSubscriptionWeekRunsSevenDaysFromTheServersAnchor() {
        guard let snap = snapshot(subscription, now: "2026-09-28T15:30:00.000000+08:00") else { return }
        let weekly = snap.gauges.first { $0.id == "weekly" }
        XCTAssertEqual(weekly?.window?.start, stamp("2026-09-26T15:23:26.719278+08:00"))
        XCTAssertEqual(weekly?.window?.end, stamp("2026-10-03T15:23:26.719278+08:00"))
        XCTAssertEqual(weekly?.window?.isInferred, false)
    }

    /// 响应里没有月窗起点:只显示用量,不猜重置时刻
    func testSubscriptionMonthHasNoPeriodBecauseTheAnchorIsNotReported() {
        guard let snap = snapshot(subscription, now: "2026-09-28T15:30:00.000000+08:00") else { return }
        let monthly = snap.gauges.first { $0.id == "monthly" }
        XCTAssertEqual(monthly?.used, 60)
        XCTAssertEqual(monthly?.limit, 150)
        XCTAssertNil(monthly?.window)
        XCTAssertEqual(snap.name, "lab-subscription")
    }

    /// 上限为 null 的那一档不限额 —— 不产出桶
    func testASubscriptionPeriodWithoutALimitIsNotShown() {
        let noMonthly = subscription.replacingOccurrences(of: #""monthly_limit_usd": 150"#,
                                                          with: #""monthly_limit_usd": null"#)
        guard let snap = snapshot(noMonthly, now: "2026-09-28T15:30:00.000000+08:00") else { return }
        XCTAssertEqual(snap.gauges.map(\.id), ["daily", "weekly"])
    }

    // ── 抓取路径 ──────────────────────────────────────────

    /// 用户粘的 Base URL 可能带 /v1;用量接口在站点根上,key 走 Bearer
    func testTheRequestGoesToTheSiteRootWithTheKey() {
        let stub = StubTransport.ok(quotaLimited)
        let adapter = Sub2APIProvider(transport: stub)
        guard let connection = adapter.parseConnection(site: site, key: "sk-lab") else { return XCTFail("解析不出连接") }
        _ = try? runAsync { try await adapter.fetchUsage(connection, schedule: ResetSchedule(), language: .zhHans) }
        XCTAssertEqual(stub.requests.first?.url?.absoluteString, "https://relay.example.com/v1/usage")
        XCTAssertEqual(stub.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-lab")
    }

    /// 钱包余额没有周期,不在接入范围内 —— 说清楚,而不是显示一个空面板
    func testAWalletOnlyKeyIsRejectedWithAClearMessage() {
        let adapter = Sub2APIProvider(transport: StubTransport.ok(wallet))
        guard let connection = adapter.parseConnection(site: site, key: "sk-lab") else { return XCTFail("解析不出连接") }
        XCTAssertThrowsError(try runAsync {
            try await adapter.fetchUsage(connection, schedule: ResetSchedule(), language: .zhHans)
        }) { error in
            XCTAssertEqual((error as? APIError)?.message, L10n.text(.errSub2apiWalletMode, .zhHans))
        }
    }

    /// 失败响应有两种格式,实测都见过;对方给的原因要原样带给用户
    func testBothFailureShapesSurfaceTheServersMessage() {
        let shapes: [(Int, String, String)] = [
            (401, #"{"code":"INVALID_API_KEY","message":"Invalid API key"}"#, "Invalid API key"),
            (403, #"{"type":"error","error":{"message":"not assigned to any group","type":"permission_error"}}"#,
             "not assigned to any group"),
        ]
        for (status, body, expected) in shapes {
            let adapter = Sub2APIProvider(transport: StubTransport(outcome: .status(status, Data(body.utf8))))
            guard let connection = adapter.parseConnection(site: site, key: "sk-lab") else { return XCTFail("解析不出连接") }
            XCTAssertThrowsError(try runAsync {
                try await adapter.fetchUsage(connection, schedule: ResetSchedule(), language: .zhHans)
            }) { error in
                XCTAssertEqual((error as? APIError)?.message, expected)
            }
        }
    }

    // ── 身份 ──────────────────────────────────────────────

    /// 响应里没有账户 ID,身份是 key 的哈希:同 key 同身份、换 key 换身份,且不含 key 本身
    func testIdentityIsAStableHashOfTheKey() {
        guard let a = sub2api.parseConnection(site: site, key: "sk-lab-one") else { return XCTFail("解析不出连接") }
        guard let again = sub2api.parseConnection(site: site, key: "sk-lab-one") else { return XCTFail("解析不出连接") }
        guard let b = sub2api.parseConnection(site: site, key: "sk-lab-two") else { return XCTFail("解析不出连接") }
        XCTAssertEqual(a.account.apiId, again.account.apiId)
        XCTAssertNotEqual(a.account.apiId, b.account.apiId)
        XCTAssertEqual(a.account.apiId.count, 16)
        XCTAssertFalse(a.account.apiId.contains("sk-lab"))
        XCTAssertEqual(a.account.baseURL, "https://relay.example.com")
        XCTAssertEqual(a.secret, "sk-lab-one")
    }
}
