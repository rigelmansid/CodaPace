//
//  Sub2APIProvider.swift — sub2api 中转站软件适配器
//
//  第一个「软件型」适配器:sub2api(claude-relay-service 作者的后继,CRS 2.0)
//  谁都能部署,地址来自用户,一个适配器覆盖所有站点(EXT-011)。
//
//  协议依据是 2026-09-28 **本机部署 v0.2.9 实测**拿到的真实响应,不是照文档写的:
//  用站点发的 key 查 `GET /v1/usage`。同一个接口按 key 的配置返回三种形态 ——
//
//  1. `quota_limited`:key 自带限额。`quota` 总额 + `rate_limits[]`(5h / 1d / 7d)。
//     窗口从**第一次使用**起算、满时长重置(09:23 开始的 1d 在次日 09:23 重置),
//     不是自然日。用过之后服务端给 `window_start` 和 `reset_at`,没用过两者都是 null。
//  2. 订阅分组(`subscription` 对象):日 / 周 / 月三档上限与已用。只给
//     `weekly_window_start`,**没有日窗和月窗的起点** —— 见 buildSnapshot 里各自的处理。
//  3. 钱包余额(只有 `balance`):没有周期额度,不在接入范围内(EXT-011),如实报错。
//
//  响应里**没有任何账户或 key 的 ID**,身份用 key 的哈希 —— 见 AccountIdentity.hashedKeyID。
//

import Foundation

public struct Sub2APIProvider: UsageProviderAdapter {

    public static let id = "sub2api"
    static let usagePath = "/v1/usage"

    /// 见 `RelayProvider.transport`
    let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSession.shared) {
        self.transport = transport
    }

    public var providerID: String { Self.id }
    public var displayName: String { "sub2api" }

    /// 站点发的 key 就是调模型用的那把,能花钱
    public var credentialSensitivity: CredentialSensitivity { .secret }

    public var inputHint: LangKey { .inputHintApiKey }

    /// 响应里有 `usage.total` 的累计 token 数,没有历史接口。
    public var capabilities: ProviderCapabilities { [.cumulativeTokens] }

    // MARK: - 识别与解析

    /// 单独一段输入认不出来:这家要「地址 + key」两样(EXT-011)
    public func detect(_ input: String) -> Bool { false }
    public func parseConnection(_ input: String) -> Connection? { nil }

    /// 自建站什么域名都有,**任何**网址都可能是它 —— 所以它排在注册表最后,
    /// 专门的适配器先认(EXT-011:专门在前、通用在后),而且界面上说的是
    /// 「将按 sub2api 测试」而不是「已识别」(`siteMatchIsGuess`)。
    public func recognizesSite(_ url: URLComponents) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false
        else { return false }
        return true
    }

    public var siteMatchIsGuess: Bool { true }
    public var keyFollowsSite: Bool { true }

    /// 请求发往站点根(`ProviderRegistry.siteRoot`);身份是 key 的哈希,
    /// 响应里没有账户 ID(`AccountIdentity.hashedKeyID`)
    public func parseConnection(site: URLComponents, key: String) -> Connection? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }),
              let base = ProviderRegistry.siteRoot(site)
        else { return nil }
        return Connection(account: AccountIdentity(providerID: providerID, baseURL: base,
                                                   apiId: AccountIdentity.hashedKeyID(key)),
                          secret: key)
    }

    /// 站点首页。`/key-usage` 那个公开页要再输一遍 key,不如首页有用
    public func managementURL(for account: AccountIdentity) -> URL? {
        guard account.isConfigured else { return nil }
        return URL(string: account.baseURL)
    }

    // MARK: - 抓取

    public func fetchUsage(_ connection: Connection, schedule: ResetSchedule,
                           language: Language) async throws -> Snapshot {
        buildSnapshot(try await fetch(connection, language: language), now: Date())
    }

    private func fetch(_ connection: Connection, language: Language) async throws -> Sub2APIUsage {
        guard let secret = connection.secret, !secret.isEmpty else {
            throw APIError(L10n.text(.errMissingCredential, language))
        }
        guard let url = URL(string: connection.account.baseURL + Self.usagePath) else {
            throw APIError(L10n.format(.errInvalidURLFormat, language, connection.account.baseURL))
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await transport.data(for: req)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // 对方给了原因就用它(「Invalid API key」「key 没分配分组」)——
            // 比一句「HTTP 403」有用得多
            throw APIError(Sub2APIUsage.errorMessage(data)
                           ?? L10n.format(.errHTTPFormat, language, http.statusCode))
        }

        let usage = try Sub2APIUsage.decode(data, language: language)
        // 钱包余额没有周期,给不出 pace —— 不在接入范围内,说清楚,而不是显示一个空面板
        if usage.isWalletOnly {
            throw APIError(L10n.text(.errSub2apiWalletMode, language))
        }
        return usage
    }
}

