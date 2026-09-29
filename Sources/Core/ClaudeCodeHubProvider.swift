//
//  ClaudeCodeHubProvider.swift — claude-code-hub 中转站软件适配器
//
//  第二个「软件型」适配器(ding113/claude-code-hub),和 sub2api 同理:谁都能部署,
//  地址来自用户,一个适配器覆盖所有站点(EXT-011)。
//
//  协议依据是 2026-09-28 **本机部署 v0.9.6 实测**,有三件事和调研时读的文档不一样:
//
//  1. **默认配置下 API Key 查不了额度。** 会话令牌模式默认 `opaque`,`/api/v1/me/quota`
//     只认登录会话。所以要先拿 key 调 `POST /api/auth/login` 换一个会话令牌(7 天有效),
//     再拿它去查 —— 和它网页端「用 API Key 登录」是同一条路,权限不超过那把 key。
//     站长改成 legacy / dual 模式的站点,key 直接就能查,所以先直接试。
//     会话令牌**必须复用**:每登录一次,站点就多一条登录记录、Redis 里多一个会话。
//     存在 `SessionTokens.store`(App 换成钥匙串实现),失效(401)了才重新登录。
//  2. **响应里一个时间戳都没有**,读不出服务端时区。时区另查 `/api/v1/system/timezone`,
//     是服务端明说的,不是猜的。
//  3. **两层限额**:key 自己的,和整个账户共用的,各有 5 小时 / 日 / 周 / 月 / 总额。
//     周、月按服务端时区的自然周(周一 0 点)、自然月(1 号 0 点)重置(源码确认);
//     key 的日重置方式和时刻响应里有;**账户的日重置规则和两层的 5 小时方式响应里都没有** ——
//     这几条只显示用量,不给 pace。
//

import Foundation

// MARK: - 会话令牌放哪

/// 会话令牌的存储。Core 不碰钥匙串 —— App 启动时把 `SessionTokens.store`
/// 换成钥匙串实现,重启 app 也能接着用,7 天内只登录一次(用户 2026-09-28 选定)。
public protocol SessionTokenStore: AnyObject {
    func token(for account: AccountIdentity) -> String?
    func setToken(_ token: String?, for account: AccountIdentity)
}

/// 只在内存里的实现:测试用,也是 App 换掉它之前的默认值
public final class InMemorySessionTokenStore: SessionTokenStore {
    private var tokens: [AccountIdentity: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func token(for account: AccountIdentity) -> String? {
        lock.lock(); defer { lock.unlock() }
        return tokens[account]
    }

    public func setToken(_ token: String?, for account: AccountIdentity) {
        lock.lock(); defer { lock.unlock() }
        tokens[account] = token
    }
}

/// 要用 key 换会话的适配器共用的那一份存储。**不带供应商名字**:App 只和它打交道,
/// 不认识具体是哪家要会话(不变量 6)。注册表里的适配器是静态建好的,所以放在这里
public enum SessionTokens {
    public static var store: SessionTokenStore = InMemorySessionTokenStore()
}

// MARK: - 适配器

public struct ClaudeCodeHubProvider: UsageProviderAdapter {

    public static let id = "claude-code-hub"
    static let quotaPath = "/api/v1/me/quota"
    static let timeZonePath = "/api/v1/system/timezone"
    static let loginPath = "/api/auth/login"

    /// 见 `RelayProvider.transport`
    let transport: HTTPTransport
    private let injectedSessions: SessionTokenStore?

    public init(transport: HTTPTransport = URLSession.shared, sessions: SessionTokenStore? = nil) {
        self.transport = transport
        self.injectedSessions = sessions
    }

    private var sessions: SessionTokenStore { injectedSessions ?? SessionTokens.store }

    public var providerID: String { Self.id }
    public var displayName: String { "claude-code-hub" }
    public var credentialSensitivity: CredentialSensitivity { .secret }
    public var inputExample: String { "https://your-relay.example.com  +  sk-…" }
    public var inputHint: LangKey { .inputHintApiKey }

    /// 响应只有金额口径的上限和已用,没有累计 token / 请求数,也没有历史接口
    public var capabilities: ProviderCapabilities { [.costAmounts] }

    // MARK: - 识别与解析(和 sub2api 同一套:地址 + key,认任何网址,排在注册表最后)

    public func detect(_ input: String) -> Bool { false }
    public func parseConnection(_ input: String) -> Connection? { nil }

