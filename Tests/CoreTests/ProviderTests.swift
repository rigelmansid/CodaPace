import Foundation
import CodaPaceCore

private let relay = RelayProvider()
private let statsURL = "https://api.example.com/admin-next/api-stats?apiId=abc123"

// MARK: - 适配器:识别与解析

final class RelayProviderTests: XCTestCase {

    func testIdentityIsStableAndNotTheDisplayName() {
        XCTAssertEqual(relay.providerID, "claude-relay-service")
        // 展示名会随措辞和本地化变,所以配置里存的必须是 providerID
        XCTAssertEqual(ProviderRegistry.adapter(id: relay.providerID)?.providerID, relay.providerID)
    }

    // ── detect:只是候选提示 ──────────────────────────────

    func testDetectsTheStatsPagePath() {
        XCTAssertTrue(relay.detect(statsURL))
    }

    /// 刻意不看域名:自建中转站什么域名都有,拿域名判断既会漏也会误
    func testDetectIgnoresTheDomain() {
        XCTAssertTrue(relay.detect("https://totally-unrelated.invalid/admin-next/api-stats?apiId=k"))
        XCTAssertFalse(relay.detect("https://api.example.com/"))
    }

    func testDetectRejectsNonSense() {
        XCTAssertFalse(relay.detect(""))
        XCTAssertFalse(relay.detect("https://example.com/dashboard"))
    }

    // ── parseConnection ────────────────────────────────

    func testParsesSchemeHostAndApiId() {
        let account = relay.parseConnection(statsURL)?.account
        XCTAssertEqual(account?.providerID, relay.providerID)
        XCTAssertEqual(account?.baseURL, "https://api.example.com")
        XCTAssertEqual(account?.apiId, "abc123")
        XCTAssertTrue(account?.isConfigured ?? false)
    }

    /// 这家的 apiId 是身份本身,不是密钥 —— 解析出来不该附带任何凭据
    func testTheRelayConnectionCarriesNoSecret() {
        XCTAssertNil(relay.parseConnection(statsURL)?.secret)
    }

    /// 身份就写在用户给的网址里,不必先跑一次请求才知道自己是谁
    func testTheRelayDoesNotNeedTheResponseToKnowItsAccountID() {
        XCTAssertFalse(relay.accountIDComesFromResponse)
    }

    /// 这家不报日重置时刻,得靠观测 —— 它得说出是哪条额度,
    /// 否则通用层只能写死一个额度名(不变量 6)
    func testTheRelayNamesTheQuotaWhoseDailyResetMustBeLearned() {
        XCTAssertEqual(relay.learnableDailyBucketID, "daily")
        XCTAssertFalse(relay.capabilities.contains(.dailyResetTime))
    }

    /// 自建部署常带非标准端口,不能丢
    func testKeepsANonStandardPort() {
        let account = relay.parseConnection("https://api.example.com:8443/admin-next/api-stats?apiId=k")?.account
        XCTAssertEqual(account?.baseURL, "https://api.example.com:8443")
    }

    func testMissingOrEmptyApiIdDoesNotParse() {
        XCTAssertNil(relay.parseConnection("https://api.example.com/admin-next/api-stats"))
        XCTAssertNil(relay.parseConnection("https://api.example.com/admin-next/api-stats?apiId="))
    }

    func testSurroundingWhitespaceIsTolerated() {
        // 从浏览器地址栏复制常带换行
        XCTAssertEqual(relay.parseConnection("  \(statsURL)\n")?.account.apiId, "abc123")
    }

    // ── managementURL ─────────────────────────────────

    /// 后台地址由适配器构造 —— 它和统计接口不一定同源同路径
    func testManagementURLIsBuiltByTheAdapter() {
        let account = relay.parseConnection(statsURL)!.account
        XCTAssertEqual(relay.managementURL(for: account)?.absoluteString, statsURL)
    }

    func testNoManagementURLWithoutAConfiguredAccount() {
        XCTAssertNil(relay.managementURL(for: .none))
    }

