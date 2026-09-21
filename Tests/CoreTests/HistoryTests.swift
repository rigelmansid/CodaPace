import Foundation
import SQLite3
import CodaPaceCore

private let base = Date(timeIntervalSince1970: 1_788_800_000)

/// 造一条采样。只关心某几个字段时,其余留默认值。
private func sample(minutes: Double,
                    total: Double = 0,
                    daily: Double = 0,
                    weeklyOpus: Double = 0,
                    window: Double = 0,
                    tokens: Double = 0,
                    requests: Int = 0) -> Sample {
    Sample(at: base.addingTimeInterval(minutes * 60),
           totalCost: total, dailyCost: daily,
           weeklyOpusCost: weeklyOpus, windowCost: window,
           allTokens: tokens, requests: requests)
}

private func storeURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cub-test-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("History.sqlite")
}

private func tempStore(accountKey: String = "key-a") -> HistoryStore {
    try! HistoryStore(path: storeURL(), accountKey: accountKey)
}

/// 库里落下的采样各自在第几分钟
private func storedMinutes(of store: HistoryStore) -> [Double] {
    try! store.samples(from: base.addingTimeInterval(-86_400),
                       to: base.addingTimeInterval(86_400))
        .map { ($0.at.timeIntervalSince(base) / 60).rounded() }
}

/// 所有天桶累加出来的 token 总量(跨时区归日的边界不影响总和)
private func totalTokens(of store: HistoryStore) -> Double {
    try! store.tokenDays(from: "0000-01-01", to: "9999-12-31")
        .reduce(0) { $0 + $1.tokens }
}

// MARK: - 采样策略

final class SamplingPolicyTests: XCTestCase {

    func testFirstSampleIsAlwaysRecorded() {
        XCTAssertTrue(SamplingPolicy.shouldRecord(previous: nil, current: sample(minutes: 0)))
    }

    func testChangedValuesAreRecorded() {
        let a = sample(minutes: 0, daily: 10)
        let b = sample(minutes: 1, daily: 11)
        XCTAssertTrue(SamplingPolicy.shouldRecord(previous: a, current: b))
    }

    /// 没变化又没到锚点间隔 —— 不写,免得一天攒出上千条重复行
    func testUnchangedWithinAnchorIntervalIsSkipped() {
        let a = sample(minutes: 0, daily: 10)
        let b = sample(minutes: 5, daily: 10)
        XCTAssertFalse(SamplingPolicy.shouldRecord(previous: a, current: b))
    }

    /// 没变化但过了锚点间隔 —— 要写,用来证明「这段时间确实没用」
    func testUnchangedPastAnchorIntervalIsRecorded() {
        let a = sample(minutes: 0, daily: 10)
        let b = sample(minutes: 16, daily: 10)
        XCTAssertTrue(SamplingPolicy.shouldRecord(previous: a, current: b))
    }
}

// MARK: - 两条基线

/// 走一遍记录侧的**真实**流程:每次刷新都交给 `HistoryWriter`,由它判断落盘、
/// 原子写入、推进基线。断言读的是库里的真实内容 —— 刻意不在测试里复制一份编排逻辑,
/// 否则编排改了测试照样通过。
private func replayRefreshes(minutes: [Double],
                            tokensAt: (Double) -> Double,
                            dailyAt: (Double) -> Double = { _ in 0 }) -> (stored: [Double], tokens: Double) {
    let store = tempStore()
    var writer = HistoryWriter()

    for minute in minutes {
        try! writer.write(sample(minutes: minute,
                                 daily: dailyAt(minute),
                                 tokens: tokensAt(minute)),
                          to: store)
    }
    return (storedMinutes(of: store), totalTokens(of: store))
}

final class SamplingLedgerTests: XCTestCase {

    func testFirstSampleIsAlwaysStored() {
        let ledger = SamplingLedger()
        XCTAssertTrue(ledger.shouldStore(sample(minutes: 0)))
        XCTAssertNil(ledger.lastObserved)
        XCTAssertNil(ledger.lastStored)
    }

    /// 从库里取的那条同时充当两条基线的初值
    func testInitFromStoreSeedsBothBaselines() {
        let seed = sample(minutes: 0, daily: 10, tokens: 500)
        let ledger = SamplingLedger(lastStored: seed)
        XCTAssertEqual(ledger.lastObserved, seed)
        XCTAssertEqual(ledger.lastStored, seed)
    }

    /// 没落盘时观测基线前移、落盘基线**不动** —— 这正是原先合成一条时丢掉的区别
    func testUnstoredSampleAdvancesOnlyTheObservedBaseline() {
        var ledger = SamplingLedger(lastStored: sample(minutes: 0, daily: 10))
        let next = sample(minutes: 1, daily: 10)

        ledger.advance(to: next, stored: false)
        XCTAssertEqual(ledger.lastObserved, next)
        XCTAssertEqual(ledger.lastStored?.at, base)
    }