    public func recognizesSite(_ url: URLComponents) -> Bool {
        ProviderRegistry.siteRoot(url) != nil
    }

    public var siteMatchIsGuess: Bool { true }
    public var keyFollowsSite: Bool { true }

    public func parseConnection(site: URLComponents, key: String) -> Connection? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }),
              let base = ProviderRegistry.siteRoot(site)
        else { return nil }
        return Connection(account: AccountIdentity(providerID: providerID, baseURL: base,
                                                   apiId: AccountIdentity.hashedKeyID(key)),
                          secret: key)
    }

    public func managementURL(for account: AccountIdentity) -> URL? {
        guard account.isConfigured else { return nil }
        return URL(string: account.baseURL)
    }

    // MARK: - 抓取

    public func fetchUsage(_ connection: Connection, schedule: ResetSchedule,
                           language: Language) async throws -> Snapshot {
        guard let key = connection.secret, !key.isEmpty else {
            throw APIError(L10n.text(.errMissingCredential, language))
        }
        let quotaData = try await authorizedGet(Self.quotaPath, connection: connection,
                                                key: key, language: language)
        let quota = try ClaudeCodeHubQuota.decode(quotaData, language: language)

        // 时区查不到(老版本没有这个接口、或被拦了)不算失败 —— 那几条额度只是不给周期,
        // 而不是拿本机时区顶上
        let zoneData = try? await authorizedGet(Self.timeZonePath, connection: connection,
                                                key: key, language: language)
        let timeZone = zoneData.flatMap(ClaudeCodeHubQuota.timeZone(from:))

        return buildSnapshot(quota, timeZone: timeZone, now: Date())
    }

    /// 带认证的 GET。依次试:存着的会话令牌 → key 本身(legacy / dual 站点)→ 用 key 登录换新令牌。
    /// 只有 401 才往下走一步;别的失败原样报出去。
    private func authorizedGet(_ path: String, connection: Connection, key: String,
                               language: Language) async throws -> Data {
        let account = connection.account

        if let token = sessions.token(for: account) {
            let (data, status) = try await get(path, base: account.baseURL, bearer: token, language: language)
            if status != 401 { return try Self.checked(data, status: status, language: language) }
            sessions.setToken(nil, for: account)   // 过期或被登出了
        }

        let (data, status) = try await get(path, base: account.baseURL, bearer: key, language: language)
        if status != 401 { return try Self.checked(data, status: status, language: language) }

        let token = try await login(base: account.baseURL, key: key, language: language)
        sessions.setToken(token, for: account)
        let (fresh, freshStatus) = try await get(path, base: account.baseURL, bearer: token, language: language)
        return try Self.checked(fresh, status: freshStatus, language: language)
    }

    private func get(_ path: String, base: String, bearer: String,
                     language: Language) async throws -> (Data, Int) {
        guard let url = URL(string: base + path) else {
            throw APIError(L10n.format(.errInvalidURLFormat, language, base))
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.httpShouldHandleCookies = false
        let (data, response) = try await transport.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 200)
    }

    /// 用 key 登录,从 `Set-Cookie: auth-token=…` 里取出会话令牌。
    ///
    /// **关掉 cookie 处理**:否则 URLSession 会把它存进 app 的 cookie 文件 ——
    /// 那是一份没人管的能用 7 天的凭据。令牌由 `sessionStore` 管。
    private func login(base: String, key: String, language: Language) async throws -> String {
        guard let url = URL(string: base + Self.loginPath) else {
            throw APIError(L10n.format(.errInvalidURLFormat, language, base))
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpShouldHandleCookies = false
        req.httpBody = try JSONSerialization.data(withJSONObject: ["key": key])

        let (data, response) = try await transport.data(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            throw APIError(ClaudeCodeHubQuota.errorMessage(data)
                           ?? L10n.format(.errHTTPFormat, language, status))
        }
        guard let token = http.flatMap({ Self.sessionToken(fromSetCookie: $0.value(forHTTPHeaderField: "Set-Cookie")) })
        else { throw APIError(L10n.text(.errUnparsable, language)) }
        return token
    }

    /// `auth-token=sid_…; Path=/; …`,可能和别的 cookie 用逗号拼在一起
    static func sessionToken(fromSetCookie header: String?) -> String? {
        guard let header, let range = header.range(of: "auth-token=") else { return nil }
        let token = header[range.upperBound...].prefix { $0 != ";" && $0 != "," }
        return token.isEmpty ? nil : String(token)
    }

    static func checked(_ data: Data, status: Int, language: Language) throws -> Data {
        guard (200..<300).contains(status) else {
            throw APIError(ClaudeCodeHubQuota.errorMessage(data)
                           ?? L10n.format(.errHTTPFormat, language, status))
        }
        return data
    }
}

