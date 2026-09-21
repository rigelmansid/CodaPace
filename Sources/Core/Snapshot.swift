//
//  Snapshot.swift — 一次成功抓取的完整结果
//

import Foundation

// MARK: - 菜单栏显示哪条额度

public enum MenuBarSource: Equatable, Hashable {
    /// 自动:显示最紧张的那条
    case auto
    /// 固定显示某一条
    case fixed(QuotaKind)
}

// MARK: - 快照

public struct Snapshot: Equatable {
    public let name: String
    public let isActive: Bool

    /// 显示顺序:总额度 → 今日 → 本周 Opus → 限流窗口
    public let gauges: [Gauge]

    public let totalCost: Double
    public let totalRequests: Int
    public let totalTokens: Double

    public let monthlyCost: Double?
    public let monthlyRequests: Int?

    public let fetchedAt: Date

    /// 这份快照的用量数值是不是都真的观测到了。false 表示响应里有必要字段缺失或为 null,
    /// 相应的数字是退回来的 0 —— 可以显示,但**不能进历史**。理由见 `UserStats.hasCompleteUsage`。
    public let hasCompleteUsage: Bool

    public init(name: String, isActive: Bool, gauges: [Gauge],
                totalCost: Double, totalRequests: Int, totalTokens: Double,
                monthlyCost: Double?, monthlyRequests: Int?, fetchedAt: Date,
                hasCompleteUsage: Bool = true) {
        self.name = name
        self.isActive = isActive
        self.gauges = gauges
        self.totalCost = totalCost
        self.totalRequests = totalRequests
        self.totalTokens = totalTokens
        self.monthlyCost = monthlyCost
        self.monthlyRequests = monthlyRequests
        self.fetchedAt = fetchedAt
        self.hasCompleteUsage = hasCompleteUsage
    }

    public func gauge(_ kind: QuotaKind) -> Gauge? {
        gauges.first { $0.kind == kind }
    }

    /// 有上限的额度(不限的没法画进度)
    public var limited: [Gauge] { gauges.filter { !$0.unlimited } }

    /// 菜单栏该显示哪条。
    ///
    /// `.auto` 的规则:取剩余最少的一条,但**排除限流窗口** ——
    /// 它每小时重置一次,比例反复大起大落,会让菜单栏的数字和颜色不停跳。
    /// 唯一的例外是限流窗口已经吃紧(剩余 < 20%),这时马上就要被限流了,值得顶上来。
    public func menuBarGauge(source: MenuBarSource) -> Gauge? {
        switch source {
        case .fixed(let kind):
            if let g = gauge(kind), !g.unlimited { return g }
            return menuBarGauge(source: .auto)

        case .auto:
            if let window = gauge(.window), !window.unlimited,
               window.remainingRatio < QuotaThresholds.critical {
                return window
            }
            let candidates = limited.filter { $0.kind != .window }
            return candidates.min { $0.remainingRatio < $1.remainingRatio }
                ?? limited.first
        }
    }
}