    /// OPT-002 的验收标准:连续一小时每分钟刷新相同数据,
    /// 应在第 0、15、30、45、60 分钟各留一条锚点。
    ///
    /// 原先只有一条基线、每次刷新都推进,比较间隔恒等于 60 秒,
    /// 于是整个小时只留下第 0 分钟那一条。
    func testIdleHourLeavesFiveAnchors() {
        let result = replayRefreshes(minutes: (0...60).map(Double.init),
                                     tokensAt: { _ in 1000 })
        XCTAssertEqual(result.stored, [0, 15, 30, 45, 60])
    }

    /// 空闲期间没有新用量,不该凭空累加出 token
    func testIdleHourAccumulatesNoTokens() {
        let result = replayRefreshes(minutes: (0...60).map(Double.init),
                                     tokensAt: { _ in 1000 })
        XCTAssertEqual(result.tokens, 0)
    }

    /// 数值一变就立刻落盘,不必等锚点
    func testChangedValueIsStoredImmediately() {
        // 第 3 分钟额度变了
        let result = replayRefreshes(minutes: (0...5).map(Double.init),
                                     tokensAt: { _ in 1000 },
                                     dailyAt: { $0 >= 3 ? 20 : 10 })
        XCTAssertEqual(result.stored, [0, 3])
    }

    /// 落盘之后锚点重新计时:第 3 分钟写过一条,下一条锚点在第 18 分钟而不是第 15 分钟
    func testAnchorClockRestartsFromTheLastStoredSample() {
        let result = replayRefreshes(minutes: (0...20).map(Double.init),
                                     tokensAt: { _ in 1000 },
                                     dailyAt: { $0 >= 3 ? 20 : 10 })
        XCTAssertEqual(result.stored, [0, 3, 18])
    }

    /// token 增量必须**每次刷新**都推进基线。观测基线停在旧位置的话,
    /// 跳过的那几次刷新对应的用量会在下一次差值里被重复累加。
    /// 这里 20 分钟里累计值每分钟 +100,总增量应恰好等于首尾之差 2000。
    func testTokenDeltaIsNeitherLostNorDoubleCountedAcrossUnstoredRefreshes() {
        let result = replayRefreshes(minutes: (0...20).map(Double.init),
                                     tokensAt: { 1000 + $0 * 100 })
        XCTAssertEqual(result.tokens, 2000)
    }

    /// 用量持续变化时每次刷新都落盘 —— 和修复前的行为一致,没有回归
    func testContinuouslyChangingValuesAreStoredEveryRefresh() {
        let result = replayRefreshes(minutes: (0...5).map(Double.init),
                                     tokensAt: { 1000 + $0 * 100 })
        XCTAssertEqual(result.stored, [0, 1, 2, 3, 4, 5])
    }
}

// MARK: - token 增量

final class TokenDeltaTests: XCTestCase {

    /// **最要命的那个坑**:重启后没有前值,若把累计值当增量,
    /// 21.5 亿的历史 token 会全部算进今天。必须返回 nil。
    func testNoPreviousMeansBaselineOnly() {
        let current = sample(minutes: 0, tokens: 2_152_951_760, requests: 25_024)
        XCTAssertNil(TokenDelta.between(previous: nil, current: current))
    }

    func testNormalDeltaIsAccumulated() {
        let a = sample(minutes: 0, tokens: 1000, requests: 10)
        let b = sample(minutes: 1, tokens: 1500, requests: 14)

        let delta = TokenDelta.between(previous: a, current: b)
        XCTAssertEqual(delta?.tokens ?? -1, 500, accuracy: 1e-9)
        XCTAssertEqual(delta?.requests, 4)
    }

    /// app 关了几天再打开:**总量照样算得出**,只是归不到具体某天。
    /// 「算不出多少」和「算得出但说不清哪天」后果完全不同 ——
    /// 从前压在同一个 nil 里,那段用量就被静默丢掉了。
    func testWideGapStillYieldsAnAmount() {
        let a = sample(minutes: 0, tokens: 1000)
        let b = sample(minutes: 3 * 24 * 60, tokens: 500_000_000)

        let delta = TokenDelta.between(previous: a, current: b)
        XCTAssertEqual(delta?.tokens ?? -1, 499_999_000, accuracy: 1e-6)

        // 归属层才是判定「记到哪」的地方
        XCTAssertEqual(TokenAttributionPolicy.attribute(from: a.at, to: b.at),
                       .unattributed(from: a.at, to: b.at))
    }

    /// 累计值变小 = 服务端重置或换了 key,不能产生负增量
    func testCounterRegressionProducesNoDelta() {
        let a = sample(minutes: 0, tokens: 5000, requests: 50)
        let b = sample(minutes: 1, tokens: 100, requests: 1)
        XCTAssertNil(TokenDelta.between(previous: a, current: b))
    }