    // ── capabilities ──────────────────────────────────

    func testDeclaresWhatTheRelayActuallyProvides() {
        XCTAssertTrue(relay.capabilities.contains(.costAmounts))
        XCTAssertTrue(relay.capabilities.contains(.cumulativeTokens))
        XCTAssertTrue(relay.capabilities.contains(.windowResetTimes))
        XCTAssertTrue(relay.capabilities.contains(.weeklyResetSchedule))
    }

    /// 这两个「不给」是有实际后果的,不是凑数:
    /// 没有日重置时刻 → app 自己观测并标注「推算」;
    /// 没有历史接口 → 历史只能从装上那天起本地积累。
    /// 能力声明要是全真,它就等于没声明。
    func testDeclaresTheTwoThingsTheRelayDoesNotProvide() {
        XCTAssertFalse(relay.capabilities.contains(.dailyResetTime))
        XCTAssertFalse(relay.capabilities.contains(.usageHistory))
    }
}

// MARK: - 注册表

final class ProviderRegistryTests: XCTestCase {

    func testResolvesByProviderID() {
        XCTAssertEqual(ProviderRegistry.adapter(id: RelayProvider.id)?.providerID, RelayProvider.id)
        XCTAssertNil(ProviderRegistry.adapter(id: "nope"))
    }

    /// 存量配置是在只有一个供应商的年代写下的,没有 providerID ——
    /// 取不到要退回兜底适配器,而不是让老用户的 app 罢工
    func testUnknownOrMissingProviderIDFallsBack() {
        let legacy = AccountIdentity(providerID: "", baseURL: "https://a.example.com", apiId: "k")
        XCTAssertEqual(ProviderRegistry.adapter(for: legacy).providerID, RelayProvider.id)

        let unknown = AccountIdentity(providerID: "some-future-provider",
                                      baseURL: "https://a.example.com", apiId: "k")
        XCTAssertEqual(ProviderRegistry.adapter(for: unknown).providerID, RelayProvider.id)
    }

    func testParseReturnsBothTheAdapterAndTheAccount() {
        let resolved = ProviderRegistry.parse(statsURL)
        XCTAssertEqual(resolved?.adapter.providerID, RelayProvider.id)
        XCTAssertEqual(resolved?.connection.account.apiId, "abc123")
        // 解析出的身份必须自带 providerID,否则存下去就不知道该谁来刷
        XCTAssertEqual(resolved?.connection.account.providerID, RelayProvider.id)
    }

    func testUnparsableInputResolvesToNothing() {
        XCTAssertNil(ProviderRegistry.parse("https://example.com/dashboard"))
        XCTAssertNil(ProviderRegistry.parse(""))
    }

    func testCandidatesAreFilteredByDetect() {
        XCTAssertEqual(ProviderRegistry.candidates(for: statsURL).count, 1)
        XCTAssertEqual(ProviderRegistry.candidates(for: "https://example.com/").count, 0)
    }

    // ── siteOwner:粘错了东西时指路 ──────────────────────────

    /// Coding Plan 的地址。用户从地址栏抄来的常常不带 `https://`
    func testATuziPageIsPointedToTheKey() {
        for page in ["coding.tu-zi.com", "https://store.tu-zi.com/user/usage/codex",
                     "https://api.tu-zi.com/coding"] {
            XCTAssertEqual(ProviderRegistry.siteOwner(for: page)?.providerID, TuziProvider.id, page)
        }
        XCTAssertEqual(ProviderRegistry.siteOwner(for: "coding.tu-zi.com")?.inputHint, .inputHintApiKey)
    }

    /// `api.tu-zi.com` 的控制台是按量付费的 new-api 站,不是 Coding Plan。
    /// 认成 tu-zi Coding 会指用户去粘一把连不上的 key(用户 2026-09-28 实机撞上的)
    func testTheTuziPayAsYouGoConsoleIsNotTuziCoding() {
        for page in ["api.tu-zi.com/console", "https://api.tu-zi.com/", "tu-zi.com",
                     "https://api.tu-zi.com/codingx"] {
            XCTAssertNotEqual(ProviderRegistry.siteOwner(for: page)?.providerID, TuziProvider.id, page)
        }
    }

