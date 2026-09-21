//
//  HistoryModels.swift — 历史采样的数据结构与纯策略
//
//  这里只放不碰数据库、不碰 UI 的逻辑,全部可单测。
//  真正的读写在 HistoryStore.swift。
//

import Foundation
import CryptoKit

// MARK: - 采样

/// 采样**当时**各额度的上限。0 表示当时不限。
///
/// 必须连同用量一起存下来:上限会变(改套餐、中转站调配额),
/// 而历史里记的是「当时花了多少、当时的上限是多少」这个事实。
/// 事后拿**现在**的上限去除历史金额,等于把过去的处境按今天重写一遍 ——
/// 50/100(剩 50%)在上限调到 200 之后会显示成剩 75%,那一刻的紧张程度凭空消失了。
public struct QuotaLimits: Equatable {
    public let total: Double
    public let daily: Double
    public let weeklyOpus: Double
    public let window: Double

    public init(total: Double, daily: Double, weeklyOpus: Double, window: Double) {
        self.total = total
        self.daily = daily
        self.weeklyOpus = weeklyOpus
        self.window = window
    }

    public func value(for kind: QuotaKind) -> Double {
        switch kind {
        case .total:      return total
        case .daily:      return daily
        case .weeklyOpus: return weeklyOpus
        case .window:     return window
        }
    }
}

/// 一次成功刷新留下的快照。金额字段来自接口的当前值,tokens/requests 是**累计值**。
public struct Sample: Equatable {
    public let at: Date
    public let totalCost: Double
    public let dailyCost: Double
    public let weeklyOpusCost: Double
    public let windowCost: Double
    public let allTokens: Double
    public let requests: Int

    /// 采样当时的各额度上限。
    ///
    /// **nil 表示这条老记录根本没记过上限** —— 不是「上限为 0」。
    /// 这两件事必须分开:前者是我们不知道,后者是当时不限额。
    /// 不知道就画不出百分比,那就不画,而不是拿当前上限顶上。
    public let limits: QuotaLimits?

    public init(at: Date, totalCost: Double, dailyCost: Double,
                weeklyOpusCost: Double, windowCost: Double,
                allTokens: Double, requests: Int,
                limits: QuotaLimits? = nil) {
        self.at = at
        self.totalCost = totalCost
        self.dailyCost = dailyCost
        self.weeklyOpusCost = weeklyOpusCost
        self.windowCost = windowCost
        self.allTokens = allTokens
        self.requests = requests
        self.limits = limits
    }

    /// 除时间戳外**用量**是否有变化。
    /// 刻意不比上限:上限变了不代表有新消费,不该因此额外落一条采样。
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

    /// - Parameter previous: **库里最后那条**,不是上一次刷新。两者的区别见 `SamplingLedger`。
    public static func shouldRecord(previous: Sample?,
                                    current: Sample,
                                    anchorInterval: TimeInterval = anchorInterval) -> Bool {
        guard let previous else { return true }
        if current.differs(from: previous) { return true }
        return current.at.timeIntervalSince(previous.at) >= anchorInterval
    }
}

// MARK: - 两条基线

/// 记录侧要同时维护**两条**基线。合成一条会让保底锚点失效:
///
/// 原先只有一条,每次刷新结束都推进,于是「离上一条记录多久了」量到的恒等于刷新间隔
/// (默认 60 秒),永远够不到 15 分钟。空闲一小时本该留下 5 条锚点,实际只留 1 条 ——
/// 而空档阈值是 30 分钟,于是图上一段**正常空闲**被当成 app 没运行,画成了阴影断档。
/// 锚点存在的意义恰恰是区分这两件事,基线搞错就等于没有锚点。
///
/// 两条基线各有用途,不能互换:
///
/// · **落盘基线 `lastStored`** —— 只在采样真的写进库之后才推进。
///   「值变了吗」「满 15 分钟了吗」问的都是*库里那条*,和中间跳过的刷新无关。
///
/// · **观测基线 `lastObserved`** —— 每次刷新都推进。token 增量靠相邻累计值做差,
///   基线必须在每次消费掉一段增量后立刻前移;停在旧位置的话,跳过的那段会在
///   下一次差值里被重复累加一遍。日重置学习同理 —— 相邻观测越密,推算的重置小时越准。
public struct SamplingLedger {

    /// 上一次刷新观测到的采样,不论它是否落盘
    public private(set) var lastObserved: Sample?

    /// 上一条真正写进库的采样
    public private(set) var lastStored: Sample?

    /// - Parameter lastStored: 启动(或换账户)时从库里取的最后一条。
    ///   它同时充当观测基线的初值 —— 重启后库里那条是唯一能拿到的历史观测。
    public init(lastStored: Sample? = nil) {
        self.lastStored = lastStored
        self.lastObserved = lastStored
    }

