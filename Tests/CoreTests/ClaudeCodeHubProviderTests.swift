import Foundation
import CodaPaceCore

//
//  ClaudeCodeHubProviderTests.swift — claude-code-hub 适配器
//
//  payload 的**形状**照抄 2026-09-28 本机部署 v0.9.6 实测的 `/api/v1/me/quota` 响应
//  (字段名、为 null 的上限、`dailyResetMode` / `dailyResetTime` 都原样保留),数值是编的。
//  登录流程的桩照抄实测的行为:opaque 模式下 key 直接查返回 401,登录回 `Set-Cookie: auth-token=sid_…`。
//

/// key 级和账户级都设了上限,key 的日重置固定在 04:00
private let fixedQuota = #"""
{"keyLimit5hUsd":5,"keyLimitDailyUsd":20,"keyLimitWeeklyUsd":60,"keyLimitMonthlyUsd":200,"keyLimitTotalUsd":500,
 "keyLimitConcurrentSessions":0,"keyCurrent5hUsd":1.5,"keyCurrentDailyUsd":6,"keyCurrentWeeklyUsd":18,
 "keyCurrentMonthlyUsd":44,"keyCurrentTotalUsd":90,"keyCurrentConcurrentSessions":0,
 "userLimit5hUsd":10,"userLimitWeeklyUsd":100,"userLimitMonthlyUsd":300,"userLimitTotalUsd":1000,
 "userLimitConcurrentSessions":null,"userRpmLimit":null,"userCurrent5hUsd":2,"userCurrentDailyUsd":7,
 "userCurrentWeeklyUsd":25,"userCurrentMonthlyUsd":60,"userCurrentTotalUsd":120,"userCurrentConcurrentSessions":0,
 "userLimitDailyUsd":30,"userExpiresAt":null,"userProviderGroup":"default","userName":"lab-user","userIsEnabled":true,
 "keyProviderGroup":"default","keyName":"lab-fixed","keyIsEnabled":true,"userAllowedModels":[],"userAllowedClients":[],
 "expiresAt":null,"dailyResetMode":"fixed","dailyResetTime":"04:00"}