// MARK: - 响应映射

extension Sub2APIProvider {

    /// public 是为了能单测这段映射(测试是独立模块)
    public func buildSnapshot(_ usage: Sub2APIUsage, now: Date) -> Snapshot {
        var gauges: [QuotaBucket] = []

        /// 有上限、却没报已用的那几条(OPT-015)。面板上照旧按 0 显示 —— 和中转站的
        /// `UserStats.hasCompleteUsage` 同一个做法 —— 但这份快照不能进历史:
        /// 0 和「不知道」在库里是两件事,会变成一次假归零和一段假增量
        var missingUsed = false
        func used(_ reported: Double?) -> Double {
            if reported == nil { missingUsed = true }
            return reported ?? 0
        }

        // ── key 自带限额 ──
        // 总额没有周期,只作为一条额度显示,不参与 pace
        if let quota = usage.quota, quota.limit > 0 {
            gauges.append(QuotaBucket(id: "total", title: .localized(.quotaTotal),
                                      used: used(quota.used), limit: quota.limit,
                                      unit: .money(currency: "USD"), window: nil, rule: nil))
        }
        for w in usage.rateLimits where w.limit > 0 {
            // 起止都来自服务端;没用过时两者是 null,于是这条额度没有周期,不给 pace ——
            // 不拿「现在 + 时长」编一个出来
            let rule = w.start.flatMap { start in
                w.resetAt.map { ResetRule(.serverProvided(start: start, end: $0), provenance: .server) }
            }
            gauges.append(QuotaBucket(id: "window_\(w.window)", title: Self.title(forWindow: w.window),
                                      used: used(w.used), limit: w.limit, unit: .money(currency: "USD"),
                                      window: rule?.period(containing: now), rule: rule))
        }

        // ── 订阅分组 ──
        if let s = usage.subscription {
            // 日:源码里按服务端时区的自然日 0 点重置,响应不给起点。时区取自响应里
            // 时间戳的偏移(`+08:00`)—— 所以是推算,界面会标出来。推不出时区就不给周期。
            let daily = usage.serverTimeZone.map {
                ResetRule(.calendarDaily(timeZone: $0, hour: 0, minute: 0), provenance: .inferred)
            }
            // 周:锚点 + 7×24h 滚动(不是自然周),锚点由服务端给;7 天这个长度来自源码,
            // 属于已验证的协议。没用过时锚点是 null,就不给周期
            let weekly = s.weeklyWindowStart.map {
                ResetRule(.fixedDuration(anchor: $0, seconds: 7 * 86_400), provenance: .configured)
            }
            // 月:30×24h 滚动,但响应**没有月窗起点**,推不出何时重置 —— 只显示用量,不给 pace
            let periods: [(String, LangKey, Double?, Double?, ResetRule?)] = [
                ("daily", .quotaDaily, s.dailyLimit, s.dailyUsed, daily),
                ("weekly", .quotaSevenDays, s.weeklyLimit, s.weeklyUsed, weekly),
                ("monthly", .quotaThirtyDays, s.monthlyLimit, s.monthlyUsed, nil),
            ]
            // 上限为 null 表示这一档不限 —— 不产出桶,而不是产出一个「不限」的桶
            for (id, title, limit, reportedUsed, rule) in periods {
                guard let limit, limit > 0 else { continue }
                gauges.append(QuotaBucket(id: id, title: .localized(title), used: used(reportedUsed), limit: limit,
                                          unit: .money(currency: "USD"),
                                          window: rule?.period(containing: now), rule: rule))
            }
        }

        return Snapshot(
            name: usage.planName.isEmpty ? displayName : usage.planName,
            isActive: usage.isActive,
            gauges: gauges,
            totalCost: usage.totalCost,
            totalRequests: usage.totalRequests,
            totalTokens: usage.totalTokens,
            monthlyCost: nil,
            monthlyRequests: nil,
            fetchedAt: now,
            // 三件事都要齐才算完整(OPT-015)。累计值尤其要紧:它缺一次,`Sample` 就把它
            // 退成 0 落库并推进基线,下一次恢复的累计值会整段被记成当天的新增 ——
            // 实测 `1000 → 缺 → 1200` 当天记了 1200 而不是 200,而且永久记在那里
            hasCompleteUsage: !gauges.isEmpty && !missingUsed
                && usage.totalTokens != nil && usage.totalRequests != nil
        )
    }