// MARK: - 响应映射

extension ClaudeCodeHubProvider {

    /// public 是为了能单测这段映射(测试是独立模块)
    public func buildSnapshot(_ q: ClaudeCodeHubQuota, timeZone: TimeZone?, now: Date) -> Snapshot {

        // 周、月:服务端时区的自然周(周一 0 点)、自然月(1 号 0 点)。规则来自源码,
        // 时区来自服务端 —— 属于已验证的协议(`configured`)。时区拿不到就不给周期
        let weekly = timeZone.map {
            ResetRule(.calendarWeekly(timeZone: $0, weekday: 2, hour: 0, minute: 0), provenance: .configured)
        }
        let monthly = timeZone.map {
            ResetRule(.subscriptionAnniversary(timeZone: $0, day: 1, hour: 0, minute: 0), provenance: .configured)
        }
        // key 的日重置:固定时刻由服务端给(`04:00`),时区也是;滚动的没有统一归零时刻,不给 pace
        let keyDaily: ResetRule? = {
            guard q.dailyResetMode == "fixed", let timeZone,
                  let (hour, minute) = ClaudeCodeHubQuota.hourMinute(q.dailyResetTime) else { return nil }
            return ResetRule(.calendarDaily(timeZone: timeZone, hour: hour, minute: minute), provenance: .server)
        }()
        let keyDailyTitle: LangKey = q.dailyResetMode == "rolling" ? .quotaOneDay : .quotaDaily

        // 5 小时是固定还是滚动、账户的日重置规则,响应里都没有 —— 只显示用量
        let rows: [(String, LangKey, LangKey, Double?, Double, ResetRule?)] = [
            ("key_5h", .quotaScopeKey, .quotaFiveHours, q.key.limit5h, q.key.current5h, nil),
            ("key_daily", .quotaScopeKey, keyDailyTitle, q.key.limitDaily, q.key.currentDaily, keyDaily),
            ("key_weekly", .quotaScopeKey, .quotaWeekly, q.key.limitWeekly, q.key.currentWeekly, weekly),
            ("key_monthly", .quotaScopeKey, .quotaMonthly, q.key.limitMonthly, q.key.currentMonthly, monthly),
            ("key_total", .quotaScopeKey, .quotaTotal, q.key.limitTotal, q.key.currentTotal, nil),
            ("user_5h", .quotaScopeAccount, .quotaFiveHours, q.user.limit5h, q.user.current5h, nil),
            ("user_daily", .quotaScopeAccount, .quotaDaily, q.user.limitDaily, q.user.currentDaily, nil),
            ("user_weekly", .quotaScopeAccount, .quotaWeekly, q.user.limitWeekly, q.user.currentWeekly, weekly),
            ("user_monthly", .quotaScopeAccount, .quotaMonthly, q.user.limitMonthly, q.user.currentMonthly, monthly),
            ("user_total", .quotaScopeAccount, .quotaTotal, q.user.limitTotal, q.user.currentTotal, nil),
        ]

        // 上限为 null 表示这一档不限 —— 不产出桶(两层加起来最多十条,只留设了上限的)
        let gauges = rows.compactMap { id, scope, period, limit, used, rule -> QuotaBucket? in
            guard let limit, limit > 0 else { return nil }
            return QuotaBucket(id: id, title: .scoped(scope: scope, period: period),
                               used: used, limit: limit, unit: .money(currency: "USD"),
                               window: rule?.period(containing: now), rule: rule)
        }

        return Snapshot(
            name: q.userName.isEmpty ? displayName : q.userName,
            isActive: q.isActive,
            gauges: gauges,
            // 只有累计花费,没有 token 和请求数;面板那行整行不显示,而不是显示 0(不变量 3)
            totalCost: nil,
            totalRequests: nil,
            totalTokens: nil,
            monthlyCost: nil,
            monthlyRequests: nil,
            fetchedAt: now,
            hasCompleteUsage: !gauges.isEmpty
        )
    }
}

// MARK: - 线上格式

/// claude-code-hub `/api/v1/me/quota` 的响应。**属于这个适配器**,别家不该复用。
public struct ClaudeCodeHubQuota: Equatable {