    func testNoChangeProducesNoDelta() {
        let a = sample(minutes: 0, tokens: 1000, requests: 10)
        let b = sample(minutes: 1, tokens: 1000, requests: 10)
        XCTAssertNil(TokenDelta.between(previous: a, current: b))
    }
}

// MARK: - 空档

final class HistoryGapTests: XCTestCase {

    func testContinuousSamplesStayInOneSegment() {
        let samples = [sample(minutes: 0), sample(minutes: 1), sample(minutes: 2)]
        XCTAssertEqual(HistoryGaps.segments(samples).count, 1)
    }

    /// 超过 30 分钟就断开 —— 画图时那段要留白/阴影,不能直接连线
    func testWideGapSplitsSegments() {
        let samples = [sample(minutes: 0), sample(minutes: 1),
                       sample(minutes: 90), sample(minutes: 91)]
        let segments = HistoryGaps.segments(samples)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].count, 2)
        XCTAssertEqual(segments[1].count, 2)
    }

    func testEmptyInputGivesNoSegments() {
        XCTAssertEqual(HistoryGaps.segments([]).count, 0)
    }
}

// MARK: - 重置周期切分

final class QuotaCycleTests: XCTestCase {

    /// 计数器下降 = 跨过重置边界,前后要分成两条曲线,
    /// 否则图上会出现一条从满格直坠到 0 的假线
    func testCounterDropStartsNewCycle() {
        let samples = [sample(minutes: 0, daily: 10),
                       sample(minutes: 1, daily: 20),
                       sample(minutes: 2, daily: 0.5),
                       sample(minutes: 3, daily: 3)]

        let cycles = QuotaCycles.split(samples, kind: .daily)
        XCTAssertEqual(cycles.count, 2)
        XCTAssertEqual(cycles[0].count, 2)
        XCTAssertEqual(cycles[1].count, 2)
    }

    func testMonotonicSamplesStayOneCycle() {
        let samples = [sample(minutes: 0, daily: 1),
                       sample(minutes: 1, daily: 2),
                       sample(minutes: 2, daily: 3)]
        XCTAssertEqual(QuotaCycles.split(samples, kind: .daily).count, 1)
    }

    /// 切分是按额度种类来的:今日归零不代表总额度也归零
    func testSplitIsPerQuotaKind() {
        let samples = [sample(minutes: 0, total: 100, daily: 10),
                       sample(minutes: 1, total: 110, daily: 0)]

        XCTAssertEqual(QuotaCycles.split(samples, kind: .daily).count, 2)
        XCTAssertEqual(QuotaCycles.split(samples, kind: .total).count, 1)
    }
}

// MARK: - 键

final class KeyTests: XCTestCase {

    func testAccountKeyIsStableAndDistinct() {
        let a = AccountKey.derive(apiId: "d7689a91-29e4-4927-9ba3-0a8d590c93a1")
        let again = AccountKey.derive(apiId: "d7689a91-29e4-4927-9ba3-0a8d590c93a1")
        let other = AccountKey.derive(apiId: "different-id")

        XCTAssertEqual(a, again)
        XCTAssertTrue(a != other)
        XCTAssertEqual(a.count, 64)          // SHA-256 十六进制
    }

    /// 数据库里不该出现 apiId 原文
    func testAccountKeyDoesNotContainRawId() {
        let id = "d7689a91-29e4-4927-9ba3-0a8d590c93a1"
        XCTAssertFalse(AccountKey.derive(apiId: id).contains(id))
    }

    func testDayKeyFormat() {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = shanghai
        let date = cal.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 23))!

        XCTAssertEqual(DayKey.string(for: date, timeZone: shanghai), "2026-09-08")
    }

    /// 归日按时区走。UTC 比北京慢 8 小时,所以同一时刻的 UTC 日期只会相同或更早:
    /// 北京 09-08 凌晨 3 点,UTC 还停在 09-07 的 19 点。
    func testDayKeyRespectsTimeZone() {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = shanghai
        let date = cal.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 3))!

        XCTAssertEqual(DayKey.string(for: date, timeZone: shanghai), "2026-09-08")
        XCTAssertEqual(DayKey.string(for: date, timeZone: TimeZone(identifier: "UTC")!),
                       "2026-09-07")
    }
}

// MARK: - 存储

final class HistoryStoreTests: XCTestCase {

    func testInsertAndReadBack() {
        let store = tempStore()
        let s = sample(minutes: 0, total: 2432.69, daily: 27.04,
                       weeklyOpus: 34.47, window: 3.74,
                       tokens: 2_152_951_760, requests: 25_024)
        try! store.insert(s)

        let read = try! store.lastSample()
        XCTAssertEqual(read?.totalCost ?? -1, 2432.69, accuracy: 1e-6)
        XCTAssertEqual(read?.requests, 25_024)
        XCTAssertEqual(read?.allTokens ?? -1, 2_152_951_760, accuracy: 1)
    }

