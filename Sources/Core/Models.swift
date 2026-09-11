//
//  Models.swift — 中转站接口的数据模型
//
//  解码策略:宽松。字段缺失或为 null 一律给默认值,
//  换一个 claude-relay-service 部署、或对方加减字段,都不会让整个响应解码失败。
//

import Foundation

// MARK: - 宽松解码

private extension KeyedDecodingContainer {
    func dbl(_ k: Key) -> Double { (try? decode(Double.self, forKey: k)) ?? 0 }
    func i(_ k: Key) -> Int { (try? decode(Int.self, forKey: k)) ?? 0 }
    func str(_ k: Key) -> String { (try? decode(String.self, forKey: k)) ?? "" }
    func bool(_ k: Key) -> Bool { (try? decode(Bool.self, forKey: k)) ?? false }
}

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
        totalCostLimit = c.dbl(.totalCostLimit)
        dailyCostLimit = c.dbl(.dailyCostLimit)
        weeklyOpusCostLimit = c.dbl(.weeklyOpusCostLimit)
        rateLimitCost = c.dbl(.rateLimitCost)

        currentTotalCost = c.dbl(.currentTotalCost)
        currentDailyCost = c.dbl(.currentDailyCost)
        weeklyOpusCost = c.dbl(.weeklyOpusCost)
        currentWindowCost = c.dbl(.currentWindowCost)

        rateLimitWindow = c.i(.rateLimitWindow)
        rateLimitRequests = c.i(.rateLimitRequests)
        currentWindowRequests = c.i(.currentWindowRequests)
        currentWindowTokens = c.dbl(.currentWindowTokens)
        windowStartTime = c.dbl(.windowStartTime)
        windowEndTime = c.dbl(.windowEndTime)
        windowRemainingSeconds = c.i(.windowRemainingSeconds)

        // 周重置日/时可以合法地为 0,所以缺失时要能区分出「没有」→ 用 -1
        weeklyResetDay = (try? c.decode(Int.self, forKey: .weeklyResetDay)) ?? -1
        weeklyResetHour = (try? c.decode(Int.self, forKey: .weeklyResetHour)) ?? -1

        concurrencyLimit = c.i(.concurrencyLimit)
    }
}

// MARK: - usage

/// 对应 `data.usage.total` 与 batch 接口的 `monthlyUsage`
public struct UsageBlock: Decodable, Equatable {
    public var allTokens = 0.0
    public var requests = 0
    public var cost = 0.0

    public init() {}

    enum CodingKeys: String, CodingKey { case allTokens, requests, cost }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allTokens = c.dbl(.allTokens)
        requests = c.i(.requests)
        cost = c.dbl(.cost)
    }
}

// MARK: - user-stats

public struct UserStats: Decodable, Equatable {
    public var name = ""
    public var isActive = false
    public var limits = Limits()
    public var total = UsageBlock()

    public init() {}

    enum CodingKeys: String, CodingKey { case name, isActive, limits, usage }
    enum UsageKeys: String, CodingKey { case total }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.str(.name)
        isActive = c.bool(.isActive)
        limits = (try? c.decode(Limits.self, forKey: .limits)) ?? Limits()
        if let usage = try? c.nestedContainer(keyedBy: UsageKeys.self, forKey: .usage) {
            total = (try? usage.decode(UsageBlock.self, forKey: .total)) ?? UsageBlock()
        }
    }
}

// MARK: - 信封

/// 两个接口统一是 `{ "success": bool, "data": {...}, "message": string }`
public struct Envelope<T: Decodable>: Decodable {
    public let success: Bool
    public let data: T?
    public let message: String?
}

public struct APIError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
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
        } catch {
            throw APIError(L10n.text(.errUnparsable, language))
        }
        guard env.success, let payload = env.data else {
            throw APIError(env.message ?? L10n.text(.errApiFailed, language))
        }
        return payload
    }
}
