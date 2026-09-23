//
//  TuziProvider.swift — tu-zi 订阅适配器
//
//  第二个适配器,也是适配器边界第一次真正被检验:它和中转站几乎没有一处相同 ——
//  认证靠 Bearer token 而不是查询参数、信封是 code/message/data 而不是
//  success/data、额度是日/周/月三层嵌套而不是那四条固定项、重置时刻由服务端
//  直接给出而不必观测。整个通用层为此没有长出一个 if,那正是 EXT-002 的验收标准。
//
//  三件和这家协议有关、又特别容易做错的事,各自写在下面对应的位置:
//
//  1. `daily_used` 这类字段**没有任何单位标记**,只有 `fuel_pack.available_usd`
//     明确带了 `_usd`。所以前者一律 `.unknown`,显示裸数字 —— 见 buildSnapshot。
//  2. 顶层的 `quota` / `quota_used` / `rate_limit_*` / `usage_*` **全部忽略**。
//     它们是另一条计费路径的字段,当前未启用 —— 「不适用」不是「用了 0」。
//  3. 重置一律 `serverProvided`,**不外推**。对方每次都给 reset_at,不需要推。
//
//  账户身份来自响应里的 `key_id`,不是用户输入的那把 key —— 见 accountIDComesFromResponse。
//

import Foundation

public struct TuziProvider: UsageProviderAdapter {

    public static let id = "tu-zi"

    /// 查订阅额度的那台机器。和用户平时访问的 store.tu-zi.com 不是同一个域名,
    /// 所以不能从用户给的网址里推 —— 这里写死协议里那一个。
    static let baseURL = "https://coding.tu-zi.com"
    static let quotaPath = "/reseller/v1/quota"

    public init() {}

    public var providerID: String { Self.id }
    public var displayName: String { "tu-zi" }

    /// `sk-` key 能发起真实 API 调用、能花钱。只能声明 `.secret` ——
    /// 于是 `Config.apply` 那道守卫会把它挡在明文存储之外,逼着走钥匙串。
    public var credentialSensitivity: CredentialSensitivity { .secret }

    public var inputExample: String { "sk-…（tu-zi 的 API Key）" }

    /// 身份在响应里,不在输入里:用户给的是一把 key,`key_id` 得问了才知道。
    public var accountIDComesFromResponse: Bool { true }

    /// 这家给什么、不给什么。
    ///
    /// **`costAmounts` 刻意为假**,尽管它报的数字看着就是钱:除了 `fuel_pack.available_usd`,
    /// 没有一个额度字段带币种标记。声明成真等于替对方承认了一件它没说过的事,
    /// 而界面会据此给数字加上 `$`。
    ///
    /// 三个「不给」都有实际后果:没有累计 token / 请求数,面板上那一整行不显示、
    /// token 柱状图一直空着;没有 `usageHistory`,历史只能从装上那天起本地积累。
    ///
    /// `dailyResetTime` 为真是这家**相对中转站的实质优势** —— 日重置时刻是对方
    /// 明确给的,界面不必再标「推算」,也不需要 DailyResetLearner 去观测。
    public var capabilities: ProviderCapabilities {
        [.windowResetTimes, .weeklyResetSchedule, .dailyResetTime, .monthlyAggregate]
    }

    // MARK: - 识别与解析

    /// 输入是一把 key,不是网址。
    ///
    /// `sk-` 这个前缀并不为 tu-zi 独有(不少家都用),所以这只是**候选提示**,
    /// 和中转站那边一样 —— 真正的确认靠 `fetchUsage` 跑一次真请求。
    public func detect(_ input: String) -> Bool {
        Self.key(from: input) != nil
    }