    /// 安全边界:别人的域名不能被认成 tu-zi(EXT-011)
    func testLookalikeDomainsAreNotTuzi() {
        for page in ["https://evil-tu-zi.com/console", "https://coding.tu-zi.com.evil.example/"] {
            XCTAssertNotEqual(ProviderRegistry.siteOwner(for: page)?.providerID, TuziProvider.id, page)
        }
    }

    /// 统计页没带 apiId:解析不出连接,但认得出是中转站的后台
    func testARelayAdminPageWithoutApiIdIsPointedToTheStatsURL() {
        let page = "https://relay.example.com/admin-next/api-stats"
        XCTAssertNil(ProviderRegistry.parse(page))
        XCTAssertEqual(ProviderRegistry.siteOwner(for: page)?.providerID, RelayProvider.id)
        XCTAssertEqual(ProviderRegistry.siteOwner(for: page)?.inputHint, .inputHintStatsPage)
    }

    /// 不是网址就谁都不认。「sk」补上 https:// 后像个主机名,但没有点号 ——
    /// 它照样会被当成网址,这里只要求它不被认成专门的那几家
    func testNonURLsHaveNoOwner() {
        for input in ["", "hello world"] {
            XCTAssertNil(ProviderRegistry.siteOwner(for: input), input)
        }
    }

    /// 陌生网址归通用的中转站软件适配器,而且那是**猜的**:界面据此说「将按 sub2api 测试」,
    /// 不说「已识别」(EXT-011)
    func testUnknownSitesFallToTheGenericRelaySoftwareAsAGuess() {
        let owner = ProviderRegistry.siteOwner(for: "https://example.com/dashboard")
        XCTAssertEqual(owner?.providerID, Sub2APIProvider.id)
        XCTAssertEqual(owner?.siteMatchIsGuess, true)
        XCTAssertEqual(ProviderRegistry.siteOwner(for: "coding.tu-zi.com")?.siteMatchIsGuess, false)
    }

    /// 通用的排在最后:专门认得的站点不能被它抢走
    func testTheGenericAdapterNeverShadowsASpecificOne() {
        XCTAssertEqual(ProviderRegistry.siteOwner(for: "https://api.tu-zi.com/coding")?.providerID,
                       TuziProvider.id)
        XCTAssertEqual(ProviderRegistry.siteOwner(for: "https://relay.example.com/admin-next/")?.providerID,
                       RelayProvider.id)
    }

    // ── 先粘服务地址,再给 key(EXT-011) ──────────────────────

    /// 用户在编程工具里填的 Base URL + key,拼出的连接和单独粘 key 的一模一样
    func testTheTuziBaseURLPlusAKeyMakesTheSameConnection() {
        let viaSite = ProviderRegistry.parse(site: "https://api.tu-zi.com/coding", key: "sk-abc")
        XCTAssertEqual(viaSite?.adapter.providerID, TuziProvider.id)
        XCTAssertEqual(viaSite?.connection, ProviderRegistry.parse("sk-abc")?.connection)
        XCTAssertEqual(viaSite?.connection.secret, "sk-abc")
    }

    /// 这家不收 key、或者 key 不像 key —— 都拼不出连接,不猜
    func testSitePlusKeyNeedsASiteThatTakesAKey() {
        // 中转站的后台要的是带 apiId 的统计页网址,不是 key
        XCTAssertNil(ProviderRegistry.parse(site: "https://relay.example.com/admin-next/", key: "sk-abc"))
        XCTAssertNil(ProviderRegistry.parse(site: "https://api.tu-zi.com/coding", key: ""))
        XCTAssertNil(ProviderRegistry.parse(site: "https://api.tu-zi.com/coding", key: "not a key"))
    }
}

// MARK: - providerID 进入身份

final class ProviderScopedIdentityTests: XCTestCase {

