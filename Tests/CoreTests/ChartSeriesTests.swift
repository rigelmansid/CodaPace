import Foundation
import CodaPaceCore

private let chartBase = Date(timeIntervalSince1970: 1_788_800_000)

/// - Parameter limit: 采样**当时**的上限。传 nil 表示这条是升级前的老记录,没记过上限。
private func chartSample(minutes: Double, daily: Double = 0, total: Double = 0,
                         limit: Double? = 70) -> Sample {
    Sample(at: chartBase.addingTimeInterval(minutes * 60),
           totalCost: total, dailyCost: daily,
           weeklyOpusCost: 0, windowCost: 0,
           allTokens: 0, requests: 0,
           limits: limit.map { QuotaLimits(total: $0, daily: $0, weeklyOpus: $0, window: $0) })
}


/// 造一条周期起点正好落在 `boundary` 的规则。
/// 用固定时长(绝对秒数)最直白 —— 这里测的是连接段,不是日历语义。
private func ruleWithBoundary(at boundary: Date, every seconds: TimeInterval = 3600) -> ResetRule {
    ResetRule(.fixedDuration(anchor: boundary, seconds: seconds), provenance: .server)
}

// MARK: - 额度曲线

final class QuotaSeriesTests: XCTestCase {

    func testRemainingRatioIsDerivedFromLimit() {
        let points = QuotaSeriesBuilder.build(
            samples: [chartSample(minutes: 0, daily: 17.5)],
            kind: .daily
        )
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].remainingRatio, 0.75, accuracy: 1e-9)
    }

    /// 不限额度没有「剩余百分比」可言,不该画出任何点
    func testUnlimitedQuotaProducesNoPoints() {
        let points = QuotaSeriesBuilder.build(
            samples: [chartSample(minutes: 0, daily: 17.5, limit: 0)],
            kind: .daily
        )
        XCTAssertEqual(points.count, 0)
    }

    func testContinuousSamplesShareOneSeries() {
        let points = QuotaSeriesBuilder.build(
            samples: [chartSample(minutes: 0, daily: 1),
                      chartSample(minutes: 1, daily: 2),
                      chartSample(minutes: 2, daily: 3)],
            kind: .daily
        )
        XCTAssertEqual(points.map(\.series), [0, 0, 0])
    }

    /// 空档要断开 —— 连起来等于捏造中间那段的走势
    func testGapStartsNewSeries() {
        let points = QuotaSeriesBuilder.build(
            samples: [chartSample(minutes: 0, daily: 1),
                      chartSample(minutes: 1, daily: 2),
                      chartSample(minutes: 120, daily: 5)],
            kind: .daily
        )
        XCTAssertEqual(points.map(\.series), [0, 0, 1])
    }

    /// 重置也要断开,否则图上会出现一条从满格直坠到 0 的假线
    func testResetStartsNewSeries() {
        let points = QuotaSeriesBuilder.build(
            samples: [chartSample(minutes: 0, daily: 60),
                      chartSample(minutes: 1, daily: 65),
                      chartSample(minutes: 2, daily: 0.5)],
            kind: .daily
        )
        XCTAssertEqual(points.map(\.series), [0, 0, 1])
        // 新周期的起点应该接近满格
        XCTAssertEqual(points[2].remainingRatio, 1 - 0.5 / 70, accuracy: 1e-9)
    }

    /// 超额使用时剩余比例不该变成负数
    func testOverspendClampsToZero() {
        let points = QuotaSeriesBuilder.build(
            samples: [chartSample(minutes: 0, daily: 90)],
            kind: .daily
        )
        XCTAssertEqual(points[0].remainingRatio, 0, accuracy: 1e-9)
    }

    func testEmptyInputProducesNoPoints() {
        XCTAssertEqual(QuotaSeriesBuilder.build(samples: [], kind: .daily).count, 0)
    }

    // MARK: 空档区间

    func testGapIntervalsAreReported() {
        let gaps = QuotaSeriesBuilder.gaps(samples: [
            chartSample(minutes: 0),
            chartSample(minutes: 1),
            chartSample(minutes: 120),
            chartSample(minutes: 121),
        ])
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].from, chartBase.addingTimeInterval(60))
        XCTAssertEqual(gaps[0].to, chartBase.addingTimeInterval(120 * 60))
    }

    func testNoGapsWhenContinuous() {
        let gaps = QuotaSeriesBuilder.gaps(samples: [
            chartSample(minutes: 0), chartSample(minutes: 1),
        ])
        XCTAssertEqual(gaps.count, 0)
    }

    // MARK: 虚线连接段

    /// 空档两端要用虚线连起来,连接的是前一段末点和后一段首点
    func testGapProducesConnector() {
        let samples = [chartSample(minutes: 0, daily: 1),
                       chartSample(minutes: 1, daily: 2),
                       chartSample(minutes: 120, daily: 5)]

        let connectors = QuotaSeriesBuilder.connectors(samples: samples, kind: .daily)
        XCTAssertEqual(connectors.count, 1)
        XCTAssertEqual(connectors[0].reason, .gap)
        XCTAssertEqual(connectors[0].from.at, chartBase.addingTimeInterval(60))
        XCTAssertEqual(connectors[0].to.at, chartBase.addingTimeInterval(120 * 60))
    }

    /// 重置处的虚线从「重置时刻的 100%」连到新周期第一条实测采样,
    /// **不是**从前一周期的末点连过来 —— 那会画成一条斜着爬升的假线。
    func testResetConnectorStartsAtFullQuotaOnTheBoundary() {
        let boundary = chartBase.addingTimeInterval(90)
        let samples = [chartSample(minutes: 0, daily: 60),
                       chartSample(minutes: 1, daily: 65),
                       chartSample(minutes: 2, daily: 0.5)]

        let connectors = QuotaSeriesBuilder.connectors(
            samples: samples, kind: .daily, rule: ruleWithBoundary(at: boundary)
        )

        XCTAssertEqual(connectors.count, 1)
        XCTAssertEqual(connectors.first?.reason, .reset)
        XCTAssertEqual(connectors.first?.from.at, boundary)
        XCTAssertEqual(connectors[0].from.remainingRatio, 1, accuracy: 1e-9)
        XCTAssertEqual(connectors[0].to.at, chartBase.addingTimeInterval(120))
    }

    /// 推算不出重置时刻就不画 —— 宁可少一段,也不把起点安在瞎猜的位置上
    func testResetProducesNoConnectorWithoutABoundary() {
        let samples = [chartSample(minutes: 0, daily: 60),
                       chartSample(minutes: 1, daily: 0.5)]
        XCTAssertEqual(
            QuotaSeriesBuilder.connectors(samples: samples, kind: .daily).count, 0)
    }

    /// 推算出的时刻若落在两条采样之外,视为不可信,同样不画
    func testOutOfRangeBoundaryIsRejected() {
        let samples = [chartSample(minutes: 0, daily: 60),
                       chartSample(minutes: 1, daily: 0.5)]
        // 边界落在两条采样之外 —— 计数器下降仍判定为重置,但起点不可信,不画
        let connectors = QuotaSeriesBuilder.connectors(
            samples: samples, kind: .daily,
            rule: ruleWithBoundary(at: chartBase.addingTimeInterval(-9999), every: 86400)
        )
        XCTAssertEqual(connectors.count, 0)
    }

    func testContinuousSamplesNeedNoConnectors() {
        let samples = [chartSample(minutes: 0, daily: 1),
                       chartSample(minutes: 1, daily: 2)]
        XCTAssertEqual(QuotaSeriesBuilder.connectors(samples: samples, kind: .daily).count, 0)
    }

    /// 空档连接段的端点必须就是实线的端点,不能错位
    func testGapConnectorEndpointsMatchTheSolidSegments() {
        let samples = [chartSample(minutes: 0, daily: 1),
                       chartSample(minutes: 120, daily: 5)]

        let points = QuotaSeriesBuilder.build(samples: samples, kind: .daily)
        let connectors = QuotaSeriesBuilder.connectors(samples: samples, kind: .daily)

        XCTAssertEqual(connectors.count, 1)
        XCTAssertEqual(connectors.first?.from, points.first)
        XCTAssertEqual(connectors.first?.to, points.dropFirst().first)
    }

    /// 长空白里若同时跨了重置,按**重置**处理:
    /// 计数器下降是确凿的事实,不该被当成"中间不知道发生了什么"的空档。
    /// 空白本身仍由阴影标出,信息不会丢。
    func testResetTakesPrecedenceOverGap() {
        let samples = [chartSample(minutes: 0, daily: 60),
                       chartSample(minutes: 200, daily: 0.5)]
        let boundary = chartBase.addingTimeInterval(150 * 60)

        let connectors = QuotaSeriesBuilder.connectors(
            samples: samples, kind: .daily,
            rule: ruleWithBoundary(at: boundary, every: 86400)
        )
        XCTAssertEqual(connectors.count, 1)
        XCTAssertEqual(connectors.first?.reason, .reset)
        XCTAssertEqual(connectors.first?.from.remainingRatio ?? -1, 1, accuracy: 1e-9)
    }
}

