//
//  RelayModels.swift — claude-relay-service 的线上格式
//
//  **这是那一家的数据模型,不是通用模型。** 从前它叫 Models.swift、住在一个
//  听起来像通用层的位置,于是下一个人很容易把第二家的字段也加进来,
//  或者拿 UserStats 去接别家的响应 —— 那正是不变量 6 要挡的事(EXT-009)。
//
//  tu-zi 的对应物是 TuziQuota,住在 TuziProvider.swift 里,和这里没有一个字段相同:
//  信封是 {code,message,data} 而不是 {success,data},额度是日/周/月而不是这四条。
//
//  通用的严格解码机制(InvalidFieldError、容忍缺失/拒绝无效的那套辅助)
//  在 Decoding.swift,两家共用。
//

import Foundation

// MARK: - limits

/// 对应响应里的 `data.limits`
public struct Limits: Decodable, Equatable {
    // 上限(0 表示不限)
    public var totalCostLimit = 0.0
    public var dailyCostLimit = 0.0
    public var weeklyOpusCostLimit = 0.0
    public var rateLimitCost = 0.0

    // 当前用量
    public var currentTotalCost = 0.0
    public var currentDailyCost = 0.0
    public var weeklyOpusCost = 0.0
    public var currentWindowCost = 0.0

    // 限流窗口
    public var rateLimitWindow = 0          // 分钟
    public var rateLimitRequests = 0
    public var currentWindowRequests = 0
    public var currentWindowTokens = 0.0
    public var windowStartTime = 0.0        // 毫秒时间戳
    public var windowEndTime = 0.0          // 毫秒时间戳
    public var windowRemainingSeconds = 0

    // 周重置(服务端 getDay(): 0=周日 … 6=周六)
    public var weeklyResetDay = -1
    public var weeklyResetHour = -1

    public var concurrencyLimit = 0

    /// 四个「当前用量」是不是都真的在响应里(既非缺失也非 null)。
    /// 它们要进历史,所以「0」和「不知道」必须能分开。
    public var hasAllCurrentCosts = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case totalCostLimit, dailyCostLimit, weeklyOpusCostLimit, rateLimitCost
        case currentTotalCost, currentDailyCost, weeklyOpusCost, currentWindowCost
        case rateLimitWindow, rateLimitRequests, currentWindowRequests, currentWindowTokens
        case windowStartTime, windowEndTime, windowRemainingSeconds
        case weeklyResetDay, weeklyResetHour, concurrencyLimit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // 上限缺失时退回 0 是有意义的:0 在这里本来就表示「不限」
        totalCostLimit = try c.number(.totalCostLimit) ?? 0
        dailyCostLimit = try c.number(.dailyCostLimit) ?? 0
        weeklyOpusCostLimit = try c.number(.weeklyOpusCostLimit) ?? 0
        rateLimitCost = try c.number(.rateLimitCost) ?? 0

        // 这四个不一样 —— 它们会被原样写进历史采样,
        // 所以要留住「到底有没有观测到」这个事实,而不只是退回 0
        let total = try c.number(.currentTotalCost)
        let daily = try c.number(.currentDailyCost)
        let opus = try c.number(.weeklyOpusCost)
        let window = try c.number(.currentWindowCost)

        currentTotalCost = total ?? 0
        currentDailyCost = daily ?? 0
        weeklyOpusCost = opus ?? 0
        currentWindowCost = window ?? 0
        hasAllCurrentCosts = total != nil && daily != nil && opus != nil && window != nil

        rateLimitWindow = try c.integer(.rateLimitWindow) ?? 0
        rateLimitRequests = try c.integer(.rateLimitRequests) ?? 0
        currentWindowRequests = try c.integer(.currentWindowRequests) ?? 0
        currentWindowTokens = try c.number(.currentWindowTokens) ?? 0
        windowStartTime = try c.number(.windowStartTime) ?? 0
        windowEndTime = try c.number(.windowEndTime) ?? 0
        windowRemainingSeconds = try c.integer(.windowRemainingSeconds) ?? 0