    /// 这几个窗口从第一次使用起算,**不是**自然日、自然周 ——
    /// 用「今日」「本周」会说出对方没说过的事
    static func title(forWindow window: String) -> BucketTitle {
        switch window {
        case "5h": return .localized(.quotaFiveHours)
        case "1d": return .localized(.quotaOneDay)
        case "7d": return .localized(.quotaSevenDays)
        default:   return .provider(window)
        }
    }
}

// MARK: - 线上格式

/// sub2api `/v1/usage` 的响应。**属于这个适配器**,别家不该复用。
public struct Sub2APIUsage: Equatable {

    public var planName = ""
    public var isActive = false

    public var quota: Amount?
    public var rateLimits: [RateWindow] = []
    public var subscription: Subscription?
    public var balance: Double?

    /// `usage.total` 的累计值。没报就是 nil,不是 0(不变量 3)
    public var totalCost: Double?
    public var totalRequests: Int?
    public var totalTokens: Double?

    /// 服务端的时区,取自响应里某个时间戳的偏移。订阅模式推算日重置要用它
    public var serverTimeZone: TimeZone?

    /// 只有钱包余额,没有任何周期额度
    public var isWalletOnly: Bool {
        quota == nil && rateLimits.isEmpty && subscription == nil && balance != nil
    }

    /// 已用值一律可选:缺了就是 nil,不是 0(不变量 3、OPT-015)。按 0 显示是映射那一层的决定
    public struct Amount: Equatable {
        public var limit = 0.0
        public var used: Double?
    }

    public struct RateWindow: Equatable {
        public var window = ""
        public var limit = 0.0
        public var used: Double?
        public var start: Date?
        public var resetAt: Date?
        /// 原样的起点字符串,只为读出服务端时区
        var startText: String?
    }

    public struct Subscription: Equatable {
        public var dailyLimit: Double?
        public var dailyUsed: Double?
        public var weeklyLimit: Double?
        public var weeklyUsed: Double?
        public var monthlyLimit: Double?
        public var monthlyUsed: Double?
        public var weeklyWindowStart: Date?
        /// 原样的时间字符串,只为读出服务端时区
        var weeklyWindowStartText: String?
        var expiresAtText: String?
    }
}

// MARK: - 解码

extension Sub2APIUsage {

    /// 没有信封:成功时响应体就是这份对象,失败时 HTTP 状态码非 2xx(见 errorMessage)
    public static func decode(_ data: Data, language: Language) throws -> Sub2APIUsage {
        do {
            return try JSONDecoder().decode(Sub2APIUsage.self, from: data)
        } catch let invalid as InvalidFieldError {
            throw APIError(L10n.format(.errInvalidFieldFormat, language, invalid.field))
        } catch is ProtocolMismatchError {
            throw APIError(L10n.format(.errNotThisProtocolFormat, language, "sub2api"))
        } catch {
            throw APIError(L10n.text(.errUnparsable, language))
        }
    }

    /// 失败响应有**两种**格式,实测都见过:
    /// key 无效是 `{"code":"INVALID_API_KEY","message":…}`,
    /// key 没分组是 Anthropic 风格的 `{"type":"error","error":{"message":…}}`。
    static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = object["message"] as? String, !message.isEmpty { return message }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty { return message }
        return nil
    }
}

extension Sub2APIUsage: Decodable {

    enum CodingKeys: String, CodingKey {
        case planName, isValid, status, quota, balance, usage, subscription
        case rateLimits = "rate_limits"
    }

