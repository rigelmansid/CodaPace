//
//  HistoryRecorder.swift — 把每次刷新的结果落进历史库
//
//  策略和落盘编排都在 Core 里(SamplingPolicy / TokenDelta / HistoryWriter /
//  DailyResetLearner),这里只剩下 App 层才有的那几件事:
//  按账户建库、把 Snapshot 拍成 Sample、把学到的重置时刻写进偏好、兜住错误。
//

import Foundation

@MainActor
final class HistoryRecorder {

    static let shared = HistoryRecorder()

    private var store: HistoryStore?
    private var accountKey: String?

    /// 落盘编排 + 两条基线。判断顺序、事务边界、基线推进时机都在它里面 ——
    /// 见 Core 的 `HistoryWriter`。
    private var writer = HistoryWriter()

    /// 采样只留 90 天,一天最多清一次(OPT-029)
    private var retention = HistoryRetention()

    /// 最近一次存储错误。历史记录坏掉不该影响主功能,只在面板上提一句。
    private(set) var lastError: String?

    // MARK: 记录

    /// - Parameter account: 这份快照**属于哪个账户**。由调用方在刷新开头定住后传进来,
    ///   不能在这里读 Config —— 快照抓取期间用户可能已经换了账户,那样就会把
    ///   上一个账户的用量写进新账户的分区。
    func record(_ snapshot: Snapshot, account: AccountIdentity) {
        guard account.isConfigured else { return }

        do {
            let store = try ensureStore(for: account)

            // 采样行和当天的 token 增量一起原子落盘,成功了才推进基线。
            // 抛错就整体回滚,这次的增量会在下一次刷新的差值里重新算进去。
            //
            // 返回 nil = 这份快照用量不完整,整条跳过了。那些 0 是「没观测到」退回来的,
            // 不是真花了 0 块钱 —— 不记也就不推进基线,下一次完整响应的差值会自然
            // 跨过这段空缺。于是三条危害一起断掉:假归零、恢复时的用量突增、
            // 以及把假下降误学成一次日重置。
            guard let outcome = try writer.record(snapshot, to: store) else { return }

            // 放在写入成功之后:写失败时这次观测等于没发生过,
            // 不该拿它去改写「日重置在几点」这个学出来的结论。
            learnDailyReset(previous: outcome.previous, current: outcome.sample, account: account)

            // 清理放在写入之后:库里最新的那条就是刚写的,碰不到基线
            try retention.pruneIfDue(store, now: outcome.sample.at)

            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: 学习日重置时刻

    /// 接口不提供日额度的重置时刻,只能从「计数器归零」这个事件里观测。
    /// 学到之后写进配置,「今日」那条的「(推算)」标注就会消失。
    private func learnDailyReset(previous: Sample?, current: Sample, account: AccountIdentity) {
        guard let previous else { return }

        // 学哪条额度**由适配器说了算**,通用层不认识任何一条具体额度的名字。
        //
        // 服务端自己就给重置时刻的供应商(tu-zi)返回 nil,整条跳过 ——
        // 对着一个已知的事实去「观测学习」,学出来的只会比对方给的更差。
        guard let bucketID = ProviderRegistry.adapter(for: account).learnableDailyBucketID,
              let previousDaily = previous.used(bucketID),
              let currentDaily = current.used(bucketID) else { return }

        // 时区是结论的一部分,所以观测和存储必须用同一个
        let timeZone = TimeZone.current

        guard let observation = DailyResetLearner.observe(
            previous: (value: previousDaily, at: previous.at),
            current: (value: currentDaily, at: current.at),
            timeZone: timeZone
        ) else { return }

        // 不再「学到一次就封存」:中转站改了重置时刻、用户换了时区,都该跟着更新。
        // 该不该更新由 Core 的 reconcile 判断,返回 nil 就是不用动。
        if let updated = DailyResetLearner.reconcile(
            stored: Config.learnedDailyReset(for: account),
            observation: observation,
            timeZone: timeZone
        ) {
            Config.setLearnedDailyReset(updated, for: account)
        }
    }

    // MARK: 账户切换

    /// 换账户后调用:丢掉库连接和 token 基线。
    ///
    /// `ensureStore(for:)` 本来就会在分区键变化时自己换库,这里额外做一次是为了
    /// **立刻**丢掉旧账户的基线。留着它的话,新账户第一条采样会拿旧账户的
    /// 累计 token 当基线做差 —— 两个账户的累计值毫无关系,差出来的数没有意义。
    func accountDidChange() {
        store = nil
        accountKey = nil
        writer.reset()
        retention.reset()
        lastError = nil
    }

    // MARK: 建库

    /// apiId 变了就换一个库连接 —— 不同账号的历史必须分开
    private func ensureStore(for account: AccountIdentity) throws -> HistoryStore {
        let key = account.storageKey

        if let store, accountKey == key { return store }

        // 老分区的认领在这里发生 —— 只有这一层同时知道新旧两个键
        let opened = try HistoryStore(accountKey: key,
                                      legacyAccountKey: account.legacyStorageKey)
        store = opened
        accountKey = key
        writer.reset()          // 换账号了,两条基线都要重建
        retention.reset()
        return opened
    }

    // MARK: 供图表读取

    // 读取路径用「当前」账户是对的:图表画的本来就是用户此刻选中的那个账户。
    // 和 record 的区别在于写入必须绑定快照抓取时的身份,读取只需要此刻的。

    func samples(from: Date, to: Date) -> [Sample] {
        (try? ensureStore(for: Config.account).samples(from: from, to: to)) ?? []
    }

    func tokenDays(from: Date, to: Date) -> [TokenDay] {
        guard let store = try? ensureStore(for: Config.account) else { return [] }
        return (try? store.tokenDays(from: DayKey.string(for: from),
                                     to: DayKey.string(for: to))) ?? []
    }

    func sampleCount() -> Int {
        (try? ensureStore(for: Config.account).sampleCount()) ?? 0
    }

    /// 历史里出现过哪些额度桶。离线时快照是 nil,额度选择器靠它才不至于整个空掉。
    func knownBucketIDs() -> [String] {
        (try? ensureStore(for: Config.account).knownBucketIDs()) ?? []
    }
}
