import Foundation
import CodaPaceCore

private let chartBase = Date(timeIntervalSince1970: 1_788_800_000)

private func chartSample(minutes: Double, daily: Double = 0, total: Double = 0) -> Sample {
    Sample(at: chartBase.addingTimeInterval(minutes * 60),
           totalCost: total, dailyCost: daily,
           weeklyOpusCost: 0, windowCost: 0,
           allTokens: 0, requests: 0)
}

// MARK: - 额度曲线

final class QuotaSeriesTests: XCTestCase {

    func testRemainingRatioIsDerivedFromLimit() {
        let points = QuotaSeriesBuilder.build(
            samples: [chartSample(minutes: 0, daily: 17.5)],
            kind: .daily, limit: 70
        )
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].remainingRatio, 0.75, accuracy: 1e-9)
    }

    /// 不限额度没有「剩余百分比」可言,不该画出任何点
    func testUnlimitedQuotaProducesNoPoints() {
        let points = QuotaSeriesBuilder.build(
            samples: [chartSample(minutes: 0, daily: 17.5)],
            kind: .daily, limit: 0
        )
        XCTAssertEqual(points.count, 0)
    }

    func testContinuousSamplesShareOneSeries() {
        let points = QuotaSeriesBuilder.build(
            samples: [chartSample(minutes: 0, daily: 1),
                      chartSample(minutes: 1, daily: 2),
                      chartSample(minutes: 2, daily: 3)],
            kind: .daily, limit: 70
        )
        XCTAssertEqual(points.map(\.series), [0, 0, 0])
    }

    /// 空档要断开 —— 连起来等于捏造中间那段的走势
    func testGapStartsNewSeries() {
        let points = QuotaSeriesBuilder.build(
            samples: [chartSample(minutes: 0, daily: 1),
                      chartSample(minutes: 1, daily: 2),
                      chartSample(minutes: 120, daily: 5)],
            kind: .daily, limit: 70
        )
        XCTAssertEqual(points.map(\.series), [0, 0, 1])
    }

    /// 重置也要断开,否则图上会出现一条从满格直坠到 0 的假线
    func testResetStartsNewSeries() {
        let points = QuotaSeriesBuilder.build(
            samples: [chartSample(minutes: 0, daily: 60),
                      chartSample(minutes: 1, daily: 65),
                      chartSample(minutes: 2, daily: 0.5)],
            kind: .daily, limit: 70
        )
        XCTAssertEqual(points.map(\.series), [0, 0, 1])
        // 新周期的起点应该接近满格
        XCTAssertEqual(points[2].remainingRatio, 1 - 0.5 / 70, accuracy: 1e-9)
    }

    /// 超额使用时剩余比例不该变成负数
    func testOverspendClampsToZero() {
        let points = QuotaSeriesBuilder.build(
            samples: [chartSample(minutes: 0, daily: 90)],
            kind: .daily, limit: 70
        )
        XCTAssertEqual(points[0].remainingRatio, 0, accuracy: 1e-9)
    }

    func testEmptyInputProducesNoPoints() {
        XCTAssertEqual(QuotaSeriesBuilder.build(samples: [], kind: .daily, limit: 70).count, 0)
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

        let connectors = QuotaSeriesBuilder.connectors(samples: samples, kind: .daily, limit: 70)
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
            samples: samples, kind: .daily, limit: 70,
            cycleStart: { _ in boundary }
        )

        XCTAssertEqual(connectors.count, 1)
        XCTAssertEqual(connectors[0].reason, .reset)
        XCTAssertEqual(connectors[0].from.at, boundary)
        XCTAssertEqual(connectors[0].from.remainingRatio, 1, accuracy: 1e-9)
        XCTAssertEqual(connectors[0].to.at, chartBase.addingTimeInterval(120))
    }

    /// 推算不出重置时刻就不画 —— 宁可少一段,也不把起点安在瞎猜的位置上
    func testResetProducesNoConnectorWithoutABoundary() {
        let samples = [chartSample(minutes: 0, daily: 60),
                       chartSample(minutes: 1, daily: 0.5)]
        XCTAssertEqual(
            QuotaSeriesBuilder.connectors(samples: samples, kind: .daily, limit: 70).count, 0)
    }

    /// 推算出的时刻若落在两条采样之外,视为不可信,同样不画
    func testOutOfRangeBoundaryIsRejected() {
        let samples = [chartSample(minutes: 0, daily: 60),
                       chartSample(minutes: 1, daily: 0.5)]
        let connectors = QuotaSeriesBuilder.connectors(
            samples: samples, kind: .daily, limit: 70,
            cycleStart: { _ in chartBase.addingTimeInterval(-9999) }
        )
        XCTAssertEqual(connectors.count, 0)
    }

    func testContinuousSamplesNeedNoConnectors() {
        let samples = [chartSample(minutes: 0, daily: 1),
                       chartSample(minutes: 1, daily: 2)]
        XCTAssertEqual(QuotaSeriesBuilder.connectors(samples: samples, kind: .daily, limit: 70).count, 0)
    }

    /// 空档连接段的端点必须就是实线的端点,不能错位
    func testGapConnectorEndpointsMatchTheSolidSegments() {
        let samples = [chartSample(minutes: 0, daily: 1),
                       chartSample(minutes: 120, daily: 5)]

        let points = QuotaSeriesBuilder.build(samples: samples, kind: .daily, limit: 70)
        let connectors = QuotaSeriesBuilder.connectors(samples: samples, kind: .daily, limit: 70)

        XCTAssertEqual(connectors.count, 1)
        XCTAssertEqual(connectors[0].from, points[0])
        XCTAssertEqual(connectors[0].to, points[1])
    }

    /// 长空白里若同时跨了重置,按**重置**处理:
    /// 计数器下降是确凿的事实,不该被当成"中间不知道发生了什么"的空档。
    /// 空白本身仍由阴影标出,信息不会丢。
    func testResetTakesPrecedenceOverGap() {
        let samples = [chartSample(minutes: 0, daily: 60),
                       chartSample(minutes: 200, daily: 0.5)]
        let boundary = chartBase.addingTimeInterval(150 * 60)

        let connectors = QuotaSeriesBuilder.connectors(
            samples: samples, kind: .daily, limit: 70,
            cycleStart: { _ in boundary }
        )
        XCTAssertEqual(connectors.count, 1)
        XCTAssertEqual(connectors[0].reason, .reset)
        XCTAssertEqual(connectors[0].from.remainingRatio, 1, accuracy: 1e-9)
    }
}