    func testLastSampleIsTheNewest() {
        let store = tempStore()
        try! store.insert(sample(minutes: 0, daily: 1))
        try! store.insert(sample(minutes: 10, daily: 2))
        try! store.insert(sample(minutes: 5, daily: 3))

        XCTAssertEqual(try! store.lastSample()?.dailyCost ?? -1, 2, accuracy: 1e-9)
    }

    func testEmptyStoreHasNoLastSample() {
        XCTAssertNil(try! tempStore().lastSample())
    }

    func testRangeQueryIsOrderedAndBounded() {
        let store = tempStore()
        for i in 0..<5 { try! store.insert(sample(minutes: Double(i), daily: Double(i))) }

        let got = try! store.samples(from: base.addingTimeInterval(60),
                                     to: base.addingTimeInterval(3 * 60))
        XCTAssertEqual(got.count, 3)
        XCTAssertEqual(got.first?.dailyCost ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(got.last?.dailyCost ?? -1, 3, accuracy: 1e-9)
    }

    /// 同一天的增量要累加,不是覆盖
    func testTokenDeltaAccumulatesWithinADay() {
        let store = tempStore()
        try! store.addTokenDelta(day: "2026-09-08", tokens: 100, requests: 2)
        try! store.addTokenDelta(day: "2026-09-08", tokens: 250, requests: 3)

        let days = try! store.tokenDays(from: "2026-09-01", to: "2026-09-30")
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].tokens, 350, accuracy: 1e-9)
        XCTAssertEqual(days[0].requests, 5)
    }

    /// 换 apiId 后历史必须隔离,不能串数据
    func testAccountsArePartitioned() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cub-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("History.sqlite")

        let a = try! HistoryStore(path: url, accountKey: "key-a")
        let b = try! HistoryStore(path: url, accountKey: "key-b")

        try! a.insert(sample(minutes: 0, daily: 42))

        XCTAssertEqual(try! a.sampleCount(), 1)
        XCTAssertEqual(try! b.sampleCount(), 0)
        XCTAssertNil(try! b.lastSample())
    }

    func testPruneRemovesOldSamplesOnly() {
        let store = tempStore()
        try! store.insert(sample(minutes: 0, daily: 1))
        try! store.insert(sample(minutes: 100, daily: 2))

        try! store.pruneSamples(before: base.addingTimeInterval(50 * 60))
        XCTAssertEqual(try! store.sampleCount(), 1)
        XCTAssertEqual(try! store.lastSample()?.dailyCost ?? -1, 2, accuracy: 1e-9)
    }

    // MARK: 事务

    func testTransactionCommitsEverythingTogether() {
        let store = tempStore()

        try! store.transaction {
            try store.insert(sample(minutes: 0, daily: 1, tokens: 100))
            try store.addTokenDelta(day: "2026-09-18", tokens: 100, requests: 2)
        }

        XCTAssertEqual(try! store.sampleCount(), 1)
        XCTAssertEqual(totalTokens(of: store), 100)
    }

    /// 正是 OPT-003 点名的注入点:采样行已插入,日桶那步失败。
    /// 两样都必须一起消失 —— 留下半条就再也修不回来了。
    func testTransactionRollsBackAPartialWrite() {
        let store = tempStore()

        XCTAssertThrowsError(
            try store.transaction {
                try store.insert(sample(minutes: 0, daily: 1, tokens: 100))
                throw StoreError("注入的失败")
            }
        )

        XCTAssertEqual(try! store.sampleCount(), 0)
        XCTAssertNil(try! store.lastSample())
        XCTAssertEqual(totalTokens(of: store), 0)
    }

    /// 回滚之后连接不能卡在事务里,后续写入要照常能用
    func testStoreStaysUsableAfterARollback() {
        let store = tempStore()

        XCTAssertThrowsError(
            try store.transaction { throw StoreError("注入的失败") }
        )

        try! store.transaction {
            try store.insert(sample(minutes: 1, daily: 5))
        }
        XCTAssertEqual(try! store.sampleCount(), 1)
    }

    /// SQLite 没有嵌套事务,误用要给一句看得懂的错误而不是底层报文
    func testNestedTransactionIsRejected() {
        let store = tempStore()

        XCTAssertThrowsError(
            try store.transaction {
                try store.transaction { }
            }
        )
        // 外层回滚后连接依然可用
        try! store.transaction { try store.insert(sample(minutes: 0, daily: 1)) }
        XCTAssertEqual(try! store.sampleCount(), 1)
    }
}

// MARK: - 落盘编排