        // 周重置日/时可以合法地为 0,所以缺失时要能区分出「没有」→ 用 -1
        weeklyResetDay = try c.integer(.weeklyResetDay) ?? -1
        weeklyResetHour = try c.integer(.weeklyResetHour) ?? -1

        concurrencyLimit = try c.integer(.concurrencyLimit) ?? 0
    }
}

// MARK: - usage

/// 对应 `data.usage.total` 与 batch 接口的 `monthlyUsage`
public struct UsageBlock: Decodable, Equatable {
    public var allTokens = 0.0
    public var requests = 0
    public var cost = 0.0

    /// 两个**累计值**是不是都真的在响应里。
    /// 它们靠相邻两次做差得出当天用量,一次假的 0 会在下一次恢复正常时
    /// 变成一整笔凭空冒出来的用量。`cost` 不参与历史,所以不算在内。
    public var hasAllTotals = true

    public init() {}

    enum CodingKeys: String, CodingKey { case allTokens, requests, cost }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tokens = try c.number(.allTokens)
        let count = try c.integer(.requests)

        allTokens = tokens ?? 0
        requests = count ?? 0
        cost = try c.number(.cost) ?? 0
        hasAllTotals = tokens != nil && count != nil
    }
}

// MARK: - user-stats

public struct UserStats: Decodable, Equatable {
    public var name = ""
    public var isActive = false
    public var limits = Limits()
    public var total = UsageBlock()

    /// 要进历史的六个数值(四个当前用量 + 两个累计值)这次是不是**都真的观测到了**。
    ///
    /// 缺失和 null 会被容忍成 0 —— 那是为了兼容不同部署,显示成 0 顶多是难看。
    /// 但写进历史就不一样了,0 和「不知道」在那里是两件完全不同的事:
    ///
    /// · 曲线上会多出一次并不存在的归零;
    /// · 下一次正常值恢复时,那段差值会被当成一大笔凭空冒出来的新增用量;
    /// · 日额度的假下降还会让重置学习把它认成一次真的重置 —— 而那个结论只学一次,
    ///   学错了就一直错下去。
    ///
    /// 所以这种快照可以显示,但不能入库。
    public var hasCompleteUsage = true

    public init() {}

    enum CodingKeys: String, CodingKey { case name, isActive, limits, usage }
    enum UsageKeys: String, CodingKey { case total }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.text(.name) ?? ""
        isActive = try c.flag(.isActive) ?? false

        let decodedLimits = try c.object(Limits.self, forKey: .limits)
        limits = decodedLimits ?? Limits()

        let decodedTotal = try c.nested(UsageKeys.self, forKey: .usage)
            .flatMap { try $0.object(UsageBlock.self, forKey: .total) }
        total = decodedTotal ?? UsageBlock()

        // 整块缺失(limits / usage 没给)和块内某个字段缺失,后果一样 —— 都是没观测到
        hasCompleteUsage = (decodedLimits?.hasAllCurrentCosts ?? false)
            && (decodedTotal?.hasAllTotals ?? false)
    }
}

// MARK: - 信封

/// 两个接口统一是 `{ "success": bool, "data": {...}, "message": string }`
public struct Envelope<T: Decodable>: Decodable {
    public let success: Bool
    public let data: T?
    public let message: String?
}

public enum ResponseDecoder {
    /// 拆信封:success 为假或 data 缺失都当成错误抛出。
    /// 服务端自带 message 时优先用它 —— 那是对方给的具体原因,比我们的兜底文案有用。
    public static func unwrap<T: Decodable>(_ type: T.Type,
                                            from data: Data,
                                            language: Language = .en) throws -> T {
        let env: Envelope<T>
        do {
            env = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch let invalid as InvalidFieldError {
            // 「某个字段坏了」和「整份东西根本不是这个接口的响应」是两回事。
            // 前者要把字段名报出来 —— 否则对着一个自建中转站根本无从排查。
            throw APIError(L10n.format(.errInvalidFieldFormat, language, invalid.field))
        } catch {
            throw APIError(L10n.text(.errUnparsable, language))
        }
        guard env.success, let payload = env.data else {
            throw APIError(env.message ?? L10n.text(.errApiFailed, language))
        }
        return payload
    }
}