    public func parseConnection(_ input: String) -> Connection? {
        guard let key = Self.key(from: input) else { return nil }

        // 身份此刻还不知道,先放占位 —— verify 跑完才拿得到真的 key_id。
        // 它不该进存储:`accountIDComesFromResponse` 为真时,保存流程会先经过
        // `ProviderRegistry.resolvedForSaving` 换成真身份,换不出来就不让保存。
        return Connection(
            account: AccountIdentity(providerID: providerID,
                                     baseURL: Self.baseURL,
                                     apiId: AccountIdentity.unresolvedAccountID),
            secret: key
        )
    }

    private static func key(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("sk-"), text.count > 3,
              !text.contains(where: { $0.isWhitespace })
        else { return nil }
        return text
    }

    /// 用户自助管理订阅的页面。和统计接口不同域 —— 正是适配器各管各的理由。
    public func managementURL(for account: AccountIdentity) -> URL? {
        guard account.isConfigured else { return nil }
        return URL(string: "https://store.tu-zi.com/user/usage/codex")
    }

    // MARK: - 抓取

    public func fetchUsage(_ connection: Connection, schedule: ResetSchedule,
                           language: Language) async throws -> Snapshot {
        // schedule 整个用不上:这家每条额度的起止时刻都由服务端直接给出,
        // 不需要 app 观测的那套推算。这不是偷懒,是能力声明的兑现。
        let quota = try await fetch(connection, language: language)
        return buildSnapshot(quota, now: Date())
    }

    /// 覆写默认实现,好在**同一次请求**里把 `key_id` 一并带出来。
    /// 分两次请求会留下「验的是 A、存的是 B」的缝。
    public func verify(_ connection: Connection, language: Language) async throws -> ConnectionReport {
        let quota = try await fetch(connection, language: language)
        return ConnectionReport(snapshot: buildSnapshot(quota, now: Date()),
                                providerID: providerID,
                                displayName: displayName,
                                capabilities: capabilities,
                                stableAccountID: quota.accountID)
    }

    private func fetch(_ connection: Connection, language: Language) async throws -> TuziQuota {
        guard let secret = connection.secret, !secret.isEmpty else {
            throw APIError(L10n.text(.errMissingCredential, language))
        }
        guard let url = URL(string: connection.account.baseURL + Self.quotaPath) else {
            throw APIError(L10n.format(.errInvalidURLFormat, language, connection.account.baseURL))
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: req)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError(L10n.format(.errHTTPFormat, language, http.statusCode))
        }
        return try TuziQuota.decode(data, language: language)
    }
}

// MARK: - 响应映射

extension TuziProvider {

    /// public 是为了能单测这段映射(测试是独立模块)。
    /// 通用层只该经由 `fetchUsage` 拿到 Snapshot。
    public func buildSnapshot(_ quota: TuziQuota, now: Date) -> Snapshot {
        let s = quota.subscription

        // 三层窗口**同时展示,不相加**:样例里 weekly_used == monthly_used,
        // 因为订阅 09-17 才激活,同一笔消费落在两个窗口里。加起来会把它算两遍。
        //
        // 单位一律 .unknown:这些字段没有任何币种标记(只有 fuel_pack.available_usd 有)。
        // 打成 $29.22 就是凭空给一个我们并不知道单位的数字安一个币种。
        let gauges: [QuotaBucket] = [
            bucket(id: "daily", title: .quotaDaily, window: s.daily, now: now),
            bucket(id: "weekly", title: .quotaWeekly, window: s.weekly, now: now),
            bucket(id: "monthly", title: .quotaMonthly, window: s.monthly, now: now),
        ].compactMap { $0 }

        return Snapshot(
            name: s.groupName.isEmpty ? displayName : s.groupName,
            isActive: quota.isActive,
            gauges: gauges,
            // 这家一个累计值都不报。传 nil 而不是 0 —— 面板据此整行不显示,
            // 而 0 会被读成「一次请求都没发过」(不变量 3)。
            totalCost: nil,
            totalRequests: nil,
            totalTokens: nil,
            // 月额度已经是上面那个桶了,不在这里再报一遍 ——
            // 同一个数字出现在两处,用户会以为是两件事。
            monthlyCost: nil,
            monthlyRequests: nil,
            fetchedAt: now,
            hasCompleteUsage: quota.hasCompleteUsage
        )
    }