/// 从**另一个连接**把当天桶的表删掉。
///
/// 这样 `HistoryWriter` 事务里的第一步(采样行)能写进去、第二步(日桶)必然失败 ——
/// 正是 OPT-003 验收标准要求的注入位置,而且是真实的存储故障,不是替身。
private func dropTokenDaysTable(at url: URL) {
    var raw: OpaquePointer?
    sqlite3_open(url.path, &raw)
    sqlite3_exec(raw, "DROP TABLE token_days;", nil, nil, nil)
    sqlite3_close(raw)
}

/// 按给定的用量数值造一份响应。`daily`/`tokens` 传 nil 表示该字段**缺失** ——
/// 用来模拟一份「解得出来但不完整」的响应。
private func statsPayload(total: Double, daily: Double?,
                          opus: Double, window: Double,
                          tokens: Double?, requests: Int) -> UserStats {
    let dailyField = daily.map { "\"currentDailyCost\": \($0)," } ?? ""
    let tokenField = tokens.map { "\"allTokens\": \($0)," } ?? ""
    let payload = """
    {
      "name": "eva", "isActive": true,
      "usage": { "total": { \(tokenField) "requests": \(requests), "cost": 1 } },
      "limits": {
        "currentTotalCost": \(total), \(dailyField)
        "weeklyOpusCost": \(opus), "currentWindowCost": \(window),
        "dailyCostLimit": 70, "totalCostLimit": 3000
      }
    }
    """
    return try! JSONDecoder().decode(UserStats.self, from: Data(payload.utf8))
}

private func snapshot(_ stats: UserStats, minutes: Double) -> Snapshot {
    RelayProvider().buildSnapshot(stats: stats,
                          monthly: nil,
                          schedule: ResetSchedule(timeZone: .current,
                                                  dailyResetHour: 0,
                                                  dailyResetHourIsObserved: false),
                          now: base.addingTimeInterval(minutes * 60))
}

/// OPT-004 验收标准点名的序列:正常 → 无效 → 正常。
final class IncompleteResponseTests: XCTestCase {

    private func complete(minutes: Double, daily: Double, tokens: Double, requests: Int) -> Snapshot {
        snapshot(statsPayload(total: 100, daily: daily, opus: 7, window: 3,
                              tokens: tokens, requests: requests),
                 minutes: minutes)
    }

    /// 中间那份缺了 currentDailyCost 和 allTokens,解得出来但不该入库
    private func incomplete(minutes: Double) -> Snapshot {
        snapshot(statsPayload(total: 100, daily: nil, opus: 7, window: 3,
                              tokens: nil, requests: 0),
                 minutes: minutes)
    }

    func testIncompleteSnapshotIsSkipped() {
        let store = tempStore()
        var writer = HistoryWriter()

        XCTAssertNil(try! writer.record(incomplete(minutes: 0), to: store))
        XCTAssertEqual(try! store.sampleCount(), 0)
    }

    /// 危害一:曲线上不能多出一次并不存在的归零
    func testInvalidResponseLeavesNoZeroSample() {
        let store = tempStore()
        var writer = HistoryWriter()

        try! writer.record(complete(minutes: 0, daily: 42, tokens: 1_000, requests: 10), to: store)
        try! writer.record(incomplete(minutes: 5), to: store)
        try! writer.record(complete(minutes: 10, daily: 45, tokens: 1_200, requests: 12), to: store)

        let stored = try! store.samples(from: base.addingTimeInterval(-3600),
                                        to: base.addingTimeInterval(3600))
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored.map { $0.dailyCost }, [42, 45])
    }

    /// 危害二:恢复正常后不能凭空多出一大笔用量。
    /// 1000 → 1200 只该累加 200;放任无效响应入库的话,
    /// 基线会被打成 0,这里会累出 1200。
    func testInvalidResponseDoesNotCauseATokenSpike() {
        let store = tempStore()
        var writer = HistoryWriter()

        try! writer.record(complete(minutes: 0, daily: 42, tokens: 1_000, requests: 10), to: store)
        try! writer.record(incomplete(minutes: 5), to: store)
        try! writer.record(complete(minutes: 10, daily: 45, tokens: 1_200, requests: 12), to: store)

        XCTAssertEqual(totalTokens(of: store), 200)
    }

    /// 危害三:日额度的假下降不能被当成一次真的重置。
    /// 重置时刻只学一次,学错了就一直错下去,所以这条最要紧。
    func testInvalidResponseNeverReachesResetLearning() {
        let store = tempStore()
        var writer = HistoryWriter()

        try! writer.record(complete(minutes: 0, daily: 42, tokens: 1_000, requests: 10), to: store)

        // 无效那次整条跳过 —— 调用方拿到 nil,也就没有 previous/current 可喂给学习器
        XCTAssertNil(try! writer.record(incomplete(minutes: 5), to: store))

        // 恢复正常这次,拿到的上一条仍是第一份的 42,而不是被污染成 0
        let resumed = try! writer.record(complete(minutes: 10, daily: 45, tokens: 1_200, requests: 12),
                                         to: store)
        XCTAssertEqual(resumed?.previous?.dailyCost, 42)

        // 42 → 45 是上升,学不出重置。若中间那次入了库,42 → 0 会被认成一次重置。
        XCTAssertNil(DailyResetLearner.observe(
            previous: (value: resumed!.previous!.dailyCost, at: resumed!.previous!.at),
            current: (value: resumed!.sample.dailyCost, at: resumed!.sample.at),
            timeZone: .current))

        // 反证:那次假下降确实会被学成重置 —— 所以跳过它是必须的,不是保险起见
        XCTAssertNotNil(DailyResetLearner.observe(
            previous: (value: 42, at: base),
            current: (value: 0, at: base.addingTimeInterval(300)),
            timeZone: .current))
    }
}