    enum UsageKeys: String, CodingKey { case total }
    enum TotalKeys: String, CodingKey {
        case actualCost = "actual_cost", requests
        case totalTokens = "total_tokens"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // 协议特征(OPT-016):有效标记(`isValid`,或 `quota_limited` 模式的 `status`)
        // 加上三种形态之一的额度块。实测的三种形态都满足;反代的错误 JSON、空对象都不满足
        let reportsValidity = try c.present(.isValid) || c.present(.status)
        let reportsAnyQuota = try c.present(.quota) || c.present(.rateLimits)
            || c.present(.subscription) || c.present(.balance)
        guard reportsValidity, reportsAnyQuota else { throw ProtocolMismatchError() }

        planName = try c.text(.planName) ?? ""
        // `quota_limited` 模式报 status,另两种只报 isValid
        isActive = try c.flag(.isValid) ?? (try c.text(.status) == "active")
        balance = try c.number(.balance)
        quota = try c.decodeIfPresent(Amount.self, forKey: .quota)
        rateLimits = try c.decodeIfPresent([RateWindow].self, forKey: .rateLimits) ?? []
        subscription = try c.decodeIfPresent(Subscription.self, forKey: .subscription)

        if try c.present(.usage) {
            let usage = try c.nestedContainer(keyedBy: UsageKeys.self, forKey: .usage)
            if try usage.present(.total) {
                let total = try usage.nestedContainer(keyedBy: TotalKeys.self, forKey: .total)
                totalCost = try total.number(.actualCost)
                totalRequests = try total.integer(.requests)
                totalTokens = try total.number(.totalTokens)
            }
        }

        // 服务端时区:订阅的 expires_at 最稳(有订阅就一定有),其次任一窗口的起点
        let stamps = [subscription?.expiresAtText, subscription?.weeklyWindowStartText]
            + rateLimits.map(\.startText)
        serverTimeZone = stamps.lazy.compactMap { Sub2APITimeZone.parse($0) }.first
    }
}

extension Sub2APIUsage.Amount: Decodable {
    enum CodingKeys: String, CodingKey { case limit, used }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limit = try c.number(.limit) ?? 0
        used = try c.number(.used)
    }
}

extension Sub2APIUsage.RateWindow: Decodable {
    enum CodingKeys: String, CodingKey {
        case window, limit, used
        case windowStart = "window_start", resetAt = "reset_at"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        window = try c.text(.window) ?? ""
        limit = try c.number(.limit) ?? 0
        used = try c.number(.used)
        startText = try c.text(.windowStart)
        // 时间格式和 tu-zi 一样(带微秒和偏移),共用同一个解析器
        start = TuziDate.parse(startText)
        resetAt = TuziDate.parse(try c.text(.resetAt))
    }
}

extension Sub2APIUsage.Subscription: Decodable {
    enum CodingKeys: String, CodingKey {
        case dailyLimit = "daily_limit_usd", dailyUsed = "daily_usage_usd"
        case weeklyLimit = "weekly_limit_usd", weeklyUsed = "weekly_usage_usd"
        case monthlyLimit = "monthly_limit_usd", monthlyUsed = "monthly_usage_usd"
        case weeklyWindowStart = "weekly_window_start", expiresAt = "expires_at"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dailyLimit = try c.number(.dailyLimit)
        dailyUsed = try c.number(.dailyUsed)
        weeklyLimit = try c.number(.weeklyLimit)
        weeklyUsed = try c.number(.weeklyUsed)
        monthlyLimit = try c.number(.monthlyLimit)
        monthlyUsed = try c.number(.monthlyUsed)
        weeklyWindowStartText = try c.text(.weeklyWindowStart)
        weeklyWindowStart = TuziDate.parse(weeklyWindowStartText)
        expiresAtText = try c.text(.expiresAt)
    }
}

/// 从 ISO8601 时间戳末尾读出时区偏移:`…+08:00` → UTC+8,`…Z` → UTC。读不出就是 nil
enum Sub2APITimeZone {
    static func parse(_ text: String?) -> TimeZone? {
        guard let text, !text.isEmpty else { return nil }
        if text.hasSuffix("Z") { return TimeZone(secondsFromGMT: 0) }
        let tail = text.suffix(6)   // ±HH:MM
        guard tail.count == 6, let sign = tail.first, sign == "+" || sign == "-",
              tail.dropFirst(3).first == ":",
              let hours = Int(tail.dropFirst().prefix(2)), let minutes = Int(tail.suffix(2))
        else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }
}
