import Foundation
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

private func tempStore(accountKey: String = "key-a") -> HistoryStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cub-test-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("History.sqlite")
    return try! HistoryStore(path: url, accountKey: accountKey)
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

    /// app 关了几天再打开:这段增量横跨多天,归给哪天都是编的 —— 只重建基线
    func testWideGapIsNotAttributedToToday() {
        let a = sample(minutes: 0, tokens: 1000)
        let b = sample(minutes: 3 * 24 * 60, tokens: 500_000_000)
        XCTAssertNil(TokenDelta.between(previous: a, current: b))
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
}