final class HistoryWriterTests: XCTestCase {

    /// 首条只该建立基线,不该把累计值当成当天用量
    func testFirstWriteStoresTheSampleWithoutInventingUsage() {
        let store = tempStore()
        var writer = HistoryWriter()

        let outcome = try! writer.write(sample(minutes: 0, daily: 10, tokens: 1_000), to: store)

        XCTAssertTrue(outcome.stored)
        XCTAssertNil(outcome.tokenDelta)
        XCTAssertNil(outcome.previous)
        XCTAssertEqual(try! store.sampleCount(), 1)
        XCTAssertEqual(totalTokens(of: store), 0)
    }

    /// 两步之间注入失败 → 数据库不留部分提交
    func testFailureBetweenTheTwoWritesLeavesNoPartialCommit() {
        let url = storeURL()
        let store = try! HistoryStore(path: url, accountKey: "k")
        var writer = HistoryWriter()

        let first = sample(minutes: 0, daily: 10, tokens: 1_000)
        try! writer.write(first, to: store)

        dropTokenDaysTable(at: url)

        XCTAssertThrowsError(
            try writer.write(sample(minutes: 5, daily: 12, tokens: 1_300), to: store)
        )

        // 第二条采样必须一并回滚。留下的话它会成为重启后的恢复基线,
        // 而它对应的 300 增量从未累加 —— 基线一前移,那段用量就不在任何差值区间里了。
        XCTAssertEqual(try! store.sampleCount(), 1)
        XCTAssertEqual(try! store.lastSample()?.at, first.at)
    }

    /// 失败后重启:增量既不丢失,也不重复累计(OPT-003 验收标准后半句)
    func testDeltaSurvivesAFailedRefreshAcrossRestart() {
        let url = storeURL()
        let store = try! HistoryStore(path: url, accountKey: "k")
        var writer = HistoryWriter()

        try! writer.write(sample(minutes: 0, tokens: 1_000), to: store)

        dropTokenDaysTable(at: url)
        XCTAssertThrowsError(
            try writer.write(sample(minutes: 5, tokens: 1_300), to: store)
        )

        // 重开连接:migrate 会把 token_days 建回来。新的 writer 从库里补基线,
        // 拿到的是回滚后的第一条 —— 于是接下来这次差值覆盖了失败那段。
        let reopened = try! HistoryStore(path: url, accountKey: "k")
        var restarted = HistoryWriter()
        try! restarted.write(sample(minutes: 10, tokens: 1_500), to: reopened)

        // 1000 → 1500 恰好 500:失败那次的 300 含在里面(没丢),且只算了一遍(没重)。
        // 若当初留下了部分提交,基线会是 1300,这里只会累到 200 —— 丢掉 300。
        XCTAssertEqual(totalTokens(of: reopened), 500)
    }

    /// 换账户要丢掉两条基线,不能拿旧账户的累计值给新账户做差
    func testResetDropsBaselinesSoANewAccountStartsClean() {
        let store = tempStore()
        var writer = HistoryWriter()

        try! writer.write(sample(minutes: 0, tokens: 1_000), to: store)
        writer.reset()

        // 换了账户,库也换了(这里用一个新库代表新账户的分区)
        let other = tempStore(accountKey: "key-b")
        let outcome = try! writer.write(sample(minutes: 1, tokens: 9_000_000), to: other)

        XCTAssertNil(outcome.previous)
        XCTAssertNil(outcome.tokenDelta)
        XCTAssertEqual(totalTokens(of: other), 0)
    }
}

// MARK: - 迁移与上限落盘

final class SchemaMigrationTests: XCTestCase {

    /// 上限要原样存得回来
    func testLimitsRoundTrip() {
        let store = tempStore()
        let limits = QuotaLimits(total: 3000, daily: 70, weeklyOpus: 500, window: 20)
        try! store.insert(Sample(at: base, totalCost: 1, dailyCost: 2,
                                 weeklyOpusCost: 3, windowCost: 4,
                                 allTokens: 5, requests: 6, limits: limits))

        XCTAssertEqual(try! store.lastSample()?.limits, limits)
    }

