//
//  Snapshot.swift — 一次成功抓取的完整结果
//

import Foundation

// MARK: - 菜单栏显示哪条额度

public enum MenuBarSource: Equatable, Hashable {
    /// 自动:显示最紧张的那条
    case auto
    /// 固定显示某一条。
    ///
    /// 绑的是**额度桶 ID**而不是从前那个固定枚举(EXT-001)——
    /// 供应商各有各的额度,枚举装不下。存量偏好存的就是这个字符串,
    /// 而中转站的桶 ID 取值等于旧枚举的 rawValue,所以老用户的选择原样有效,
    /// 不需要迁移。
    case fixed(bucketID: String)
}

// MARK: - 快照

public struct Snapshot: Equatable {
    public let name: String
    public let isActive: Bool

    /// 这个账户的各条额度,**顺序即显示顺序**,由适配器决定 ——
    /// 哪条该排在前面是那家供应商的事,通用层不该有自己的偏好。
    public let gauges: [QuotaBucket]

    public let totalCost: Double
    public let totalRequests: Int
    public let totalTokens: Double

    public let monthlyCost: Double?
    public let monthlyRequests: Int?

    public let fetchedAt: Date

    /// 这份快照的用量数值是不是都真的观测到了。false 表示响应里有必要字段缺失或为 null,
    /// 相应的数字是退回来的 0 —— 可以显示,但**不能进历史**。理由见 `UserStats.hasCompleteUsage`。
    public let hasCompleteUsage: Bool

    public init(name: String, isActive: Bool, gauges: [QuotaBucket],
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

    public func bucket(id: String) -> QuotaBucket? {
        gauges.first { $0.id == id }
    }

    /// 有上限的额度(不限的没法画进度)
    public var limited: [QuotaBucket] { gauges.filter { !$0.unlimited } }

    /// 菜单栏该显示哪条。
    ///
    /// `.auto` 的规则:取剩余最少的一条,但**排除高频窗口** ——
    /// 那种一小时一轮的额度,比例反复大起大落,会让菜单栏的数字和颜色不停跳。
    /// 唯一的例外是它自己已经吃紧(剩余 < 20%),这时马上就要被限流了,值得顶上来。
    ///
    /// 「哪条算高频」由周期长度判定(`hasVolatileWindow`),不点名某条额度 ——
    /// 从前这里写死了 `.window`,那是中转站的额度名漏进了通用层。
    public func menuBarGauge(source: MenuBarSource) -> QuotaBucket? {
        switch source {
        case .fixed(let bucketID):
            if let picked = bucket(id: bucketID), !picked.unlimited { return picked }
            return menuBarGauge(source: .auto)

        case .auto:
            if let volatile = limited.first(where: { $0.hasVolatileWindow }),
               volatile.remainingRatio < QuotaThresholds.critical {
                return volatile
            }
            let candidates = limited.filter { !$0.hasVolatileWindow }
            return candidates.min { $0.remainingRatio < $1.remainingRatio }
                ?? limited.first
        }
    }
}