// MARK: - 周期起点推算

/// 原先这几例测的是 TimeWindow.cycleStart —— 「拿窗口秒数往回减」。
/// 那个算法本身对**固定时长**的周期是对的,错在它被无差别用在日历周期上。
/// 现在它归位成 ResetPolicy.fixedDuration,断言意图原样保留。
final class CycleStartTests: XCTestCase {

    private let dayStart = Date(timeIntervalSince1970: 1_788_800_000)

    private var rule: ResetRule {
        ResetRule(.fixedDuration(anchor: Date(timeIntervalSince1970: 1_788_800_000),
                                 seconds: 86400),
                  provenance: .server)
    }

    private func cycleStart(_ moment: Date) -> Date? {
        rule.period(containing: moment)?.start
    }

    func testMomentInsideCurrentCycleReturnsItsStart() {
        XCTAssertEqual(cycleStart(dayStart.addingTimeInterval(3600)), dayStart)
    }

    func testExactBoundaryBelongsToTheCycleItStarts() {
        XCTAssertEqual(cycleStart(dayStart), dayStart)
    }

    /// 往回推:昨天的时刻应落在昨天那个周期
    func testEarlierMomentStepsBackOneCycle() {
        XCTAssertEqual(cycleStart(dayStart.addingTimeInterval(-600)),
                       dayStart.addingTimeInterval(-86400))
    }