"""#

private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

private func stamp(_ text: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: text)!
}

private let now = stamp("2026-09-28T15:30:00+08:00")   // 周一
private let hub = ClaudeCodeHubProvider()

private func snapshot(_ json: String, timeZone: TimeZone? = shanghai,
                      file: StaticString = #filePath, line: UInt = #line) -> Snapshot? {
    do {
        let quota = try ClaudeCodeHubQuota.decode(Data(json.utf8), language: .zhHans)
        return hub.buildSnapshot(quota, timeZone: timeZone, now: now)
    } catch {
        XCTFail("解码失败:\(error)", file: file, line: line)
        return nil
    }
}

private func bucket(_ snap: Snapshot, _ id: String) -> QuotaBucket? {
    snap.gauges.first { $0.id == id }
}

// MARK: - 按请求回话的桩

/// 登录流程要按「哪个路径、带的什么令牌」分别回话,单一结果的 StubTransport 不够用
private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    typealias Reply = (status: Int, body: String, headers: [String: String])
    let script: (URLRequest) -> Reply
    var requests: [URLRequest] = []

    init(_ script: @escaping (URLRequest) -> Reply) { self.script = script }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let reply = script(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: nil, headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }

    var logins: Int { requests.filter { $0.url?.path == "/api/auth/login" }.count }
}

/// 一个 opaque 模式的站点:只认 `validSession`,key 直接查一律 401
private func opaqueSite(validSession: String, issuing newSession: String) -> ScriptedTransport {
    ScriptedTransport { req in
        let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
        switch req.url?.path {
        case "/api/auth/login":
            return (200, #"{"ok":true}"#, ["Set-Cookie": "auth-token=\(newSession); Path=/; Max-Age=604800; HttpOnly"])
        case "/api/v1/me/quota" where auth == "Bearer \(validSession)" || auth == "Bearer \(newSession)":
            return (200, fixedQuota, [:])
        case "/api/v1/system/timezone" where auth == "Bearer \(validSession)" || auth == "Bearer \(newSession)":
            return (200, #"{"timeZone":"Asia/Shanghai"}"#, [:])
        default:
            return (401, #"{"title":"Unauthorized","detail":"Authentication is invalid or expired."}"#, [:])
        }
    }
}

private let site = URLComponents(string: "https://hub.example.com/v1")!

final class ClaudeCodeHubProviderTests: XCTestCase {

    // ── 额度映射 ──────────────────────────────────────────

    /// 两层都设了上限:十条,标题带上是哪一层
    func testBothLayersBecomeScopedBuckets() {
        guard let snap = snapshot(fixedQuota) else { return }
        XCTAssertEqual(snap.gauges.map(\.id), ["key_5h", "key_daily", "key_weekly", "key_monthly", "key_total",
                                               "user_5h", "user_daily", "user_weekly", "user_monthly", "user_total"])
        XCTAssertEqual(bucket(snap, "key_weekly")?.title, .scoped(scope: .quotaScopeKey, period: .quotaWeekly))
        XCTAssertEqual(bucket(snap, "user_monthly")?.title, .scoped(scope: .quotaScopeAccount, period: .quotaMonthly))
        XCTAssertEqual(bucket(snap, "user_daily")?.used, 7)
        XCTAssertEqual(snap.name, "lab-user")
    }

    /// 上限为 null 的那一档不限 —— 不产出桶(没设 key 级限额的 key 只剩账户那层)
    func testUnsetLimitsProduceNoBucket() {
        let keyWithoutLimits = fixedQuota
            .replacingOccurrences(of: #""keyLimit5hUsd":5,"keyLimitDailyUsd":20,"keyLimitWeeklyUsd":60,"keyLimitMonthlyUsd":200,"keyLimitTotalUsd":500"#,
                                  with: #""keyLimit5hUsd":null,"keyLimitDailyUsd":null,"keyLimitWeeklyUsd":null,"keyLimitMonthlyUsd":null,"keyLimitTotalUsd":null"#)
        guard let snap = snapshot(keyWithoutLimits) else { return }
        XCTAssertEqual(snap.gauges.map(\.id), ["user_5h", "user_daily", "user_weekly", "user_monthly", "user_total"])
    }

    /// key 的固定日重置:服务端给的时刻 + 服务端的时区,不是推算
    func testTheKeysFixedDailyResetUsesTheServersTimeAndZone() {
        guard let snap = snapshot(fixedQuota) else { return }
        let daily = bucket(snap, "key_daily")
        XCTAssertEqual(daily?.window?.start, stamp("2026-09-28T04:00:00+08:00"))
        XCTAssertEqual(daily?.window?.end, stamp("2026-09-29T04:00:00+08:00"))
        XCTAssertEqual(daily?.window?.isInferred, false)
    }

    /// 滚动的日额度没有统一归零时刻:不给周期,标题也不写「今日」
    func testARollingDailyQuotaHasNoPeriod() {
        let rolling = fixedQuota.replacingOccurrences(of: #""dailyResetMode":"fixed","dailyResetTime":"04:00""#,
                                                      with: #""dailyResetMode":"rolling","dailyResetTime":"00:00""#)
        guard let snap = snapshot(rolling) else { return }
        XCTAssertNil(bucket(snap, "key_daily")?.window)
        XCTAssertEqual(bucket(snap, "key_daily")?.title, .scoped(scope: .quotaScopeKey, period: .quotaOneDay))
    }

    /// 周、月:服务端时区的自然周(周一 0 点)、自然月(1 号 0 点)
    func testWeeksAndMonthsFollowTheServersCalendar() {
        guard let snap = snapshot(fixedQuota) else { return }
        XCTAssertEqual(bucket(snap, "user_weekly")?.window?.start, stamp("2026-09-28T00:00:00+08:00"))
        XCTAssertEqual(bucket(snap, "user_weekly")?.window?.end, stamp("2026-10-05T00:00:00+08:00"))
        XCTAssertEqual(bucket(snap, "key_monthly")?.window?.start, stamp("2026-09-01T00:00:00+08:00"))
        XCTAssertEqual(bucket(snap, "key_monthly")?.window?.end, stamp("2026-10-01T00:00:00+08:00"))
    }

    /// 响应里没说的规则(5 小时的方式、账户的日重置)和总额:只显示用量,不给 pace
    func testRulesTheResponseDoesNotStateGetNoPeriod() {
        guard let snap = snapshot(fixedQuota) else { return }
        for id in ["key_5h", "user_5h", "user_daily", "key_total", "user_total"] {
            XCTAssertNil(bucket(snap, id)?.window, id)
        }
    }

    /// 时区查不到时不拿本机时区顶上 —— 哪条都不给周期
    func testWithoutTheServersTimeZoneNothingGetsAPeriod() {
        guard let snap = snapshot(fixedQuota, timeZone: nil) else { return }
        XCTAssertTrue(snap.gauges.allSatisfy { $0.window == nil })
    }

    // ── 认证流程 ──────────────────────────────────────────

    /// 存着的会话还有效:直接用,**不登录**(每登录一次站点就多一条记录)
    func testAStoredSessionIsReusedWithoutLoggingIn() {
        let sessions = InMemorySessionTokenStore()
        let transport = opaqueSite(validSession: "sid_old", issuing: "sid_new")
        let adapter = ClaudeCodeHubProvider(transport: transport, sessions: sessions)
        guard let connection = adapter.parseConnection(site: site, key: "sk-lab") else { return XCTFail("解析不出连接") }
        sessions.setToken("sid_old", for: connection.account)

        _ = try? runAsync { try await adapter.fetchUsage(connection, schedule: ResetSchedule(), language: .zhHans) }
        XCTAssertEqual(transport.logins, 0)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sid_old")
    }

    /// key 被拒(opaque 站点):登录**一次**,把会话存起来,接着用它查额度和时区
    func testWhenTheKeyIsRefusedItLogsInOnceAndKeepsTheSession() {
        let sessions = InMemorySessionTokenStore()
        let transport = opaqueSite(validSession: "sid_unused", issuing: "sid_new")
        let adapter = ClaudeCodeHubProvider(transport: transport, sessions: sessions)
        guard let connection = adapter.parseConnection(site: site, key: "sk-lab") else { return XCTFail("解析不出连接") }

        let snap = try? runAsync { try await adapter.fetchUsage(connection, schedule: ResetSchedule(), language: .zhHans) }
        XCTAssertEqual(transport.logins, 1)
        XCTAssertEqual(sessions.token(for: connection.account), "sid_new")
        XCTAssertEqual(snap?.gauges.count, 10)
        // 时区也拿到了,于是周额度有周期
        XCTAssertNotNil(snap?.gauges.first { $0.id == "key_weekly" }?.window)
    }

    /// 存着的会话过期了:换一个新的,旧的不留
    func testAnExpiredSessionIsReplaced() {
        let sessions = InMemorySessionTokenStore()
        let transport = opaqueSite(validSession: "sid_current", issuing: "sid_fresh")
        let adapter = ClaudeCodeHubProvider(transport: transport, sessions: sessions)
        guard let connection = adapter.parseConnection(site: site, key: "sk-lab") else { return XCTFail("解析不出连接") }
        sessions.setToken("sid_expired", for: connection.account)

        _ = try? runAsync { try await adapter.fetchUsage(connection, schedule: ResetSchedule(), language: .zhHans) }
        XCTAssertEqual(transport.logins, 1)
        XCTAssertEqual(sessions.token(for: connection.account), "sid_fresh")
    }

    /// legacy / dual 模式的站点直接认 key:不登录,也不存任何会话
    func testASiteThatAcceptsTheKeyNeedsNoLogin() {
        let sessions = InMemorySessionTokenStore()
        let transport = ScriptedTransport { req in
            req.url?.path == "/api/v1/me/quota" ? (200, fixedQuota, [:]) : (200, #"{"timeZone":"Asia/Shanghai"}"#, [:])
        }
        let adapter = ClaudeCodeHubProvider(transport: transport, sessions: sessions)
        guard let connection = adapter.parseConnection(site: site, key: "sk-lab") else { return XCTFail("解析不出连接") }

        _ = try? runAsync { try await adapter.fetchUsage(connection, schedule: ResetSchedule(), language: .zhHans) }
        XCTAssertEqual(transport.logins, 0)
        XCTAssertNil(sessions.token(for: connection.account))
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://hub.example.com/api/v1/me/quota")
    }

    /// key 错了:登录被拒,站点给的原因原样带给用户
    func testABadKeySurfacesTheLoginError() {
        let transport = ScriptedTransport { req in
            req.url?.path == "/api/auth/login"
                ? (401, #"{"error":"API Key 无效或已过期","errorCode":"KEY_INVALID"}"#, [:])
                : (401, #"{"detail":"Authentication is invalid or expired."}"#, [:])
        }
        let adapter = ClaudeCodeHubProvider(transport: transport, sessions: InMemorySessionTokenStore())
        guard let connection = adapter.parseConnection(site: site, key: "sk-wrong") else { return XCTFail("解析不出连接") }

        XCTAssertThrowsError(try runAsync {
            try await adapter.fetchUsage(connection, schedule: ResetSchedule(), language: .zhHans)
        }) { error in
            XCTAssertEqual((error as? APIError)?.message, "API Key 无效或已过期")
        }
    }

    /// 登录请求不让 URLSession 自己存 cookie —— 那会留下一份没人管的、能用 7 天的凭据
    func testLoginKeepsTheSessionOutOfTheCookieJar() {
        let transport = opaqueSite(validSession: "sid_unused", issuing: "sid_new")
        let adapter = ClaudeCodeHubProvider(transport: transport, sessions: InMemorySessionTokenStore())
        guard let connection = adapter.parseConnection(site: site, key: "sk-lab") else { return XCTFail("解析不出连接") }

        _ = try? runAsync { try await adapter.fetchUsage(connection, schedule: ResetSchedule(), language: .zhHans) }
        let login = transport.requests.first { $0.url?.path == "/api/auth/login" }
        XCTAssertEqual(login?.httpShouldHandleCookies, false)
    }

    // ── 身份 ──────────────────────────────────────────────

    /// 和 sub2api 同一套:key 的哈希当身份,请求发往站点根
    func testIdentityIsTheKeyHashAtTheSiteRoot() {
        guard let connection = hub.parseConnection(site: site, key: "sk-lab") else { return XCTFail("解析不出连接") }
        XCTAssertEqual(connection.account.apiId, AccountIdentity.hashedKeyID("sk-lab"))
        XCTAssertEqual(connection.account.baseURL, "https://hub.example.com")
        XCTAssertEqual(connection.account.providerID, ClaudeCodeHubProvider.id)
    }

    // ── 缺字段(OPT-015)────────────────────────────────────

    /// 有上限、没报已用:面板照旧按 0 显示,但不能进历史 —— 0 和「不知道」在库里是两件事
    func testALimitWithoutItsUsageIsNotStoredAsZero() {
        let missing = fixedQuota.replacingOccurrences(of: #""keyCurrentDailyUsd":6,"#, with: "")
        XCTAssertNotEqual(missing, fixedQuota, "替换锚点没命中")
        guard let snap = snapshot(missing) else { return }
        XCTAssertFalse(snap.hasCompleteUsage)
        XCTAssertEqual(bucket(snap, "key_daily")?.used, 0)

        // 对照:字段齐全时是完整的
        XCTAssertEqual(snapshot(fixedQuota)?.hasCompleteUsage, true)
    }

    /// HTTP 200 的无关 JSON 不能被当成验证成功(OPT-016)。审查原样复现的就是这个:
    /// 站点对每个请求都回 `200 {"error":…}`,从前 verify 报成功,设置页就此停下不试 sub2api
    func testVerifyRejectsAnUnrelatedJSONObject() {
        for body in [#"{"error":{"message":"not found"}}"#, "{}"] {
            let adapter = ClaudeCodeHubProvider(transport: ScriptedTransport { _ in (200, body, [:]) },
                                                sessions: InMemorySessionTokenStore())
            guard let connection = adapter.parseConnection(site: site, key: "sk-lab") else { return XCTFail("解析不出连接") }
            XCTAssertThrowsError(try runAsync { try await adapter.verify(connection, language: .zhHans) }) { error in
                XCTAssertEqual((error as? APIError)?.message,
                               L10n.format(.errNotThisProtocolFormat, .zhHans, "claude-code-hub"), body)
            }
        }
    }

    /// 测试连接换来的会话不进正式存储(OPT-017)。从前登录一成功就写进 `SessionTokens.store` ——
    /// App 里那是钥匙串 —— 发生在额度请求之前,取消或失败都会留下一份能用 7 天的凭据
    func testAScopedVerifyKeepsTheSessionOutOfTheSharedStore() {
        let shared = InMemorySessionTokenStore()
        let previous = SessionTokens.store
        SessionTokens.store = shared
        defer { SessionTokens.store = previous }

        let scratch = InMemorySessionTokenStore()
        let adapter = ClaudeCodeHubProvider(transport: opaqueSite(validSession: "sid_old", issuing: "sid_new"))
        guard let connection = adapter.parseConnection(site: site, key: "sk-lab") else { return XCTFail("解析不出连接") }

        do { _ = try runAsync { try await adapter.sessionScoped(to: scratch).verify(connection, language: .zhHans) } }
        catch { return XCTFail("验证失败:\(error)") }
        XCTAssertEqual(scratch.token(for: connection.account), "sid_new")
        XCTAssertNil(shared.token(for: connection.account))
    }

    /// 不用会话的适配器原样返回自己 —— 通用层可以对谁都这么调,不必认识哪家要会话
    func testAdaptersWithoutSessionsIgnoreTheScope() {
        let scoped = Sub2APIProvider().sessionScoped(to: InMemorySessionTokenStore())
        XCTAssertEqual(scoped.providerID, Sub2APIProvider.id)
        XCTAssertTrue(scoped is Sub2APIProvider)
    }

    /// 上限是 null 的那一档本来就不出桶,它的已用缺不缺都不影响完整性
    func testAMissingUsageOnAnUnlimitedTierDoesNotCount() {
        let unlimited = fixedQuota
            .replacingOccurrences(of: #""keyLimitDailyUsd":20,"#, with: #""keyLimitDailyUsd":null,"#)
            .replacingOccurrences(of: #""keyCurrentDailyUsd":6,"#, with: "")
        guard let snap = snapshot(unlimited) else { return }
        XCTAssertNil(bucket(snap, "key_daily"))
        XCTAssertTrue(snap.hasCompleteUsage)
    }
}
