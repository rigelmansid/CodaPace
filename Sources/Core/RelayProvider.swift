//
//  RelayProvider.swift — claude-relay-service 适配器
//
//  这是第一个适配器,也是把现有实现原样搬进适配器边界的那一次迁移:
//  两个接口路径、响应形状、管理后台地址,全部收在这个文件里。
//  通用层从此只认 UsageProviderAdapter,不再知道 /apiStats 是什么。
//
//  Models.swift 里的 UserStats / Limits / Envelope 是**这个供应商的线上格式**,
//  以后接入别家时它们不该被复用,而是各自在各自的适配器里定义。
//

import Foundation

public struct RelayProvider: UsageProviderAdapter {

    public static let id = "claude-relay-service"

    /// 发请求那一步。测试换掉它来构造认证失效、超时这类失败路径(EXT-009);
    /// 生产路径就是 `URLSession.shared`,和从前完全一致。
    let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSession.shared) {
        self.transport = transport
    }

    public var providerID: String { Self.id }
    public var displayName: String { "claude-relay-service" }

    /// apiId 是只读统计标识:发不了 API 请求,也拿不到 API Key ——
    /// 所以明文存储可接受。这是**这家的性质**,不是通用前提。
    public var credentialSensitivity: CredentialSensitivity { .readOnlyIdentifier }

    public var inputExample: String { "https://your-relay.example.com/admin-next/api-stats?apiId=…" }

    public var inputHint: LangKey { .inputHintStatsPage }

    /// 管理后台的任意页面(`/admin-next/…`),或统计页但没带 apiId。
    /// 按路径认,和 `detect` 同理不看域名。
    public func recognizesSite(_ url: URLComponents) -> Bool {
        url.path.contains("/admin-next")
    }

    /// 这家不报日重置时刻,只能靠观测「今日」那条计数器归零来学 ——
    /// 和 `capabilities` 里没有 `.dailyResetTime` 是同一件事的两种说法。
    public var learnableDailyBucketID: String? { "daily" }

    /// 这个中转站给什么、不给什么。
    ///
    /// 两个「不给」是有实际后果的,不是凑数:
    /// · 没有 `dailyResetTime` —— 接口根本没有日重置字段,所以 app 要自己观测,
    ///   在观测到之前界面上如实标注「推算」。
    /// · 没有 `usageHistory` —— 只报当前值,所以历史只能从装上那天开始本地积累。
    public var capabilities: ProviderCapabilities {
        [.costAmounts, .cumulativeTokens, .cumulativeRequests,
         .windowResetTimes, .weeklyResetSchedule, .monthlyAggregate]
    }

    // MARK: - 识别与解析

    /// 用量页面的路径特征。
    ///
    /// 刻意**不看域名** —— 自建中转站什么域名都有,拿域名判断只会既漏又误。
    /// 而且这只是候选提示:真正的确认靠 `fetchUsage` 跑一次真请求。
    public func detect(_ input: String) -> Bool {
        guard let comps = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return comps.path.contains(Self.statsPath)
            || comps.queryItems?.contains { $0.name == "apiId" } == true
    }

    /// 例:https://api.example.com/admin-next/api-stats?apiId=xxxx
    ///
    /// 不带凭据:这家的 apiId 就是身份本身,是个只读统计标识,不是密钥。
    public func parseConnection(_ input: String) -> Connection? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: text),
              let scheme = comps.scheme,
              let host = comps.host,
              let apiId = comps.queryItems?.first(where: { $0.name == "apiId" })?.value,
              !apiId.isEmpty
        else { return nil }

        var base = "\(scheme)://\(host)"
        if let port = comps.port { base += ":\(port)" }

        // 部署在子路径下时(反代挂在 /relay 之类),统计接口也在同一个前缀底下。
        // 只取 scheme://host 会把请求发到根路径上去 —— 那台机器上根本没有 /apiStats。
        base += pathPrefix(of: comps.path)

        return Connection(account: AccountIdentity(providerID: providerID,
                                                  baseURL: base, apiId: apiId))
    }

    /// 用量页面路径里位于 `/admin-next/api-stats` **之前**的那一段。
    /// 没有这个路径(比如用户只给了带 apiId 的其它链接)时返回空串。
    private func pathPrefix(of path: String) -> String {
        guard let range = path.range(of: Self.statsPath) else { return "" }
        let prefix = String(path[path.startIndex..<range.lowerBound])
        return prefix == "/" ? "" : prefix
    }

    private static let statsPath = "/admin-next/api-stats"

    public func managementURL(for account: AccountIdentity) -> URL? {
        guard account.isConfigured else { return nil }
        return URL(string: "\(account.baseURL)\(Self.statsPath)?apiId=\(account.apiId)")
    }

    // MARK: - 抓取

    public func fetchUsage(_ connection: Connection, schedule: ResetSchedule,
                           language: Language) async throws -> Snapshot {
        let account = connection.account
        let stats = try await userStats(account, language: language)

        // 本月消费是锦上添花,取不到不影响主结果
        let monthly = try? await monthlyUsage(account, language: language)

        // 打点放在拿到数据之后 —— fetchedAt 是「这份数字什么时候到手的」,
        // 不是「什么时候发的请求」。倒计时和 pace 都按它算。
        return buildSnapshot(stats: stats, monthly: monthly,
                             schedule: schedule, now: Date())
    }

    // MARK: - 两个接口

    /// 凭据一律显式传入,这里不读任何全局配置 ——
    /// 一次刷新必须全程绑定同一个身份,中途回头读配置就会横跨两个账户。
    func userStats(_ account: AccountIdentity, language: Language) async throws -> UserStats {
        try await post(base: account.baseURL,
                       path: "/apiStats/api/user-stats",
                       body: ["apiId": account.apiId],
                       as: UserStats.self,
                       language: language)
    }

    private struct BatchAggregated: Decodable { let monthlyUsage: UsageBlock? }
    private struct BatchData: Decodable { let aggregated: BatchAggregated? }

    func monthlyUsage(_ account: AccountIdentity, language: Language) async throws -> UsageBlock? {
        let batch = try await post(base: account.baseURL,
                                   path: "/apiStats/api/batch-stats",
                                   body: ["apiIds": [account.apiId]],
                                   as: BatchData.self,
                                   language: language)
        return batch.aggregated?.monthlyUsage
    }

    // MARK: - 底层

    private func post<T: Decodable>(base: String,
                                    path: String,
                                    body: Any,
                                    as type: T.Type,
                                    language: Language) async throws -> T {
        guard let url = URL(string: base + path) else {
            throw APIError(L10n.format(.errInvalidURLFormat, language, base))
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await transport.data(for: req)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError(L10n.format(.errHTTPFormat, language, http.statusCode))
        }
        return try ResponseDecoder.unwrap(type, from: data, language: language)
    }
}

