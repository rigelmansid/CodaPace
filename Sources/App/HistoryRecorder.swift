//
//  HistoryRecorder.swift — 把每次刷新的结果落进历史库
//
//  策略本身都在 Core 里(SamplingPolicy / TokenDelta / DailyResetLearner),
//  这里只负责串起来:建库、取基线、写入、学习重置时刻。
//

import Foundation

@MainActor
final class HistoryRecorder {

    static let shared = HistoryRecorder()

    private var store: HistoryStore?
    private var accountKey: String?

    /// 内存里的上一条采样。启动时从数据库补齐 ——
    /// 没有它,token 增量就没有基线可减。
    private var previous: Sample?

    /// 最近一次存储错误。历史记录坏掉不该影响主功能,只在面板上提一句。
    private(set) var lastError: String?

    // MARK: 记录

    func record(_ snapshot: Snapshot) {
        guard Config.isConfigured else { return }

        do {
            let store = try ensureStore()

            let sample = Sample(
                at: snapshot.fetchedAt,
                totalCost: snapshot.gauge(.total)?.used ?? 0,
                dailyCost: snapshot.gauge(.daily)?.used ?? 0,
                weeklyOpusCost: snapshot.gauge(.weeklyOpus)?.used ?? 0,
                windowCost: snapshot.gauge(.window)?.used ?? 0,
                allTokens: snapshot.totalTokens,
                requests: snapshot.totalRequests
            )

            // 基线优先用内存里的,重启后从库里补
            if previous == nil { previous = try store.lastSample() }

            if SamplingPolicy.shouldRecord(previous: previous, current: sample) {
                try store.insert(sample)
            }

            // token 按天累加。返回 nil 说明这次只该重建基线(首次 / 断档过久 / 累计值回退)
            if let delta = TokenDelta.between(previous: previous, current: sample) {
                try store.addTokenDelta(day: DayKey.string(for: sample.at),
                                        tokens: delta.tokens,
                                        requests: delta.requests)
            }

            learnDailyReset(previous: previous, current: sample)

            previous = sample
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: 学习日重置时刻

    /// 接口不提供日额度的重置时刻,只能从「计数器归零」这个事件里观测。
    /// 学到之后写进配置,「今日」那条的「(推算)」标注就会消失。
    private func learnDailyReset(previous: Sample?, current: Sample) {
        guard let previous, Config.observedDailyResetHour == nil else { return }

        let observation = DailyResetLearner.observe(
            previous: (value: previous.dailyCost, at: previous.at),
            current: (value: current.dailyCost, at: current.at),
            timeZone: .current
        )
        if let observation {
            Config.observedDailyResetHour = observation.hour
        }
    }

    // MARK: 建库

    /// apiId 变了就换一个库连接 —— 不同账号的历史必须分开
    private func ensureStore() throws -> HistoryStore {
        let key = AccountKey.derive(apiId: Config.apiId)

        if let store, accountKey == key { return store }

        let opened = try HistoryStore(accountKey: key)
        store = opened
        accountKey = key
        previous = nil          // 换账号了,基线要重建
        return opened
    }

    // MARK: 供图表读取(第 6 步用)

    func samples(from: Date, to: Date) -> [Sample] {
        (try? ensureStore().samples(from: from, to: to)) ?? []
    }

    func tokenDays(from: Date, to: Date) -> [TokenDay] {
        guard let store = try? ensureStore() else { return [] }
        return (try? store.tokenDays(from: DayKey.string(for: from),
                                     to: DayKey.string(for: to))) ?? []
    }

    func sampleCount() -> Int {
        (try? ensureStore().sampleCount()) ?? 0
    }
}