    /// 一层窗口 → 一个额度桶。对方没报这一层就**不产出桶**,而不是产出一个 0。
    private func bucket(id: String, title: LangKey,
                        window: TuziQuota.Window, now: Date) -> QuotaBucket? {
        guard window.isReported else { return nil }

        // 重置一律 serverProvided,**不外推**:对方每次都给 reset_at,不需要推,
        // 也推不出来 —— 样例里日窗口恰好是 +24 小时整,既可能是固定时长也可能是
        // 日历规则,一份样例分不出来。用 serverProvided 就根本不必分(EXT-004)。
        let rule = window.start.flatMap { start in
            window.resetAt.map { end in
                ResetRule(.serverProvided(start: start, end: end), provenance: .server)
            }
        }

        return QuotaBucket(id: id,
                           title: .localized(title),
                           used: window.used,
                           limit: window.limit,
                           unit: .unknown,
                           window: rule?.period(containing: now),
                           rule: rule)
    }
}

// MARK: - 线上格式

/// tu-zi 的响应。**属于这个适配器**,别家不该复用 ——
/// 和 Models.swift 里那套 UserStats/Limits 是同样的关系。
public struct TuziQuota: Equatable {

    /// 对方报的账户标识(`key_id`)。历史分区键就用它 ——
    /// 用户换一把 key 而 key_id 不变时,攒下的曲线不会断。
    public var accountID: String = ""

    public var isActive = false
    public var subscription = Subscription()

    /// 三层窗口的六个数值是不是都真的观测到了。
    /// 缺任何一个都不该进历史 —— 那些 0 是退回来的,不是「真的用了 0」。
    public var hasCompleteUsage = false

    public struct Subscription: Equatable {
        public var groupName = ""
        public var daily = Window()
        public var weekly = Window()
        public var monthly = Window()
    }

    /// 一层窗口。`isReported` 为假表示**对方根本没报这一层**,
    /// 和「报了,用量是 0」是两件事 —— 前者不该产出一条额度。
    public struct Window: Equatable {
        public var used = 0.0
        public var limit = 0.0
        public var start: Date?
        public var resetAt: Date?
        public var isReported = false
    }
}

// MARK: - 解码

extension TuziQuota {

    /// 信封和中转站那套完全不同:`{code, message, data}`,`code == 0` 才是成功。
    /// 所以不能复用 `ResponseDecoder.unwrap` —— 那是**那家**的信封。
    ///
    /// public 是为了能单测这段解码(测试是独立模块)。
    /// 通用层只该经由 `fetchUsage` 拿到 Snapshot。
    public static func decode(_ data: Data, language: Language) throws -> TuziQuota {
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)

            guard envelope.code == 0, let quota = envelope.quota else {
                // 对方给了具体原因就用它 —— 比我们的兜底文案有用得多
                throw APIError(envelope.message ?? L10n.text(.errApiFailed, language))
            }
            return quota

        } catch let invalid as InvalidFieldError {
            // 「某个字段坏了」和「整份东西根本不是这个接口的响应」是两回事:
            // 前者要把字段名报出来,否则无从排查
            throw APIError(L10n.format(.errInvalidFieldFormat, language, invalid.field))
        } catch let api as APIError {
            throw api
        } catch {
            throw APIError(L10n.text(.errUnparsable, language))
        }
    }

    private struct Envelope: Decodable {
        let code: Int?
        let message: String?
        let quota: TuziQuota?

        enum CodingKeys: String, CodingKey { case code, message, data }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.integer(.code)
            message = try? c.decode(String.self, forKey: .message)
            quota = try c.decodeIfPresent(TuziQuota.self, forKey: .data)
        }
    }
}