    func testMomentThreeCyclesEarlier() {
        XCTAssertEqual(cycleStart(dayStart.addingTimeInterval(-2.5 * 86400)),
                       dayStart.addingTimeInterval(-3 * 86400))
    }

    func testZeroDurationHasNoCycles() {
        let degenerate = ResetRule(.fixedDuration(anchor: dayStart, seconds: 0),
                                   provenance: .server)
        XCTAssertNil(degenerate.period(containing: dayStart))
    }
}

// MARK: - token 柱状图

final class TokenSeriesTests: XCTestCase {

    func testParsesDayKeysIntoDates() {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let bars = TokenSeriesBuilder.build(
            days: [TokenDay(day: "2026-09-08", tokens: 1_500_000, requests: 12)],
            timeZone: shanghai
        )

        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars[0].tokens, 1_500_000, accuracy: 1e-9)
        XCTAssertEqual(bars[0].requests, 12)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = shanghai
        XCTAssertEqual(bars[0].day,
                       cal.date(from: DateComponents(year: 2026, month: 9, day: 8))!)
    }

    /// 缺的日子不补零柱 ——「那天没用」和「那天 app 没开」不是一回事
    func testMissingDaysAreNotBackfilled() {
        let bars = TokenSeriesBuilder.build(days: [
            TokenDay(day: "2026-09-01", tokens: 10, requests: 1),
            TokenDay(day: "2026-09-05", tokens: 20, requests: 2),
        ])
        XCTAssertEqual(bars.count, 2)
    }

    func testMalformedDayKeyIsDropped() {
        let bars = TokenSeriesBuilder.build(days: [
            TokenDay(day: "not-a-date", tokens: 10, requests: 1),
            TokenDay(day: "2026-09-08", tokens: 20, requests: 2),
        ])
        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars[0].tokens, 20, accuracy: 1e-9)
    }
}

// MARK: - 采样时的上限(OPT-008)

final class HistoricalLimitTests: XCTestCase {

    /// **本条的核心**：上限调高之后，旧点的含义不能被改写。
    /// 50/100 当时剩 50%，上限升到 200 也还是剩 50% —— 那一刻的紧张程度是事实。
    func testRaisingTheLimitDoesNotRewriteOlderPoints() {
        let samples = [
            chartSample(minutes: 0, daily: 50, limit: 100),   // 当时剩 50%
            chartSample(minutes: 10, daily: 50, limit: 200),  // 上限翻倍后，同样花了 50
        ]
        let points = QuotaSeriesBuilder.build(samples: samples, kind: .daily)

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual((points.first?.remainingRatio ?? -1), 0.5, accuracy: 1e-9)
        XCTAssertEqual((points.dropFirst().first?.remainingRatio ?? -1), 0.75, accuracy: 1e-9)
    }

