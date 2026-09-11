//
//  HistoryModels.swift — 历史采样的数据结构与纯策略
//
//  这里只放不碰数据库、不碰 UI 的逻辑,全部可单测。
//  真正的读写在 HistoryStore.swift。
//

import Foundation
import CryptoKit

// MARK: - 采样

/// 一次成功刷新留下的快照。金额字段来自接口的当前值,tokens/requests 是**累计值**。
public struct Sample: Equatable {
    public let at: Date
    public let totalCost: Double
    public let dailyCost: Double
    public let weeklyOpusCost: Double
    public let windowCost: Double
    public let allTokens: Double
    public let requests: Int

    public init(at: Date, totalCost: Double, dailyCost: Double,
                weeklyOpusCost: Double, windowCost: Double,
                allTokens: Double, requests: Int) {
        self.at = at
        self.totalCost = totalCost
        self.dailyCost = dailyCost
        self.weeklyOpusCost = weeklyOpusCost
        self.windowCost = windowCost
        self.allTokens = allTokens
        self.requests = requests
    }

    /// 除时间戳外是否有任何数值变化
    public func differs(from other: Sample) -> Bool {
        totalCost != other.totalCost
            || dailyCost != other.dailyCost
            || weeklyOpusCost != other.weeklyOpusCost
            || windowCost != other.windowCost
            || allTokens != other.allTokens
            || requests != other.requests
    }

    /// 按种类取对应的额度值,便于按额度切分周期
    public func cost(for kind: QuotaKind) -> Double {
        switch kind {
        case .total:      return totalCost
        case .daily:      return dailyCost
        case .weeklyOpus: return weeklyOpusCost
        case .window:     return windowCost
        }
    }
}

/// 按天聚合的 token 用量
public struct TokenDay: Equatable {
    public let day: String        // yyyy-MM-dd(本地时区)
    public let tokens: Double
    public let requests: Int

    public init(day: String, tokens: Double, requests: Int) {
        self.day = day
        self.tokens = tokens
        self.requests = requests
    }
}

// MARK: - 采样策略

/// changes-plus-anchor:有变化就记,没变化也每隔一段时间记一条锚点。
/// 锚点的意义是把「这段时间确实没用」和「app 根本没开着」区分开 ——
/// 否则曲线上的一段空白没法解释。
public enum SamplingPolicy {
    public static let anchorInterval: TimeInterval = 15 * 60

    public static func shouldRecord(previous: Sample?,
                                    current: Sample,
                                    anchorInterval: TimeInterval = anchorInterval) -> Bool {
        guard let previous else { return true }
        if current.differs(from: previous) { return true }
        return current.at.timeIntervalSince(previous.at) >= anchorInterval
    }
}

// MARK: - token 增量

/// 接口给的是**累计** token 数,按天用量得靠相邻采样做差。
public enum TokenDelta {

    /// 超过这个间隔就不认这次差值 —— 说不清它是哪天用掉的
    public static let maxGap: TimeInterval = 30 * 60

    public struct Delta: Equatable {
        public let tokens: Double
        public let requests: Int
    }

    /// 返回 nil 表示**只重建基线、不产生增量**。三种情况:
    /// 1. 没有前值(首次安装)—— 直接把累计值当增量会把上亿的历史全算进今天
    /// 2. 间隔过大(app 关了很久)—— 这段增量横跨多天,归给哪天都是编的
    /// 3. 累计值变小(服务端重置或换了 key)—— 不能产生负增量
    public static func between(previous: Sample?,
                               current: Sample,
                               maxGap: TimeInterval = maxGap) -> Delta? {
        guard let previous else { return nil }

        let gap = current.at.timeIntervalSince(previous.at)
        guard gap > 0, gap <= maxGap else { return nil }

        let tokens = current.allTokens - previous.allTokens
        let requests = current.requests - previous.requests
        guard tokens >= 0, requests >= 0 else { return nil }
        guard tokens > 0 || requests > 0 else { return nil }

        return Delta(tokens: tokens, requests: requests)
    }
}

// MARK: - 空档

public enum HistoryGaps {
    /// 相邻采样超过这个间隔就算断档
    public static let threshold: TimeInterval = 30 * 60

    /// 把采样切成连续的段。段与段之间是 app 没运行的时间,
    /// 画图时要渲染成阴影,**不能直接连线** —— 那等于凭空捏造中间的用量。
    public static func segments(_ samples: [Sample],
                                threshold: TimeInterval = threshold) -> [[Sample]] {
        split(samples) { previous, current in
            current.at.timeIntervalSince(previous.at) > threshold
        }
    }
}

// MARK: - 重置周期

public enum QuotaCycles {
    /// 按某条额度切分重置周期:计数器一旦下降,就说明跨过了重置边界。
    /// 每个周期各画一条曲线,不跨重置平滑 —— 否则会出现一条从 0 猛跳回满格的假线。
    public static func split(_ samples: [Sample], kind: QuotaKind) -> [[Sample]] {
        HistoryGaps.split(samples) { previous, current in
            current.cost(for: kind) < previous.cost(for: kind)
        }
    }
}

extension HistoryGaps {
    /// 按给定条件在相邻两条之间断开
    static func split(_ samples: [Sample],
                      breakBetween: (Sample, Sample) -> Bool) -> [[Sample]] {
        var result: [[Sample]] = []
        var current: [Sample] = []

        for sample in samples {
            if let last = current.last, breakBetween(last, sample) {
                result.append(current)
                current = []
            }
            current.append(sample)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

// MARK: - 账号分区

public enum AccountKey {
    /// 用 apiId 的 SHA-256 做分区键。换 key 时历史自动隔离,不会串数据;
    /// 同时数据库里也不会留下 apiId 原文。
    public static func derive(apiId: String) -> String {
        SHA256.hash(data: Data(apiId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - 日期键

public enum DayKey {
    /// 按本地时区归日,格式 yyyy-MM-dd
    public static func string(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