    private let a = AccountIdentity(providerID: "p1", baseURL: "https://x.example.com", apiId: "k")

    /// 同一个网址在不同协议下含义完全不同,所以 providerID 是身份的一部分。
    /// 这也意味着换了供应商之后,在途的旧响应过不了提交前的身份校验。
    func testProviderIDIsPartOfTheIdentity() {
        let other = AccountIdentity(providerID: "p2", baseURL: a.baseURL, apiId: a.apiId)
        XCTAssertFalse(a == other)
    }

    /// 两个分区键**刻意不含** providerID:算进去会让现有用户的历史分区键当场变掉,
    /// 等于把他们攒下的曲线全丢掉。带版本的迁移是 EXT-009 的事。
    /// **历史分区键必须区分供应商**(EXT-009)。
    ///
    /// tu-zi 的账户标识是响应里的 `key_id`,一个短整数;自建中转站的 apiId
    /// 可以是任意字符串。两者撞上而分区键不分供应商的话,两个账户的历史会
    /// 静默合并 —— 而且合了就再也分不开。
    func testTheStorageKeyDistinguishesTheProvider() {
        let other = AccountIdentity(providerID: "p2", baseURL: a.baseURL, apiId: a.apiId)
        XCTAssertNotEqual(a.storageKey, other.storageKey)
    }

    /// 偏好键**刻意仍然不含 providerID**,而且不需要含:
    /// 它已经带了 baseURL,两家供应商的服务地址不可能相同,撞不上。
    /// 键加得越多能撞上的越少,而每加一个都要付一次迁移的代价。
    func testThePreferenceKeyNeedsNoProviderBecauseItAlreadyHasTheEndpoint() {
        let other = AccountIdentity(providerID: "p2", baseURL: a.baseURL, apiId: a.apiId)
        XCTAssertEqual(a.preferenceKey, other.preferenceKey)
    }

    /// 只有兜底适配器的账户才有老分区可认领。
    ///
    /// 存量配置里没有 providerID,一律按兜底适配器算,所以那个年代的历史
    /// 只可能属于它。让别家也来认领,认领到的正好是**另一家的历史** ——
    /// 那恰恰是加 providerID 要修的碰撞,会在迁移里再犯一遍。
    func testOnlyTheFallbackProviderMayAdoptALegacyPartition() {
        let legacy = AccountIdentity(providerID: ProviderRegistry.fallback.providerID,
                                     baseURL: a.baseURL, apiId: a.apiId)
        XCTAssertEqual(legacy.legacyStorageKey, AccountKey.derive(apiId: a.apiId))

        let newcomer = AccountIdentity(providerID: TuziProvider.id,
                                       baseURL: a.baseURL, apiId: a.apiId)
        XCTAssertNil(newcomer.legacyStorageKey)
    }
}

// MARK: - 子路径部署

final class PathPrefixTests: XCTestCase {

    /// 反代挂在 /relay 底下时,统计接口也在同一个前缀里。
    /// 只取 scheme://host 会把请求发到根路径上去 —— 那台机器上根本没有 /apiStats。
    func testSubPathDeploymentKeepsItsPrefix() {
        let account = relay.parseConnection(
            "https://example.com/relay/admin-next/api-stats?apiId=k")?.account
        XCTAssertEqual(account?.baseURL, "https://example.com/relay")
    }

    func testMultiSegmentPrefixIsKept() {
        let account = relay.parseConnection(
            "https://example.com/a/b/admin-next/api-stats?apiId=k")?.account
        XCTAssertEqual(account?.baseURL, "https://example.com/a/b")
    }

    /// 根路径部署不该凭空多出一截
    func testRootDeploymentHasNoPrefix() {
        XCTAssertEqual(relay.parseConnection(statsURL)?.account.baseURL, "https://api.example.com")
    }

    func testPrefixSurvivesAlongsideAPort() {
        let account = relay.parseConnection(
            "https://example.com:8443/relay/admin-next/api-stats?apiId=k")?.account
        XCTAssertEqual(account?.baseURL, "https://example.com:8443/relay")
    }