    /// 调低同理：不能凭空给旧点制造紧张
    func testLoweringTheLimitDoesNotRewriteOlderPoints() {
        let samples = [
            chartSample(minutes: 0, daily: 50, limit: 200),   // 当时剩 75%
            chartSample(minutes: 10, daily: 50, limit: 100),
        ]
        let points = QuotaSeriesBuilder.build(samples: samples, kind: .daily)
        XCTAssertEqual((points.first?.remainingRatio ?? -1), 0.75, accuracy: 1e-9)
        XCTAssertEqual((points.dropFirst().first?.remainingRatio ?? -1), 0.5, accuracy: 1e-9)
    }

    /// 取消上限那一段画不出百分比，但**之前**有上限的点照旧
    func testRemovingTheLimitOnlyDropsThePointsAfterIt() {
        let samples = [
            chartSample(minutes: 0, daily: 50, limit: 100),
            chartSample(minutes: 10, daily: 60, limit: 0),    // 改成不限额
        ]
        let points = QuotaSeriesBuilder.build(samples: samples, kind: .daily)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual((points.first?.remainingRatio ?? -1), 0.5, accuracy: 1e-9)
    }

    /// 升级前的老记录没记过上限 —— **不知道**不等于「不限额」，
    /// 更不能拿当前上限顶上。跳过它，而不是编一个百分比。
    func testLegacySamplesWithoutRecordedLimitsAreSkipped() {
        let samples = [
            chartSample(minutes: 0, daily: 50, limit: nil),   // 老记录
            chartSample(minutes: 10, daily: 50, limit: 100),
        ]
        let points = QuotaSeriesBuilder.build(samples: samples, kind: .daily)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.at, chartBase.addingTimeInterval(600))
    }

    /// 全是老记录时曲线为空 —— 诚实的空白，好过一条按今天重写的假曲线
    func testAllLegacySamplesProduceNoCurve() {
        let samples = (0..<5).map { chartSample(minutes: Double($0), daily: 50, limit: nil) }
        XCTAssertEqual(QuotaSeriesBuilder.build(samples: samples, kind: .daily).count, 0)
    }

    /// 跳过老记录不能把段号搞乱：后面的点仍应正确分段
    func testSkippedSamplesDoNotCorruptSegmentNumbering() {
        let samples = [
            chartSample(minutes: 0, daily: 10, limit: nil),
            chartSample(minutes: 5, daily: 20),
            chartSample(minutes: 200, daily: 30),             // 远超空档阈值 → 新段
        ]
        let points = QuotaSeriesBuilder.build(samples: samples, kind: .daily)
        XCTAssertEqual(points.count, 2)
        XCTAssertFalse(points.first?.series == points.dropFirst().first?.series)
    }

    /// 上限变了但用量没变，不该因此多落一条采样 —— differs 只比用量
    func testChangingOnlyTheLimitIsNotAUsageChange() {
        let a = chartSample(minutes: 0, daily: 50, limit: 100)
        let b = chartSample(minutes: 1, daily: 50, limit: 200)
        XCTAssertFalse(b.differs(from: a))
    }

    /// **空曲线有两种原因，而空数组本身区分不出来**（OPT-009 的判据依据）。
    ///
    /// 「这段时间根本没有采样」和「有采样但一条都算不出百分比」对用户是两件事：
    /// 前者该去看 app 有没有在跑，后者该去看额度配置。界面若只看点数组，
    /// 只能二选一地说，必然有一半场合在撒谎 —— 所以它还需要「这段有几条采样」
    /// 这第二个信号。这里把「单看点数组分不出来」这个事实钉住。
    func testAnEmptyCurveDoesNotRevealWhyItIsEmpty() {
        let none: [Sample] = []
        let unlimited = (0..<3).map { chartSample(minutes: Double($0), daily: 50, limit: 0) }
        let legacy = (0..<3).map { chartSample(minutes: Double($0), daily: 50, limit: nil) }

        XCTAssertEqual(QuotaSeriesBuilder.build(samples: none, kind: .daily).count, 0)
        XCTAssertEqual(QuotaSeriesBuilder.build(samples: unlimited, kind: .daily).count, 0)
        XCTAssertEqual(QuotaSeriesBuilder.build(samples: legacy, kind: .daily).count, 0)

        // 三种情况的曲线一模一样，差别只在采样条数上
        XCTAssertEqual(none.count, 0)
        XCTAssertEqual(unlimited.count, 3)
        XCTAssertEqual(legacy.count, 3)
    }
}