extension TuziQuota: Decodable {

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case status
        case subscription
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // key_id 是个数字,而身份字段是字符串 —— 存进 apiId 的是它的十进制写法。
        // 缺了就留空串:那样 `resolvedForSaving` 会拒绝保存,而不是拿占位值存进去。
        accountID = try c.integer(.keyID).map(String.init) ?? ""

        isActive = (try? c.decode(String.self, forKey: .status)) == "active"
        subscription = try c.decodeIfPresent(Subscription.self, forKey: .subscription)
            ?? Subscription()

        // 至少有一层窗口的**用量和上限都**拿到了,这份快照才算能进历史。
        //
        // 一层都没有时不是「今天没用」,是这份响应里根本没有额度信息 —— 那些 0
        // 是退回来的。半份的窗口(报了用量没报上限)整层丢掉,不猜那个缺的数:
        // `QuotaBucket.limit` 里的 0 意思是「不限额」,拿它顶替「不知道」
        // 会把一条有限额的额度显示成无限,正是不变量 3 禁止的事。
        hasCompleteUsage = subscription.daily.isReported
            || subscription.weekly.isReported
            || subscription.monthly.isReported
    }
}

extension TuziQuota.Subscription: Decodable {

    // 三层窗口在响应里是**扁平的带前缀字段**,不是嵌套对象
    enum CodingKeys: String, CodingKey {
        case groupName = "group_name"
        case dailyUsed = "daily_used", dailyLimit = "daily_limit"
        case dailyWindowStart = "daily_window_start", dailyResetAt = "daily_reset_at"
        case weeklyUsed = "weekly_used", weeklyLimit = "weekly_limit"
        case weeklyWindowStart = "weekly_window_start", weeklyResetAt = "weekly_reset_at"
        case monthlyUsed = "monthly_used", monthlyLimit = "monthly_limit"
        case monthlyWindowStart = "monthly_window_start", monthlyResetAt = "monthly_reset_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        groupName = (try? c.decode(String.self, forKey: .groupName)) ?? ""

        daily = try TuziQuota.Window(c, used: .dailyUsed, limit: .dailyLimit,
                                     start: .dailyWindowStart, reset: .dailyResetAt)
        weekly = try TuziQuota.Window(c, used: .weeklyUsed, limit: .weeklyLimit,
                                      start: .weeklyWindowStart, reset: .weeklyResetAt)
        monthly = try TuziQuota.Window(c, used: .monthlyUsed, limit: .monthlyLimit,
                                       start: .monthlyWindowStart, reset: .monthlyResetAt)
    }
}

extension TuziQuota.Window {

    fileprivate init(_ c: KeyedDecodingContainer<TuziQuota.Subscription.CodingKeys>,
                     used usedKey: TuziQuota.Subscription.CodingKeys,
                     limit limitKey: TuziQuota.Subscription.CodingKeys,
                     start startKey: TuziQuota.Subscription.CodingKeys,
                     reset resetKey: TuziQuota.Subscription.CodingKeys) throws {
        let reportedUsed = try c.number(usedKey)
        let reportedLimit = try c.number(limitKey)

        // 两个数值都在才算「报了这一层」。理由见 TuziQuota.hasCompleteUsage。
        isReported = reportedUsed != nil && reportedLimit != nil
        used = reportedUsed ?? 0
        limit = reportedLimit ?? 0

        start = TuziDate.parse(try? c.decode(String.self, forKey: startKey))
        resetAt = TuziDate.parse(try? c.decode(String.self, forKey: resetKey))
    }
}

// MARK: - 时刻

/// 这家给的是带偏移和**微秒**的 ISO8601:`2026-09-21T11:19:02.793995+08:00`。
///
/// 两个 formatter 都要:带小数秒的解析器遇到不带小数秒的字符串会直接失败,
/// 反过来也一样。对方哪天省掉小数位,不该让整条额度消失。
enum TuziDate {

    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 解析不出来就是 nil —— 那条额度于是没有窗口,不做速度判断,
    /// 而不是安一个编出来的时刻。
    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return withFraction.date(from: text) ?? plain.date(from: text)
    }
}
