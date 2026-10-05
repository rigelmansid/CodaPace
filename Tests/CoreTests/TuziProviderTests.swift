import Foundation
import CodaPaceCore

//
//  TuziProviderTests.swift — tu-zi 适配器
//
//  下面这份 payload 的**形状**照抄真实响应(字段名、嵌套、时间戳格式、
//  空的 active_batches、为 null 的 window_1d_start 都原样保留),
//  但所有数值都是编的 —— 真实响应里有账户标识和消费金额,不进仓库。
//

private let tuzi = TuziProvider()

/// 一份完整的订阅响应。要改坏某一处时用 `payload(replacing:with:)`。
private let tuziPayload = #"""
{
  "code": 0,
  "message": "success",
  "data": {
    "concurrency": 8,
    "expires_at": "2026-10-17T11:18:35.132328+08:00",
    "fuel_pack": {
      "billing_mode": "subscription_first",
      "available_usd": 0,
      "active_batches": []
    },
    "key_id": 1001,
    "quota": 0,
    "quota_used": 0,
    "rate_limit_1d": 0,
    "rate_limit_7d": 0,
    "status": "active",
    "subscription": {
      "group_id": 8,
      "group_name": "Codex（月卡mini）",
      "status": "active",
      "activated": true,
      "expires_at": "2026-10-17T11:18:35.132328+08:00",
      "daily_used": 12.5,
      "daily_limit": 30,
      "weekly_used": 61.25,
      "weekly_limit": 150,
      "monthly_used": 61.25,
      "monthly_limit": 600,
      "daily_window_start": "2026-09-21T11:19:02.793995+08:00",
      "weekly_window_start": "2026-09-17T11:19:02.793995+08:00",
      "monthly_window_start": "2026-09-17T11:19:02.793995+08:00",
      "daily_reset_at": "2026-09-22T11:19:02.793995+08:00",
      "weekly_reset_at": "2026-09-24T11:19:02.793995+08:00",
      "monthly_reset_at": "2026-10-17T11:19:02.793995+08:00"
    },
    "usage_1d": 0,
    "usage_7d": 0,
    "window_1d_start": null,
    "window_7d_start": null
  }
}
"""#

private func payload(replacing old: String, with new: String) -> String {
    precondition(tuziPayload.contains(old), "锚点没命中,改坏的地方不是你以为的那处")
    return tuziPayload.replacingOccurrences(of: old, with: new)
}

private func decode(_ text: String = tuziPayload) throws -> TuziQuota {
    try TuziQuota.decode(Data(text.utf8), language: .en)
}

/// 日窗口正中间的某个时刻 —— 落在窗口里,`serverProvided` 才算得出周期
private let insideDailyWindow = ISO8601DateFormatter().date(from: "2026-09-21T23:00:00+08:00")!

private func snapshot(_ text: String = tuziPayload,
                      now: Date = insideDailyWindow) -> Snapshot {
    tuzi.buildSnapshot(try! decode(text), now: now)
}

// MARK: - 解码

final class TuziDecodingTests: XCTestCase {

    /// 账户身份来自响应里的 `key_id`,不是用户给的那把 key。
    /// 这样换一把 key 而 key_id 不变时,攒下的历史不会断。
    func testAccountIDComesFromKeyID() {
        XCTAssertEqual(try! decode().accountID, "1001")
    }

    func testDecodesTheThreeWindows() {
        let s = try! decode().subscription
        XCTAssertEqual(s.groupName, "Codex（月卡mini）")
        XCTAssertEqual(s.daily.used, 12.5, accuracy: 1e-9)
        XCTAssertEqual(s.daily.limit, 30, accuracy: 1e-9)
        XCTAssertEqual(s.weekly.limit, 150, accuracy: 1e-9)
        XCTAssertEqual(s.monthly.limit, 600, accuracy: 1e-9)
    }

    /// 带偏移和**微秒**的 ISO8601 要解得出来。
    /// 解不出来的后果不是报错,而是那条额度悄悄失去窗口、不再有倒计时和速度判断。
    func testParsesMicrosecondTimestampsWithOffset() {
        let start = try! decode().subscription.daily.start
        XCTAssertNotNil(start, "微秒精度的时间戳必须解得出来")
        XCTAssertEqual(start?.timeIntervalSince1970 ?? -1,
                       ISO8601DateFormatter().date(from: "2026-09-21T11:19:02+08:00")!
                           .timeIntervalSince1970,
                       accuracy: 1.0)
    }

    /// 对方哪天省掉小数位,不该让整条额度消失
    func testAlsoParsesTimestampsWithoutFractionalSeconds() {
        let text = payload(replacing: "\"2026-09-21T11:19:02.793995+08:00\"",
                           with: "\"2026-09-21T11:19:02+08:00\"")
        XCTAssertNotNil(try! decode(text).subscription.daily.start)
    }

    /// 信封是 `{code, message, data}`,不是中转站那套 `{success, data}`。
    /// code 非 0 时要把**对方给的原因**报出来。
    func testNonZeroCodeSurfacesTheServerMessage() {
        let text = payload(replacing: "\"code\": 0", with: "\"code\": 401")
            .replacingOccurrences(of: "\"message\": \"success\"",
                                  with: "\"message\": \"invalid api key\"")
        XCTAssertThrowsError(try decode(text)) { error in
            XCTAssertEqual((error as? APIError)?.message, "invalid api key")
        }
    }

    /// 数字位置上是非数字字符串 —— 整份拒绝,并点名是哪个字段
    func testNonNumericUsageIsRejectedByName() {
        let text = payload(replacing: "\"daily_used\": 12.5", with: "\"daily_used\": \"abc\"")
        XCTAssertThrowsError(try decode(text)) { error in
            XCTAssertTrue((error as? APIError)?.message.contains("daily_used") ?? false)
        }
    }

    func testGarbageResponseGivesAReadableError() {
        XCTAssertThrowsError(try decode("<html>502</html>")) { error in
            XCTAssertNotNil((error as? APIError)?.message)
        }
    }
}

// MARK: - 映射

final class TuziSnapshotTests: XCTestCase {

    func testBuildsThreeBucketsInDisplayOrder() {
        XCTAssertEqual(snapshot().gauges.map(\.id), ["daily", "weekly", "monthly"])
    }

    /// **证据不在这份 JSON 里,别只看它就把这条改回去。**
    ///
    /// `daily_used` 没有任何单位标记,整份响应只有 `fuel_pack.available_usd`
    /// 带了 `_usd`。单看 JSON 的结论只能是「不知道单位」。
    ///
    /// 但供应商自己的用量页面把**同一个数字**显示成 `$12.50 / $30.00` ——
    /// 单位是对方在另一个渠道说明的,不是我们替它发明的。「不发明数据」禁止的是
    /// 编造,不是禁止采信供应商自己的声明。
    ///
    /// 这条要是哪天翻回 `.unknown`,得先拿出新证据(比如页面改成了别的币种),
    /// 而不是因为「JSON 里没写」。
    func testAmountsAreUSDPerTheProvidersOwnUsagePage() {
        let daily = snapshot().bucket(id: "daily")
        XCTAssertEqual(daily?.unit, .money(currency: "USD"))
        XCTAssertEqual(daily?.amount(12.5), "$12.50")
    }

    /// 服务端自己就给重置时刻,就不该再去「观测学习」它 ——
    /// 对着一个已知事实学出来的只会比对方给的更差
    func testNeedsNoDailyResetLearning() {
        XCTAssertNil(tuzi.learnableDailyBucketID)
    }

    /// 没有累计 token、没有历史接口,也就不该声明有
    func testDeclaresTheThingsItDoesNotProvide() {
        XCTAssertFalse(tuzi.capabilities.contains(.cumulativeTokens))
        XCTAssertFalse(tuzi.capabilities.contains(.usageHistory))
    }

    /// 重置一律 serverProvided:对方每次都给 reset_at,不需要推,也推不出来 ——
    /// 日窗口恰好是 +24 小时整,固定时长和日历规则一份样例分不出来(EXT-004)
    func testResetRuleIsServerProvidedAndNotExtrapolated() {
        let rule = snapshot().bucket(id: "daily")?.rule
        XCTAssertEqual(rule?.provenance, .server)

        guard case .serverProvided = rule?.policy else {
            return XCTFail("日额度的重置必须是服务端给的那一段,不能外推")
        }
    }

    /// 窗口就是服务端给的那两个时刻,一秒都不该挪
    func testWindowUsesTheExactTimestampsTheServerGave() {
        let window = snapshot().bucket(id: "daily")?.window
        let expectedStart = ISO8601DateFormatter().date(from: "2026-09-21T11:19:02+08:00")!
        let expectedEnd = ISO8601DateFormatter().date(from: "2026-09-22T11:19:02+08:00")!

        XCTAssertEqual(window?.start.timeIntervalSince1970 ?? -1,
                       expectedStart.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(window?.end.timeIntervalSince1970 ?? -1,
                       expectedEnd.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertFalse(window?.isInferred ?? true, "服务端给的时刻不是推算值")
    }

    /// 顶层的 quota / quota_used / rate_limit_* / usage_* 全部忽略。
    ///
    /// 它们是另一条计费路径的字段,配合 `billing_mode: "subscription_first"`
    /// 和为 null 的 `window_1d_start` 可判断当前未启用 ——
    /// **「不适用」不是「用了 0」**,不能据此产出一条假额度。
    func testTheUnusedBillingPathProducesNoBuckets() {
        XCTAssertEqual(snapshot().gauges.count, 3)
        XCTAssertNil(snapshot().bucket(id: "quota"))
        XCTAssertNil(snapshot().bucket(id: "window"))
    }

    /// fuel_pack 也不产出桶:它是**余额**,没有「上限」可言。
    /// 拿 available_usd 当 limit 会让它永远显示剩余 100%(花掉多少,上限就跟着掉多少)。
    func testTheFuelPackBalanceIsNotForcedIntoAQuotaBucket() {
        XCTAssertNil(snapshot().bucket(id: "fuelPack"))
    }

    /// 这家一个累计值都不报 —— 传 nil 而不是 0,面板据此整行不显示。
    /// 报 0 会被读成「一次请求都没发过」。
    func testUnreportedTotalsAreNilNotZero() {
        let s = snapshot()
        XCTAssertNil(s.totalTokens)
        XCTAssertNil(s.totalRequests)
        XCTAssertNil(s.totalCost)
    }

    /// 月额度已经是一个桶了,不该在 monthlyCost 里再报一遍 ——
    /// 同一个数字出现在两处,用户会以为是两件事
    func testMonthlyIsABucketNotADuplicatedSummary() {
        XCTAssertNotNil(snapshot().bucket(id: "monthly"))
        XCTAssertNil(snapshot().monthlyCost)
    }

    /// 周和月的用量相等是**真实形状**:订阅 09-17 激活,同一笔消费落在两个窗口里。
    /// 两条同时展示,但绝不能相加。
    func testOverlappingWindowsAreBothShownAndNotSummed() {
        let s = snapshot()
        XCTAssertEqual(s.bucket(id: "weekly")?.used ?? -1, 61.25, accuracy: 1e-9)
        XCTAssertEqual(s.bucket(id: "monthly")?.used ?? -1, 61.25, accuracy: 1e-9)
    }

    /// 套餐名当账户名用 —— 它是个套餐名,不是额度名,不该进桶的标题
    func testTheSubscriptionNameBecomesTheAccountName() {
        XCTAssertEqual(snapshot().name, "Codex（月卡mini）")
    }
}

// MARK: - 缺数据

final class TuziMissingDataTests: XCTestCase {

    /// 对方没报某一层,那一层就**不产出桶**,而不是产出一条用量为 0 的额度
    func testAnUnreportedWindowProducesNoBucket() {
        let text = payload(replacing: "\"monthly_used\": 61.25,", with: "")
            .replacingOccurrences(of: "\"monthly_limit\": 600,", with: "")

        XCTAssertEqual(snapshot(text).gauges.map(\.id), ["daily", "weekly"])
    }

    /// 半份的窗口(报了用量没报上限)整层丢掉,**不猜那个缺的上限**。
    ///
    /// `QuotaBucket.limit` 里的 0 意思是「不限额」,拿它顶替「不知道」
    /// 会把一条有限额的额度显示成无限 —— 剩余百分比永远 100%。
    func testAHalfReportedWindowIsDroppedRatherThanGuessed() {
        let text = payload(replacing: "\"daily_limit\": 30,", with: "")
        XCTAssertNil(snapshot(text).bucket(id: "daily"))
        XCTAssertEqual(snapshot(text).gauges.map(\.id), ["weekly", "monthly"])
    }

    /// null 和缺失同等对待
    func testANullLimitIsTreatedAsUnreported() {
        let text = payload(replacing: "\"daily_limit\": 30", with: "\"daily_limit\": null")
        XCTAssertNil(snapshot(text).bucket(id: "daily"))
    }

    /// 一层额度都没有时不该进历史 —— 那不是「今天没用」,
    /// 是这份响应里根本没有额度信息
    func testASubscriptionlessResponseIsNotComplete() {
        let text = payload(replacing: "\"subscription\": {", with: "\"unused\": {")
        XCTAssertFalse(snapshot(text).hasCompleteUsage)
        XCTAssertEqual(snapshot(text).gauges.count, 0)
    }

    func testAResponseWithQuotasIsComplete() {
        XCTAssertTrue(snapshot().hasCompleteUsage)
    }

    /// 时刻解不出来时那条额度照样有用量,只是没有窗口 ——
    /// 不做速度判断,而不是整条消失
    func testAnUnparsableTimestampCostsTheWindowNotTheQuota() {
        let text = payload(replacing: "\"daily_reset_at\": \"2026-09-22T11:19:02.793995+08:00\"",
                           with: "\"daily_reset_at\": \"not a date\"")
        let daily = snapshot(text).bucket(id: "daily")

        XCTAssertEqual(daily?.used ?? -1, 12.5, accuracy: 1e-9)
        XCTAssertNil(daily?.window)
        XCTAssertEqual(daily?.pace(now: insideDailyWindow), .unavailable)
    }
}

// MARK: - 识别与身份

final class TuziConnectionTests: XCTestCase {

    private let key = "sk-abcdef0123456789"

    func testParsesAnApiKeyIntoAConnectionCarryingTheSecret() {
        let connection = tuzi.parseConnection(key)
        XCTAssertEqual(connection?.secret, key)
        XCTAssertEqual(connection?.account.providerID, TuziProvider.id)
    }

    func testTolerratesSurroundingWhitespace() {
        XCTAssertEqual(tuzi.parseConnection("  \(key)\n")?.secret, key)
    }

    func testRejectsThingsThatAreNotKeys() {
        XCTAssertNil(tuzi.parseConnection(""))
        XCTAssertNil(tuzi.parseConnection("https://example.com/admin-next/api-stats?apiId=k"))
        XCTAssertNil(tuzi.parseConnection("sk-"))
        XCTAssertNil(tuzi.parseConnection("sk- has spaces"))
    }

    /// 身份在响应里,不在输入里 —— 解析出来的只能是占位值
    func testTheParsedIdentityIsOnlyAPlaceholder() {
        XCTAssertTrue(tuzi.accountIDComesFromResponse)
        XCTAssertEqual(tuzi.parseConnection(key)?.account.apiId,
                       AccountIdentity.unresolvedAccountID)
    }

    /// 密钥能花钱,只能声明 .secret —— 于是明文存储那道守卫会把它挡住
    func testAnApiKeyMayNotReusePlainTextStorage() {
        XCTAssertEqual(tuzi.credentialSensitivity, .secret)
        XCTAssertFalse(ProviderRegistry.canStoreInPlainText(tuzi))
    }

    /// 一把 key 和一个中转站网址不会互相认错
    func testTheTwoAdaptersDoNotClaimEachOthersInput() {
        XCTAssertEqual(ProviderRegistry.parse(key)?.adapter.providerID, TuziProvider.id)
        XCTAssertEqual(
            ProviderRegistry.parse("https://a.example.com/admin-next/api-stats?apiId=k")?
                .adapter.providerID,
            RelayProvider.id)
    }

    /// **密钥不许出现在任何字符串里** —— 错误信息、日志、断言失败都会走到这儿
    func testTheConnectionDescriptionNeverLeaksTheSecret() {
        let description = String(describing: tuzi.parseConnection(key)!)
        XCTAssertFalse(description.contains(key))
        XCTAssertFalse(description.contains("sk-"))
    }
}

// MARK: - 保存前解析身份

final class ResolvedForSavingTests: XCTestCase {

    private let key = "sk-abcdef0123456789"

    private func report(accountID: String?, providerID: String = TuziProvider.id) -> ConnectionReport {
        ConnectionReport(providerID: providerID, displayName: "tu-zi",
                         accountName: "Codex", isActive: true,
                         stableAccountID: accountID,
                         capabilities: [], findings: [])
    }

    /// 没跑过 verify 就没有身份 —— 不给保存,而不是编一个。
    /// 编出来的那个会在真身份到手的那天把历史和偏好劈成两半。
    func testAnUnverifiedSecretConnectionCannotBeSaved() {
        let connection = tuzi.parseConnection(key)!
        XCTAssertNil(ProviderRegistry.resolvedForSaving(connection, report: nil))
    }

    func testVerificationReplacesThePlaceholderWithTheRealAccountID() {
        let connection = tuzi.parseConnection(key)!
        let saved = ProviderRegistry.resolvedForSaving(connection, report: report(accountID: "1001"))

        XCTAssertEqual(saved?.account.apiId, "1001")
        XCTAssertTrue(saved?.account.isConfigured ?? false)
        XCTAssertEqual(saved?.secret, key, "换身份不该把密钥弄丢")
    }

    /// 报告里没带账户标识就等于没验出来
    func testAReportWithoutAnAccountIDDoesNotUnlockSaving() {
        let connection = tuzi.parseConnection(key)!
        XCTAssertNil(ProviderRegistry.resolvedForSaving(connection, report: report(accountID: nil)))
        XCTAssertNil(ProviderRegistry.resolvedForSaving(connection, report: report(accountID: "")))
    }

    /// 界面上残留的**上一家**的报告不算数 —— 否则会把别家的身份安到这个连接上
    func testAReportFromAnotherProviderIsNotAccepted() {
        let connection = tuzi.parseConnection(key)!
        XCTAssertNil(ProviderRegistry.resolvedForSaving(
            connection, report: report(accountID: "1001", providerID: RelayProvider.id)))
    }

    /// 身份就在输入里的适配器不受影响:没跑过 verify 也照样能保存
    func testTheRelayCanBeSavedWithoutVerifying() {
        let connection = RelayProvider()
            .parseConnection("https://a.example.com/admin-next/api-stats?apiId=k")!
        let saved = ProviderRegistry.resolvedForSaving(connection, report: nil)

        XCTAssertEqual(saved?.account.apiId, "k")
    }
}
