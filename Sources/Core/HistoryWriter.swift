//
//  HistoryWriter.swift — 一次刷新的落盘编排
//
//  和 HistoryModels.swift 的分工:那边是不碰数据库的纯策略(该不该落盘、增量是多少),
//  这边负责按正确的顺序把它们串起来并真的写进库。
//
//  顺序本身就是正确性的一部分,三条都不能挪:
//
//  1. 先算判断(用哪条基线),再写库 —— 判据不能受本次写入影响;
//  2. 采样行和当天的 token 增量在**同一个事务**里 —— 只写进一半会留下无法修复的状态;
//  3. 事务提交成功之后才推进内存基线 —— 提前推进等于承认了一次没发生的写入。
//

import Foundation

/// 把一次刷新该落盘的东西写进库,并维护两条基线。
///
/// 持有基线所以是 struct + mutating:调用方(App 层的 HistoryRecorder)只需要留着它,
/// 不必自己关心「什么时候该从库里补基线」「什么时候该前移哪一条」。
public struct HistoryWriter {

    /// 两条基线(观测 / 落盘)。nil 表示还没从库里补过 —— 启动后第一次写入时补。
    private var ledger: SamplingLedger?

    public init() {}

    /// 一次写入的结果,供调用方决定后续动作(目前是日重置学习)。
    public struct Outcome: Equatable {
        /// 本次写入的采样
        public let sample: Sample
        /// 采样行是否落盘(变化或满锚点间隔)
        public let stored: Bool
        /// 本次累加进当天桶的增量;nil 表示只重建基线,没有可归属的增量
        public let tokenDelta: TokenDelta.Delta?
        /// 与本次相邻的**上一次观测**。日重置学习要拿它和本次做对比,
        /// 所以必须是推进之前的值。
        public let previous: Sample?
    }

    /// 从一份快照落一条历史。
    ///
    /// - Returns: 用量不完整的快照直接跳过,返回 nil —— 调用方据此知道这次什么都没发生,
    ///   也就不该拿它去喂日重置学习。理由见 `Snapshot.hasCompleteUsage`。
    @discardableResult
    public mutating func record(_ snapshot: Snapshot,
                                to store: HistoryStore,
                                timeZone: TimeZone = .current) throws -> Outcome? {
        guard snapshot.hasCompleteUsage else { return nil }
        return try write(Sample(snapshot), to: store, timeZone: timeZone)
    }

    /// - Throws: 任何一步写库失败都会整体回滚并抛出,且**基线不前移** ——
    ///   于是这次的增量会在下一次刷新的差值里被重新算进去,不会丢。
    @discardableResult
    public mutating func write(_ sample: Sample,
                               to store: HistoryStore,
                               timeZone: TimeZone = .current) throws -> Outcome {

        // 基线优先用内存里的,重启(或换账户)后从库里补
        var ledger = try self.ledger ?? SamplingLedger(lastStored: store.lastSample())

        // 两个判断都在写库之前算完,用的是本次写入之前的基线
        let stored = ledger.shouldStore(sample)
        let delta = TokenDelta.between(previous: ledger.lastObserved, current: sample)
        let previous = ledger.lastObserved

        // 一个事务 —— 理由见 HistoryStore.transaction 的注释。
        // 两样都没有就别开事务:空闲时每分钟都来一次,没必要为此去拿写锁。
        if stored || delta != nil {
            try store.transaction {
                if stored {
                    try store.insert(sample)
                }
                // 跨日界的那一段归不到具体某天 —— 整段塞进后一天是编的,
                // 按时间比例劈开也是编的。如实记成未归属,总量不丢。
                if let delta, let previous {
                    switch TokenAttributionPolicy.attribute(from: previous.at, to: sample.at,
                                                            timeZone: timeZone) {
                    case .day(let key):
                        try store.addTokenDelta(day: key,
                                                tokens: delta.tokens,
                                                requests: delta.requests)
                    case .unattributed(let from, let to):
                        try store.addUnattributed(from: from, to: to,
                                                  tokens: delta.tokens,
                                                  requests: delta.requests)
                    }
                }
            }
        }

        // 到这里才算数:上面抛错的话 self.ledger 一个字没动
        ledger.advance(to: sample, stored: stored)
        self.ledger = ledger

        return Outcome(sample: sample, stored: stored, tokenDelta: delta, previous: previous)
    }

    /// 换账户:丢掉两条基线,下一次写入会按新账户的库重建。
    /// 两个账户的累计值毫无关系,拿旧账户的基线做差没有意义。
    public mutating func reset() {
        ledger = nil
    }
}

// MARK: - 快照 → 采样

public extension Sample {
    /// 从一份快照取出要落历史的数值:四条用量、两个累计值,**以及当时的四个上限**。
    ///
    /// 上限必须一起存。它会变(改套餐、中转站调配额),而历史记的是
    /// 「当时花了多少、当时的上限是多少」这个事实 —— 画百分比时用采样自己那条,
    /// 不是用当前上限,否则等于把过去按今天重写一遍。
    init(_ snapshot: Snapshot) {
        // ⚠︎ EXT-001 阶段 1 的**临时桥接**,阶段 2 连同 QuotaKind 一起删。
        //
        // 展示侧已经换成了任意多个额度桶,而历史存储这一层还是四个固定列,
        // 所以这里要按固定的四个 ID 回头去取。桥接能成立,全靠中转站的桶 ID
        // 取值等于旧枚举的 rawValue —— 也正因如此,它只对中转站有效:
        // 别家供应商(tu-zi 报的是日/周/月)从这里出去会四条全空。
        //
        // 所以阶段 2 之前**不要接第二个适配器**,顺序不能调换。
        func bucket(_ kind: QuotaKind) -> QuotaBucket? {
            snapshot.bucket(id: kind.rawValue)
        }

        self.init(
            at: snapshot.fetchedAt,
            totalCost: bucket(.total)?.used ?? 0,
            dailyCost: bucket(.daily)?.used ?? 0,
            weeklyOpusCost: bucket(.weeklyOpus)?.used ?? 0,
            windowCost: bucket(.window)?.used ?? 0,
            allTokens: snapshot.totalTokens,
            requests: snapshot.totalRequests,
            limits: QuotaLimits(total: bucket(.total)?.limit ?? 0,
                                daily: bucket(.daily)?.limit ?? 0,
                                weeklyOpus: bucket(.weeklyOpus)?.limit ?? 0,
                                window: bucket(.window)?.limit ?? 0)
        )
    }
}