    /// 解析出来的东西要能原样拼回去 —— 后台链接不能把前缀丢了
    func testManagementURLRoundTripsThePrefix() {
        let url = "https://example.com/relay/admin-next/api-stats?apiId=k"
        let account = relay.parseConnection(url)!.account
        XCTAssertEqual(relay.managementURL(for: account)?.absoluteString, url)
    }
}

// MARK: - 识别结果

final class ProviderResolutionTests: XCTestCase {

    func testKnownLinkResolves() {
        XCTAssertEqual(ProviderRegistry.resolve(statsURL),
                       .resolved(providerID: RelayProvider.id,
                                 connection: relay.parseConnection(statsURL)!))
    }

    /// 认不出来就如实说认不出来 —— 猜一个出来会让用户对着「已识别」的假象排查半天
    func testUnknownLinkIsUnsupportedNotGuessed() {
        XCTAssertEqual(ProviderRegistry.resolve("https://example.com/dashboard"), .unsupported)
        XCTAssertEqual(ProviderRegistry.resolve(""), .unsupported)
    }

    /// 用户手动指定协议的通道:定不下来时该让他选,而不是替他猜
    func testManuallyChosenProviderIsHonoured() {
        XCTAssertEqual(ProviderRegistry.resolve(statsURL, using: RelayProvider.id),
                       .resolved(providerID: RelayProvider.id,
                                 connection: relay.parseConnection(statsURL)!))
    }

    func testManuallyChosenProviderThatCannotParseIsUnsupported() {
        XCTAssertEqual(ProviderRegistry.resolve("https://example.com/dashboard",
                                                using: RelayProvider.id), .unsupported)
        XCTAssertEqual(ProviderRegistry.resolve(statsURL, using: "no-such-provider"), .unsupported)
    }
}

// MARK: - 凭据性质

final class CredentialSensitivityTests: XCTestCase {

    /// apiId 是只读统计标识,明文存可以接受
    func testRelayIdentifierMayBeStoredInPlainText() {
        XCTAssertEqual(relay.credentialSensitivity, .readOnlyIdentifier)
        XCTAssertTrue(ProviderRegistry.canStoreInPlainText(relay))
    }

    /// 关键在于这是**那家的性质**而非通用前提:
    /// 声明成敏感凭据的适配器必须被挡住,逼着为它设计真正的存储
    func testSecretBearingAdapterMayNotReusePlainTextStorage() {
        XCTAssertFalse(ProviderRegistry.canStoreInPlainText(SecretBearingStub()))
    }
}

/// 一个只为验证「敏感凭据会被挡住」而存在的桩
private struct SecretBearingStub: UsageProviderAdapter {
    var providerID: String { "stub" }
    var displayName: String { "Stub" }
    var capabilities: ProviderCapabilities { [] }
    var credentialSensitivity: CredentialSensitivity { .secret }
    var inputExample: String { "" }
    var inputHint: LangKey { .inputHintApiKey }
    func detect(_ input: String) -> Bool { false }
    func parseConnection(_ input: String) -> Connection? { nil }
    func managementURL(for account: AccountIdentity) -> URL? { nil }
    func fetchUsage(_ connection: Connection, schedule: ResetSchedule,
                    language: Language) async throws -> Snapshot {
        throw APIError("stub")
    }
}

// MARK: - 连接报告

private func reportSnapshot(gauges: [QuotaBucket], complete: Bool = true) -> Snapshot {
    Snapshot(name: "eva", isActive: true, gauges: gauges,
             totalCost: 0, totalRequests: 0, totalTokens: 0,
             monthlyCost: nil, monthlyRequests: nil, fetchedAt: Date(),
             hasCompleteUsage: complete)
}

final class ConnectionReportTests: XCTestCase {

    private let window = TimeWindow(start: Date(), end: Date().addingTimeInterval(3600))