// MARK: - 周期 ID 作为切段证据(EXT-005)

private let cycleTZ = TimeZone(identifier: "Asia/Shanghai")!

private func dailyRule(hour: Int = 0) -> ResetRule {
    ResetRule(.calendarDaily(timeZone: cycleTZ, hour: hour, minute: 0), provenance: .server)
}

private func sampleAt(_ date: Date, daily: Double, limit: Double = 70) -> Sample {
    Sample(at: date, totalCost: 0, dailyCost: daily, weeklyOpusCost: 0, windowCost: 0,
           allTokens: 0, requests: 0,
           limits: QuotaLimits(total: limit, daily: limit, weeklyOpus: limit, window: limit))
}

private func shanghai(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = cycleTZ
    return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

final class PeriodBasedSplitTests: XCTestCase {

    /// **规则能看出计数器看不出的重置**：整个周期都没用过时，用量前后都是 0，
    /// 计数器不下降，但确实跨了周期。周期 ID 是直接证据。
    func testCrossingAPeriodIsDetectedEvenWithoutACounterDrop() {
        let samples = [
            sampleAt(shanghai(2026, 6, 15, 23, 50), daily: 0),
            sampleAt(shanghai(2026, 6, 16, 0, 10), daily: 0),
        ]
        let points = QuotaSeriesBuilder.build(samples: samples, kind: .daily, rule: dailyRule())

        XCTAssertEqual(points.count, 2)
        XCTAssertFalse(points.first?.series == points.dropFirst().first?.series,
                       "跨了重置周期就该断开，哪怕用量没变")
    }

    /// 没有规则时退回旧证据：用量没变就看不出来（这正是为什么需要规则）
    func testWithoutARuleTheSilentResetIsInvisible() {
        let samples = [
            sampleAt(shanghai(2026, 6, 15, 23, 50), daily: 0),
            sampleAt(shanghai(2026, 6, 16, 0, 10), daily: 0),
        ]
        let points = QuotaSeriesBuilder.build(samples: samples, kind: .daily)
        XCTAssertEqual(points.first?.series, points.dropFirst().first?.series)
    }

    /// 计数器下降仍是**补充证据**，不能因为有了规则就丢掉 ——
    /// 管理员手动清零、服务端改配置，规则都不知道
    func testCounterDropStillSplitsWithinOnePeriod() {
        // 间隔必须小于空档阈值,否则断开来自空档,测不出计数器下降这条证据
        let samples = [
            sampleAt(shanghai(2026, 6, 15, 10, 0), daily: 60),
            sampleAt(shanghai(2026, 6, 15, 10, 10), daily: 1),   // 同一天内被清零
        ]
        let points = QuotaSeriesBuilder.build(samples: samples, kind: .daily, rule: dailyRule())
        XCTAssertFalse(points.first?.series == points.dropFirst().first?.series)
    }

    /// 同一周期内正常上升不该断开
    func testSamePeriodStaysOneSegment() {
        let samples = [
            sampleAt(shanghai(2026, 6, 15, 10, 0), daily: 10),
            sampleAt(shanghai(2026, 6, 15, 10, 10), daily: 20),
        ]
        let points = QuotaSeriesBuilder.build(samples: samples, kind: .daily, rule: dailyRule())
        XCTAssertEqual(points.first?.series, points.dropFirst().first?.series)
    }

    /// 非整点重置：14:35 的规则下，14:00 和 15:00 属于不同周期
    func testNonIntegerHourResetSplitsAtTheRightMoment() {
        let rule = ResetRule(.calendarDaily(timeZone: cycleTZ, hour: 14, minute: 35),
                             provenance: .server)
        // 跨过 14:35,且间隔在空档阈值内
        let samples = [
            sampleAt(shanghai(2026, 6, 15, 14, 30), daily: 30),
            sampleAt(shanghai(2026, 6, 15, 14, 40), daily: 35),   // 用量还在涨
        ]
        let points = QuotaSeriesBuilder.build(samples: samples, kind: .daily, rule: rule)
        XCTAssertFalse(points.first?.series == points.dropFirst().first?.series)
    }

    /// 算不出周期的规则（滑动窗口）不该产生切段，退回计数器下降
    func testRollingWindowRuleDoesNotSplit() {
        let rule = ResetRule(.rollingWindow(seconds: 3600), provenance: .server)
        let samples = [
            sampleAt(shanghai(2026, 6, 15, 23, 50), daily: 0),
            sampleAt(shanghai(2026, 6, 16, 0, 10), daily: 0),
        ]
        let points = QuotaSeriesBuilder.build(samples: samples, kind: .daily, rule: rule)
        XCTAssertEqual(points.first?.series, points.dropFirst().first?.series)
    }
}

// MARK: - 连接段与点的对齐

final class ConnectorAlignmentTests: XCTestCase {

    /// 有些采样画不出点（上限未知），于是点的序号和采样的序号对不上。
    /// 断点是按采样序号记的，直接拿它索引点数组会取到**错的点**。
    func testConnectorsUseTheRightPointsWhenSomeSamplesAreSkipped() {
        let samples = [
            chartSample(minutes: 0, daily: 10, limit: nil),    // 画不出
            chartSample(minutes: 1, daily: 10, limit: nil),    // 画不出
            chartSample(minutes: 2, daily: 20),
            chartSample(minutes: 200, daily: 30),              // 空档 → 连接段
        ]
        let points = QuotaSeriesBuilder.build(samples: samples, kind: .daily)
        let connectors = QuotaSeriesBuilder.connectors(samples: samples, kind: .daily)

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(connectors.count, 1)
        XCTAssertEqual(connectors.first?.from, points.first)
        XCTAssertEqual(connectors.first?.to, points.dropFirst().first)
    }

    /// 前一条采样画不出点时，这条虚线无处可连 —— 不画，而不是连到别处
    func testNoGapConnectorWhenThePreviousSampleIsNotDrawn() {
        let samples = [
            chartSample(minutes: 0, daily: 10),
            chartSample(minutes: 200, daily: 20, limit: nil),   // 空档的后端画不出
            chartSample(minutes: 201, daily: 30),
        ]
        let connectors = QuotaSeriesBuilder.connectors(samples: samples, kind: .daily)
        XCTAssertEqual(connectors.count, 0)
    }
}

// MARK: - 未知边界不画成已知事件(EXT-005)

final class InferredBoundaryTests: XCTestCase {

    private func samplesAcrossReset() -> [Sample] {
        [sampleAt(shanghai(2026, 6, 15, 23, 50), daily: 60),
         sampleAt(shanghai(2026, 6, 16, 0, 5), daily: 1)]
    }

    /// 服务端明确给出的边界 —— 如实画成已知
    func testServerProvidedBoundaryIsNotMarkedInferred() {
        let rule = ResetRule(.calendarDaily(timeZone: cycleTZ, hour: 0, minute: 0),
                             provenance: .server)
        let connectors = QuotaSeriesBuilder.connectors(samples: samplesAcrossReset(),
                                                       kind: .daily, rule: rule)
        XCTAssertEqual(connectors.count, 1)
        XCTAssertFalse(connectors.first?.isBoundaryInferred ?? true)
    }

    /// 日重置时刻还没观测到，只是「先当作本地零点」——
    /// 这个边界是推算的，不能画得和服务端给的一模一样
    func testInferredBoundaryIsMarked() {
        let rule = ResetRule(.calendarDaily(timeZone: cycleTZ, hour: 0, minute: 0),
                             provenance: .inferred)
        let connectors = QuotaSeriesBuilder.connectors(samples: samplesAcrossReset(),
                                                       kind: .daily, rule: rule)
        XCTAssertEqual(connectors.count, 1)
        XCTAssertTrue(connectors.first?.isBoundaryInferred ?? false)
    }

    /// 观测到过真实的归零事件就算确定 —— 那是发生过的事实，不是假设
    func testObservedBoundaryCountsAsKnown() {
        let rule = ResetRule(.calendarDaily(timeZone: cycleTZ, hour: 0, minute: 0),
                             provenance: .observed)
        let connectors = QuotaSeriesBuilder.connectors(samples: samplesAcrossReset(),
                                                       kind: .daily, rule: rule)
        XCTAssertFalse(connectors.first?.isBoundaryInferred ?? true)
    }

    /// 空档连接段与边界可信度无关，始终为 false
    func testGapConnectorIsNeverMarkedAsInferredBoundary() {
        let samples = [chartSample(minutes: 0, daily: 1),
                       chartSample(minutes: 120, daily: 5)]
        let connectors = QuotaSeriesBuilder.connectors(samples: samples, kind: .daily)
        XCTAssertEqual(connectors.first?.reason, .gap)
        XCTAssertFalse(connectors.first?.isBoundaryInferred ?? true)
    }
}