// MARK: - 响应映射

// 把这个中转站的线上格式映射成通用快照。**属于适配器**,不属于通用层:
// 它认识 currentTotalCost / weeklyOpusCost 这些字段名,也认识「四条固定额度」这个形状。
// 换一家供应商,这段就该整体换掉,而不是在里面加分支。
// (EXT-001 会把「四条固定额度」一般化成动态额度桶,那时每个适配器各自产出自己的桶。)
extension RelayProvider {

    /// public 是为了能单测这段映射(测试是独立模块)。
    /// 它不是给通用层调用的 —— 通用层只该经由 `fetchUsage` 拿到 Snapshot。
    public func buildSnapshot(stats: UserStats,
                              monthly: UsageBlock?,
                              schedule: ResetSchedule,
                              now: Date) -> Snapshot {
        let L = stats.limits

        // 每条额度都带上「它怎么重置」这条规则,历史图才能按各自的算法反推周期边界。
        // 窗口仍是此刻这一段:限流窗口过期时**不外推**,让 pace 变成不可判断。
        let dailyRule = schedule.dailyRule()
        let weeklyRule = schedule.weeklyRule(limits: L)
        let windowRule = schedule.windowRule(limits: L, now: now)

        // 这四个桶 ID 的取值**刻意等于**从前那个 QuotaKind 枚举的 rawValue
        // (枚举本身在阶段 2 已经删掉,留下的只有这四个字符串)。
        // 同一个字符串还活在三处存量数据里:菜单栏固定选择的偏好、通知去重键、
        // 历史表的四个固定额度列。改了它,老用户的菜单栏选择会失效、
        // 当前周期已发过的告警会重发一遍、历史曲线会对不上。**不要改。**
        //
        // 单位一律美元:这家的字段名就是 cost,界面上一直按美元显示,
        // 而且它确实是按金额计费的。不是所有供应商都能这么说(见 TuziProvider)。
        let usd = QuotaUnit.money(currency: "USD")

        let gauges: [QuotaBucket] = [
            // 账户总配额:没有重置周期,所以没有窗口,也就不做速度判断
            QuotaBucket(id: "total",
                        title: .localized(.quotaTotal),
                        used: L.currentTotalCost,
                        limit: L.totalCostLimit,
                        unit: usd,
                        window: nil,
                        rule: nil),

            QuotaBucket(id: "daily",
                        title: .localized(.quotaDaily),
                        used: L.currentDailyCost,
                        limit: L.dailyCostLimit,
                        unit: usd,
                        window: dailyRule.period(containing: now),
                        rule: dailyRule),

            // 标题里那个「Opus」不是随手起的:中转站这条额度的字段名就是
            // `weeklyOpusCostLimit`,它**只限 Opus**,用 Sonnet 不吃这条。
            // 所以不能图通用改成「本周」—— 那会让用户以为所有模型共用一条周限额。
            //
            // 反过来说,这个标题的正确性**押在中转站的这条性质上**:哪天它改成
            // 限全部模型而字段名没动,这里就开始撒谎了。真要变,改的是标题,
            // **不是 id** —— id 是三处存量数据的主键(见 QuotaBucket.id)。
            //
            // 别家供应商的周额度是**另一个桶**,由它自己的适配器声明自己的 id 和标题
            // (tu-zi 的是 `weekly`),不会复用这一条,也就不会显示成「本周 Opus」。
            QuotaBucket(id: "weeklyOpus",
                        title: .localized(.quotaWeeklyOpus),
                        used: L.weeklyOpusCost,
                        limit: L.weeklyOpusCostLimit,
                        unit: usd,
                        window: weeklyRule?.period(containing: now),
                        rule: weeklyRule),

            QuotaBucket(id: "window",
                        title: .localized(.quotaWindow),
                        used: L.currentWindowCost,
                        limit: L.rateLimitCost,
                        unit: usd,
                        window: schedule.windowInterval(limits: L, now: now),
                        rule: windowRule),
        ]

        return Snapshot(
            name: stats.name.isEmpty ? "API Key" : stats.name,
            isActive: stats.isActive,
            gauges: gauges,
            totalCost: stats.total.cost,
            totalRequests: stats.total.requests,
            totalTokens: stats.total.allTokens,
            monthlyCost: monthly?.cost,
            monthlyRequests: monthly?.requests,
            fetchedAt: now,
            // 本月消费是锦上添花,取不到也不影响主结果,所以不参与这个判断
            hasCompleteUsage: stats.hasCompleteUsage
        )
    }
}