    /// 「当时不限额」(0) 必须能和「不知道」(nil) 分开存、分开读
    func testZeroLimitIsDistinctFromUnknown() {
        let store = tempStore()
        let zero = QuotaLimits(total: 0, daily: 0, weeklyOpus: 0, window: 0)
        try! store.insert(Sample(at: base, totalCost: 0, dailyCost: 0,
                                 weeklyOpusCost: 0, windowCost: 0,
                                 allTokens: 0, requests: 0, limits: zero))
        XCTAssertEqual(try! store.lastSample()?.limits, zero)

        try! store.insert(Sample(at: base.addingTimeInterval(60), totalCost: 0, dailyCost: 0,
                                 weeklyOpusCost: 0, windowCost: 0,
                                 allTokens: 0, requests: 0, limits: nil))
        XCTAssertNil(try! store.lastSample()?.limits)
    }

    /// 升级路径：v1 的库(没有上限列)要能打开，老行读出来是 nil 而**不是 0**。
    /// 回填当前上限等于把今天的配额说成当时的事实，所以刻意留空。
    func testUpgradingFromV1LeavesOldRowsUnknown() {
        let url = storeURL()

        // 先造一个 v1 的库：只有旧的八列，user_version = 0
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var raw: OpaquePointer?
        sqlite3_open(url.path, &raw)
        sqlite3_exec(raw, """
            CREATE TABLE samples (
                account_key TEXT NOT NULL, ts REAL NOT NULL,
                total_cost REAL NOT NULL, daily_cost REAL NOT NULL,
                weekly_opus_cost REAL NOT NULL, window_cost REAL NOT NULL,
                all_tokens REAL NOT NULL, requests INTEGER NOT NULL,
                PRIMARY KEY (account_key, ts));
            INSERT INTO samples VALUES ('key-a', \(base.timeIntervalSince1970),
                                        11, 22, 33, 44, 55, 66);
            """, nil, nil, nil)
        sqlite3_close(raw)

        // 打开它 —— migrate 应补上四列
        let store = try! HistoryStore(path: url, accountKey: "key-a")
        let old = try! store.lastSample()

        XCTAssertEqual(old?.dailyCost ?? -1, 22, accuracy: 1e-9)   // 老数据还在
        XCTAssertNil(old?.limits, "老行的上限未知，不该被回填成 0 或当前上限")

        // 新写入的行照常带上限
        let limits = QuotaLimits(total: 1, daily: 2, weeklyOpus: 3, window: 4)
        try! store.insert(Sample(at: base.addingTimeInterval(60), totalCost: 0, dailyCost: 0,
                                 weeklyOpusCost: 0, windowCost: 0,
                                 allTokens: 0, requests: 0, limits: limits))
        XCTAssertEqual(try! store.lastSample()?.limits, limits)
    }

    /// 迁移要幂等：重复打开同一个库不该出错
    func testReopeningAnAlreadyMigratedStoreIsFine() {
        let url = storeURL()
        let first = try! HistoryStore(path: url, accountKey: "key-a")
        try! first.insert(sample(minutes: 0, daily: 1))

        let second = try! HistoryStore(path: url, accountKey: "key-a")
        XCTAssertEqual(try! second.sampleCount(), 1)
    }
}

// MARK: - 跨日界的增量归属(EXT-005)

private let attrTZ = TimeZone(identifier: "Asia/Shanghai")!

private func attrDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = attrTZ
    return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

final class TokenAttributionTests: XCTestCase {

    func testSameDayIsAttributedToThatDay() {
        let result = TokenAttributionPolicy.attribute(from: attrDate(2026, 6, 15, 10, 0),
                                                      to: attrDate(2026, 6, 15, 10, 10),
                                                      timeZone: attrTZ)
        XCTAssertEqual(result, .day("2026-06-15"))
    }

    /// app 关了很久再打开:那段增量横跨太多天,归给任何一天都是编的
    func testWideGapIsNotAttributedToAnyDay() {
        let from = attrDate(2026, 6, 15, 10)
        let to = attrDate(2026, 6, 18, 10)           // 三天后
        XCTAssertEqual(TokenAttributionPolicy.attribute(from: from, to: to, timeZone: attrTZ),
                       .unattributed(from: from, to: to))
    }

    /// 同一天内但间隔超过阈值,同样归不了 —— 判据是间隔,不只是日界
    func testLongGapWithinOneDayIsAlsoUnattributable() {
        let from = attrDate(2026, 6, 15, 10, 0)
        let to = attrDate(2026, 6, 15, 12, 0)
        XCTAssertEqual(TokenAttributionPolicy.attribute(from: from, to: to, timeZone: attrTZ),
                       .unattributed(from: from, to: to))
    }