    /// 这条采样该不该落盘。判据是落盘基线。
    public func shouldStore(_ sample: Sample,
                            anchorInterval: TimeInterval = SamplingPolicy.anchorInterval) -> Bool {
        SamplingPolicy.shouldRecord(previous: lastStored,
                                    current: sample,
                                    anchorInterval: anchorInterval)
    }

    /// 登记一条处理完的采样。
    /// - Parameter stored: 它是否真的写进了库。只有写进去了才推进落盘基线。
    public mutating func advance(to sample: Sample, stored: Bool) {
        lastObserved = sample
        if stored { lastStored = sample }
    }
}

// MARK: - token 增量

/// 接口给的是**累计** token 数,按天用量得靠相邻采样做差。
public enum TokenDelta {

    public struct Delta: Equatable {
        public let tokens: Double
        public let requests: Int
    }

    /// 相邻两次累计值之差 —— **只回答「用了多少」,不回答「算在哪天」**。
    ///
    /// 归属是 `TokenAttributionPolicy` 的事。两件事分开,是因为「算不出多少」和
    /// 「算得出但说不清哪天」后果完全不同:前者只能重建基线,后者的总量必须留下来。
    /// 从前它们压在同一个 nil 里,于是断档期间的用量被静默丢弃,总量对不上。
    ///
    /// 返回 nil 表示**连总量都算不出**,只能重建基线。两种情况:
    /// 1. 没有前值(首次安装)—— 直接把累计值当增量会把上亿的历史全算进今天
    /// 2. 累计值变小(服务端重置或换了 key)—— 不能产生负增量
    public static func between(previous: Sample?, current: Sample) -> Delta? {
        guard let previous else { return nil }
        guard current.at > previous.at else { return nil }

        let tokens = current.allTokens - previous.allTokens
        let requests = current.requests - previous.requests
        guard tokens >= 0, requests >= 0 else { return nil }
        guard tokens > 0 || requests > 0 else { return nil }

        return Delta(tokens: tokens, requests: requests)
    }
}

// MARK: - 增量归属

/// 一段 token 增量该记到哪儿。
public enum TokenAttribution: Equatable {

    /// 两次采样落在同一天 —— 这段增量明确属于那一天
    case day(String)

    /// 跨了日界。**不塞进任何一个桶。**
    ///
    /// 接口只给累计值,我们知道「这段时间里一共用了多少」,但不知道其中多少发生在
    /// 午夜之前、多少在之后。按时间比例劈开是编的:用量不是均匀流淌的,
    /// 很可能全部集中在某一侧。整段塞进后一天同样是编的,只是错得更隐蔽。
    ///
    /// 所以如实记成「这段时间有这么多用量,但归不到具体某天」,
    /// 总量不丢,也不假装知道它属于哪天。
    case unattributed(from: Date, to: Date)
}

public enum TokenAttributionPolicy {

    /// 间隔超过这个长度就归不到具体某天 —— app 关了很久,这段用量横跨太多时间
    public static let maxAttributableGap: TimeInterval = 30 * 60

    /// 这段增量该记到哪儿。两条都不满足才算能归属:
    ///
    /// · **两次采样落在同一天** —— 跨了日界就说不清哪部分属于哪天;
    /// · **间隔不超过 `maxAttributableGap`** —— app 关了三天再打开,
    ///   那段增量横跨太多天,归给任何一天都是编的。
    ///
    /// 两种情况都归到 `unattributed` 而**不是丢掉**:我们确实知道这段时间里用了多少,
    /// 只是不知道分布。丢掉会让总量凭空变少,那是另一种不诚实。
    public static func attribute(from previous: Date, to current: Date,
                                 timeZone: TimeZone = .current,
                                 maxGap: TimeInterval = maxAttributableGap) -> TokenAttribution {
        guard current.timeIntervalSince(previous) <= maxGap else {
            return .unattributed(from: previous, to: current)
        }

        let before = DayKey.string(for: previous, timeZone: timeZone)
        let after = DayKey.string(for: current, timeZone: timeZone)

        guard before == after else { return .unattributed(from: previous, to: current) }
        return .day(after)
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
        derive([apiId])
    }

    /// 多段输入的派生键。
    ///
    /// 用 `\n` 连接 —— 它不会出现在网址或 apiId 里,所以不存在
    /// 「`a` + `bc` 和 `ab` + `c` 撞成同一个键」这种拼接歧义。
    ///
    /// 单段时结果与 `derive(apiId:)` **完全一致**:历史分区键必须保持稳定,
    /// 一变就等于把所有老用户的历史全丢掉。
    public static func derive(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
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