// MARK: - 周期起点推算

final class CycleStartTests: XCTestCase {

    private let dayStart = Date(timeIntervalSince1970: 1_788_800_000)

    private var window: TimeWindow {
        TimeWindow(start: dayStart, end: dayStart.addingTimeInterval(86400))
    }

    func testMomentInsideCurrentCycleReturnsItsStart() {
        XCTAssertEqual(window.cycleStart(containing: dayStart.addingTimeInterval(3600)), dayStart)
    }

    func testExactBoundaryBelongsToTheCycleItStarts() {
        XCTAssertEqual(window.cycleStart(containing: dayStart), dayStart)
    }

    /// 往回推:昨天的时刻应落在昨天那个周期
    func testEarlierMomentStepsBackOneCycle() {
        XCTAssertEqual(window.cycleStart(containing: dayStart.addingTimeInterval(-600)),
                       dayStart.addingTimeInterval(-86400))
    }

    func testMomentThreeCyclesEarlier() {
        XCTAssertEqual(window.cycleStart(containing: dayStart.addingTimeInterval(-2.5 * 86400)),
                       dayStart.addingTimeInterval(-3 * 86400))
    }

    func testZeroDurationWindowHasNoCycles() {
        let degenerate = TimeWindow(start: dayStart, end: dayStart)
        XCTAssertNil(degenerate.cycleStart(containing: dayStart))
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