    /// **验收标准点名的那条**：跨边界的差值不能被整段塞进后一个桶。
    /// 我们只知道这段时间一共用了多少，不知道多少在午夜之前。
    func testCrossingMidnightIsNotAttributedToEitherDay() {
        let from = attrDate(2026, 6, 15, 23, 58)
        let to = attrDate(2026, 6, 16, 0, 2)
        XCTAssertEqual(TokenAttributionPolicy.attribute(from: from, to: to, timeZone: attrTZ),
                       .unattributed(from: from, to: to))
    }

    /// 归属看的是**当地**日界，换个时区同样两个时刻可能就在同一天了
    func testAttributionFollowsTheGivenTimeZone() {
        let from = attrDate(2026, 6, 15, 23, 58)
        let to = attrDate(2026, 6, 16, 0, 2)
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(TokenAttributionPolicy.attribute(from: from, to: to, timeZone: utc),
                       .day("2026-06-15"))
    }
}

final class UnattributedStorageTests: XCTestCase {

    private func snapshotSample(_ date: Date, tokens: Double) -> Sample {
        Sample(at: date, totalCost: 0, dailyCost: 0, weeklyOpusCost: 0, windowCost: 0,
               allTokens: tokens, requests: 0,
               limits: QuotaLimits(total: 0, daily: 70, weeklyOpus: 0, window: 0))
    }

    /// 同一天内的增量照常进当天的桶
    func testSameDayDeltaGoesIntoTheDayBucket() {
        let store = tempStore()
        var writer = HistoryWriter()

        try! writer.write(snapshotSample(attrDate(2026, 6, 15, 10), tokens: 1000),
                          to: store, timeZone: attrTZ)
        try! writer.write(snapshotSample(attrDate(2026, 6, 15, 10, 10), tokens: 1300),
                          to: store, timeZone: attrTZ)

        XCTAssertEqual(totalTokens(of: store), 300)
        let unattributed = try! store.unattributedTotal(from: attrDate(2026, 6, 1, 0),
                                                        to: attrDate(2026, 7, 1, 0))
        XCTAssertEqual(unattributed.tokens, 0)
    }

    /// 跨午夜那一段既不进 15 号也不进 16 号，而是记成未归属 —— **总量不丢**
    func testMidnightDeltaLandsInUnattributedNotInADay() {
        let store = tempStore()
        var writer = HistoryWriter()

        try! writer.write(snapshotSample(attrDate(2026, 6, 15, 23, 58), tokens: 1000),
                          to: store, timeZone: attrTZ)
        try! writer.write(snapshotSample(attrDate(2026, 6, 16, 0, 2), tokens: 1300),
                          to: store, timeZone: attrTZ)

        XCTAssertEqual(totalTokens(of: store), 0, "不该塞进任何一天")

        let unattributed = try! store.unattributedTotal(from: attrDate(2026, 6, 1, 0),
                                                        to: attrDate(2026, 7, 1, 0))
        XCTAssertEqual(unattributed.tokens, 300, "总量必须留下来")
    }

    /// 跨日之后回到同一天内，照常归属 —— 不会因为跨过一次就永久失准
    func testAttributionResumesAfterMidnight() {
        let store = tempStore()
        var writer = HistoryWriter()

        try! writer.write(snapshotSample(attrDate(2026, 6, 15, 23, 58), tokens: 1000),
                          to: store, timeZone: attrTZ)
        try! writer.write(snapshotSample(attrDate(2026, 6, 16, 0, 2), tokens: 1300),
                          to: store, timeZone: attrTZ)
        try! writer.write(snapshotSample(attrDate(2026, 6, 16, 0, 12), tokens: 1500),
                          to: store, timeZone: attrTZ)

        XCTAssertEqual(totalTokens(of: store), 200, "16 号那段照常入桶")
        let unattributed = try! store.unattributedTotal(from: attrDate(2026, 6, 1, 0),
                                                        to: attrDate(2026, 7, 1, 0))
        XCTAssertEqual(unattributed.tokens, 300)
    }

    /// 未归属与当天用量相加应等于首尾之差 —— 一个 token 都没漏
    func testNothingIsLostAcrossTheBoundary() {
        let store = tempStore()
        var writer = HistoryWriter()

        for (minute, tokens) in [(0.0, 1000.0), (10.0, 1100.0), (20.0, 1250.0), (30.0, 1400.0)] {
            try! writer.write(snapshotSample(attrDate(2026, 6, 15, 23, 45)
                                                .addingTimeInterval(minute * 60),
                                             tokens: tokens),
                              to: store, timeZone: attrTZ)
        }

        let unattributed = try! store.unattributedTotal(from: attrDate(2026, 6, 1, 0),
                                                        to: attrDate(2026, 7, 1, 0))
        XCTAssertEqual(totalTokens(of: store) + unattributed.tokens, 400,
                       "1000 → 1400，总量必须完整保留")
    }
}