    /// 账户名和状态必须来自**真实响应**,不是从输入里猜的
    func testAccountFactsComeFromTheResponse() {
        let report = ConnectionReport(snapshot: reportSnapshot(gauges: []),
                                      providerID: "p", displayName: "P", capabilities: [])
        XCTAssertEqual(report.accountName, "eva")
        XCTAssertTrue(report.isActive)
    }

    /// 一条带上限的额度都没有 —— 百分比和 pace 都显示不出来,该提前说
    func testNoLimitedQuotaIsReported() {
        let report = ConnectionReport(
            snapshot: reportSnapshot(gauges: [bucket("daily", used: 5, limit: 0)]),
            providerID: "p", displayName: "P", capabilities: [])
        XCTAssertTrue(report.findings.contains(.noLimitedQuota))
    }

    func testIncompleteUsageIsReported() {
        let report = ConnectionReport(
            snapshot: reportSnapshot(gauges: [bucket("daily", used: 5, limit: 10)],
                                     complete: false),
            providerID: "p", displayName: "P", capabilities: [])
        XCTAssertTrue(report.findings.contains(.incompleteUsage))
    }

    func testNoResetWindowIsReported() {
        let report = ConnectionReport(
            snapshot: reportSnapshot(gauges: [bucket("daily", used: 5, limit: 10)]),
            providerID: "p", displayName: "P", capabilities: [])
        XCTAssertTrue(report.findings.contains(.noResetWindow))
    }

    /// 能力声明缺失会直接变成用户看得见的提示 —— 这是能力声明真正被消费的地方
    func testMissingCapabilitiesBecomeFindings() {
        let report = ConnectionReport(
            snapshot: reportSnapshot(gauges: [bucket("daily", used: 5, limit: 10,
                                                    window: window)]),
            providerID: "p", displayName: "P", capabilities: [])
        XCTAssertTrue(report.findings.contains(.dailyResetInferred))
        XCTAssertTrue(report.findings.contains(.historyIsLocalOnly))
    }

    func testDeclaredCapabilitiesProduceNoSuchFindings() {
        let report = ConnectionReport(
            snapshot: reportSnapshot(gauges: [bucket("daily", used: 5, limit: 10,
                                                    window: window)]),
            providerID: "p", displayName: "P",
            capabilities: [.dailyResetTime, .usageHistory])
        XCTAssertEqual(report.findings, [])
    }

    /// 中转站的真实情况:两条「不给」如实出现在报告里
    func testRelayReportsItsTwoKnownLimitations() {
        let report = ConnectionReport(
            snapshot: reportSnapshot(gauges: [bucket("daily", used: 5, limit: 10,
                                                    window: window)]),
            providerID: relay.providerID, displayName: relay.displayName,
            capabilities: relay.capabilities)
        XCTAssertEqual(report.findings, [.dailyResetInferred, .historyIsLocalOnly])
    }
}

// MARK: - 在飞的是哪一个

final class InFlightGateTests: XCTestCase {

    func testIdleGateIsNotBusy() {
        let gate = InFlightGate<String>()
        XCTAssertFalse(gate.isBusy)
        XCTAssertNil(gate.token)
    }

    func testSameTokenDoesNotReenter() {
        var gate = InFlightGate<String>()
        XCTAssertTrue(gate.begin("a"))
        XCTAssertFalse(gate.begin("a"))
    }

    /// 用户改了网址,新的一次测试必须放行 —— 它和上一次是两件事
    func testDifferentTokenIsLetThrough() {
        var gate = InFlightGate<String>()
        _ = gate.begin("a")
        XCTAssertTrue(gate.begin("b"))
        XCTAssertEqual(gate.token, "b")
    }

    /// 先发起的那次回来时,不能把后来者的在飞标记抹成空闲
    func testStaleFinishDoesNotClearTheNewerToken() {
        var gate = InFlightGate<String>()
        _ = gate.begin("a")
        _ = gate.begin("b")

        gate.finish("a")
        XCTAssertTrue(gate.isBusy)
        XCTAssertEqual(gate.token, "b")

        gate.finish("b")
        XCTAssertFalse(gate.isBusy)
    }
}