    public struct Layer: Equatable {
        public var limit5h: Double?, limitDaily: Double?, limitWeekly: Double?
        public var limitMonthly: Double?, limitTotal: Double?
        public var current5h = 0.0, currentDaily = 0.0, currentWeekly = 0.0
        public var currentMonthly = 0.0, currentTotal = 0.0
    }

    public var key = Layer()
    public var user = Layer()
    public var userName = ""
    public var isActive = false
    /// key 的日重置方式和时刻。**不是账户的** —— 账户那层的规则响应里没有
    public var dailyResetMode = ""
    public var dailyResetTime = ""
}

extension ClaudeCodeHubQuota {

    public static func decode(_ data: Data, language: Language) throws -> ClaudeCodeHubQuota {
        do {
            return try JSONDecoder().decode(ClaudeCodeHubQuota.self, from: data)
        } catch let invalid as InvalidFieldError {
            throw APIError(L10n.format(.errInvalidFieldFormat, language, invalid.field))
        } catch {
            throw APIError(L10n.text(.errUnparsable, language))
        }
    }

    /// `{"timeZone":"Asia/Shanghai"}` → 时区。认不出的名字就是 nil,不猜
    static func timeZone(from data: Data) -> TimeZone? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["timeZone"] as? String else { return nil }
        return TimeZone(identifier: name)
    }

    /// `"04:00"` → (4, 0)
    static func hourMinute(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return (h, m)
    }

    /// 失败响应有两种格式,实测都见过:API 是 problem+json(`detail`),
    /// 登录是 `{"error":…,"errorCode":…}`
    static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for field in ["detail", "error", "title"] {
            if let message = object[field] as? String, !message.isEmpty { return message }
        }
        return nil
    }
}

extension ClaudeCodeHubQuota: Decodable {

    enum CodingKeys: String, CodingKey {
        case keyLimit5hUsd, keyLimitDailyUsd, keyLimitWeeklyUsd, keyLimitMonthlyUsd, keyLimitTotalUsd
        case keyCurrent5hUsd, keyCurrentDailyUsd, keyCurrentWeeklyUsd, keyCurrentMonthlyUsd, keyCurrentTotalUsd
        case userLimit5hUsd, userLimitDailyUsd, userLimitWeeklyUsd, userLimitMonthlyUsd, userLimitTotalUsd
        case userCurrent5hUsd, userCurrentDailyUsd, userCurrentWeeklyUsd, userCurrentMonthlyUsd, userCurrentTotalUsd
        case userName, userIsEnabled, keyIsEnabled, dailyResetMode, dailyResetTime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = Layer(limit5h: try c.number(.keyLimit5hUsd), limitDaily: try c.number(.keyLimitDailyUsd),
                    limitWeekly: try c.number(.keyLimitWeeklyUsd), limitMonthly: try c.number(.keyLimitMonthlyUsd),
                    limitTotal: try c.number(.keyLimitTotalUsd),
                    current5h: try c.number(.keyCurrent5hUsd) ?? 0, currentDaily: try c.number(.keyCurrentDailyUsd) ?? 0,
                    currentWeekly: try c.number(.keyCurrentWeeklyUsd) ?? 0,
                    currentMonthly: try c.number(.keyCurrentMonthlyUsd) ?? 0,
                    currentTotal: try c.number(.keyCurrentTotalUsd) ?? 0)
        user = Layer(limit5h: try c.number(.userLimit5hUsd), limitDaily: try c.number(.userLimitDailyUsd),
                     limitWeekly: try c.number(.userLimitWeeklyUsd), limitMonthly: try c.number(.userLimitMonthlyUsd),
                     limitTotal: try c.number(.userLimitTotalUsd),
                     current5h: try c.number(.userCurrent5hUsd) ?? 0, currentDaily: try c.number(.userCurrentDailyUsd) ?? 0,
                     currentWeekly: try c.number(.userCurrentWeeklyUsd) ?? 0,
                     currentMonthly: try c.number(.userCurrentMonthlyUsd) ?? 0,
                     currentTotal: try c.number(.userCurrentTotalUsd) ?? 0)
        userName = try c.text(.userName) ?? ""
        let userEnabled = try c.flag(.userIsEnabled) ?? false
        let keyEnabled = try c.flag(.keyIsEnabled) ?? false
        isActive = userEnabled && keyEnabled
        dailyResetMode = try c.text(.dailyResetMode) ?? ""
        dailyResetTime = try c.text(.dailyResetTime) ?? ""
    }
}
