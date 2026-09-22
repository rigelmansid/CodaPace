import Foundation
import CodaPaceCore

private let selTZ = TimeZone(identifier: "Asia/Shanghai")!
private let selBase = Date(timeIntervalSince1970: 1_788_800_000)

private func at(_ minutes: Double) -> Date { selBase.addingTimeInterval(minutes * 60) }

private func selSample(_ minutes: Double, daily: Double = 10, limit: Double? = 70) -> Sample {
    Sample(at: at(minutes), quotas: ["daily": QuotaReading(used: daily, limit: limit)])
}

private func plotted(_ samples: [Sample]) -> [PlottedPoint] {
    QuotaSeriesBuilder.plotted(samples: samples, bucketID: "daily")
}

// MARK: - 选点

final class PointSelectionTests: XCTestCase {

    private var points: [PlottedPoint] {
        plotted([selSample(0), selSample(10), selSample(20)])
    }

    func testEmptyChartHasNoSelection() {
        XCTAssertNil(ChartSelection.nearestPoint(to: at(5), in: []))
    }

    func testSinglePointIsAlwaysSelected() {
        let hit = ChartSelection.nearestPoint(to: at(999), in: plotted([selSample(0)]))
        XCTAssertEqual(hit?.at, at(0))
    }

    func testExactHitHasZeroDistance() {
        let hit = ChartSelection.nearestPoint(to: at(10), in: points)
        XCTAssertEqual(hit?.at, at(10))
        XCTAssertEqual(hit?.distance ?? -1, 0, accuracy: 1e-9)
    }

    /// 指针落在两点之间 —— 吸附到较近的那个，并报出距离
    func testSnapsToTheNearerNeighbour() {
        let hit = ChartSelection.nearestPoint(to: at(12), in: points)
        XCTAssertEqual(hit?.at, at(10))
        XCTAssertEqual(hit?.distance ?? -1, 120, accuracy: 1e-9)
    }

    /// 首尾之外也要能选中，不该返回 nil
    func testBeforeFirstAndAfterLastStillSelect() {
        XCTAssertEqual(ChartSelection.nearestPoint(to: at(-100), in: points)?.at, at(0))
        XCTAssertEqual(ChartSelection.nearestPoint(to: at(100), in: points)?.at, at(20))
    }

    /// 等距时取较早的那个 —— 重置边界上前后两点可能等距，
    /// 结果必须确定，否则同一位置悬停会来回跳
    func testTiesResolveToTheEarlierPoint() {
        let hit = ChartSelection.nearestPoint(to: at(5), in: plotted([selSample(0), selSample(10)]))
        XCTAssertEqual(hit?.at, at(0))
    }

    /// 密集采样:每分钟一条也要选得准
    func testDenseSamplesSelectPrecisely() {
        let dense = plotted((0...60).map { selSample(Double($0)) })
        XCTAssertEqual(ChartSelection.nearestPoint(to: at(37.4), in: dense)?.at, at(37))
    }

    /// **空档里不插值**:返回的仍是真实存在的点，且距离 > 0，
    /// 界面据此说明「这是最近一次采样」而不是假装那里有数据
    func testInsideAGapReturnsARealSampleMarkedAsNearest() {
        let across = plotted([selSample(0), selSample(300)])   // 中间 5 小时空档
        let hit = ChartSelection.nearestPoint(to: at(100), in: across)

        XCTAssertEqual(hit?.at, at(0), "必须是真实采样点")
        XCTAssertTrue((hit?.distance ?? 0) > 0, "指针不在这个点上")
    }

    /// 画不出点的采样不参与选中 —— 曲线上看不见它，就不该能选到它
    func testUndrawableSamplesAreNotSelectable() {
        let mixed = plotted([selSample(0, limit: nil), selSample(10)])
        XCTAssertEqual(mixed.count, 1)
        XCTAssertEqual(ChartSelection.nearestPoint(to: at(0), in: mixed)?.at, at(10))
    }
}

// MARK: - 曲线浮层内容

final class QuotaTooltipTests: XCTestCase {

    private func hit(at moment: Date, samples: [Sample]) -> ChartSelection.PointHit {
        ChartSelection.nearestPoint(to: moment, in: plotted(samples))!
    }

    /// 剩余金额用**采样当时的上限**算，和曲线同一口径
    func testRemainingAmountUsesTheSampleOwnLimit() {
        let tip = QuotaTooltip(hit: hit(at: at(0), samples: [selSample(0, daily: 30, limit: 100)]),
                               bucketID: "daily", rule: nil)
        XCTAssertEqual(tip.remainingAmount ?? -1, 70, accuracy: 1e-9)
        XCTAssertEqual(tip.remainingRatio, 0.7, accuracy: 1e-9)
    }

    /// 正好指着某点时不该标成「最近一次」
    func testExactHitIsNotMarkedAsNearest() {
        XCTAssertFalse(QuotaTooltip(hit: hit(at: at(0), samples: [selSample(0)]),
                                    bucketID: "daily", rule: nil).isNearest)
    }

    /// 落在空档里必须标出来 —— 这是「不插值」在界面上的体现
    func testGapHitIsMarkedAsNearestWithItsRealTime() {
        let tip = QuotaTooltip(hit: hit(at: at(100), samples: [selSample(0), selSample(300)]),
                               bucketID: "daily", rule: nil)
        XCTAssertTrue(tip.isNearest)
        XCTAssertEqual(tip.at, at(0), "显示的必须是那条采样的真实时间")
    }

    /// 带上该点所属的重置周期
    func testCarriesThePeriodThePointBelongsTo() {
        let rule = ResetRule(.calendarDaily(timeZone: selTZ, hour: 0, minute: 0),
                             provenance: .server)
        let tip = QuotaTooltip(hit: hit(at: at(0), samples: [selSample(0)]),
                               bucketID: "daily", rule: rule)
        XCTAssertNotNil(tip.period)
        XCTAssertEqual(tip.period, rule.period(containing: at(0)))
    }

    /// 算不出周期时就是 nil —— 不编一个出来
    func testNoPeriodWhenTheRuleCannotComputeOne() {
        let rolling = ResetRule(.rollingWindow(seconds: 3600), provenance: .server)
        XCTAssertNil(QuotaTooltip(hit: hit(at: at(0), samples: [selSample(0)]),
                                  bucketID: "daily", rule: rolling).period)
        XCTAssertNil(QuotaTooltip(hit: hit(at: at(0), samples: [selSample(0)]),
                                  bucketID: "daily", rule: nil).period)
    }
}

// MARK: - token 柱浮层

final class TokenTooltipTests: XCTestCase {

    private func day(_ y: Int, _ mo: Int, _ d: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = selTZ
        return c.date(from: DateComponents(year: y, month: mo, day: d))!
    }

    /// **缺失的一天不是「用了 0」** —— 没有柱子就返回 nil，不能显示成零
    func testMissingDayHasNoBar() {
        let bars = [TokenBar(day: day(2026, 6, 15), tokens: 100, requests: 2)]
        XCTAssertNil(ChartSelection.bar(at: day(2026, 6, 16), in: bars, timeZone: selTZ))
    }

    /// 真实的零用量那天有柱子，照常选中 —— 和「缺失」是两回事
    func testGenuineZeroDayIsStillSelectable() {
        let bars = [TokenBar(day: day(2026, 6, 15), tokens: 0, requests: 0)]
        let bar = ChartSelection.bar(at: day(2026, 6, 15), in: bars, timeZone: selTZ)
        XCTAssertEqual(bar?.tokens ?? -1, 0, accuracy: 1e-9)
    }

    /// 当天任意时刻都该命中那根柱子
    func testAnyMomentWithinTheDayHitsThatBar() {
        let bars = [TokenBar(day: day(2026, 6, 15), tokens: 100, requests: 2)]
        let noon = day(2026, 6, 15).addingTimeInterval(12 * 3600)
        XCTAssertNotNil(ChartSelection.bar(at: noon, in: bars, timeZone: selTZ))
    }

    func testCrossMonthBarsAreSelectedCorrectly() {
        let bars = [TokenBar(day: day(2026, 5, 31), tokens: 1, requests: 1),
                    TokenBar(day: day(2026, 6, 1), tokens: 2, requests: 1)]
        XCTAssertEqual(ChartSelection.bar(at: day(2026, 6, 1), in: bars, timeZone: selTZ)?.tokens,
                       2)
    }

    /// 请求数为 0 时分不清「真没有」和「接口没给」，不显示，而不是填个 0
    func testZeroRequestsAreOmittedRatherThanShownAsZero() {
        XCTAssertNil(TokenTooltip(bar: TokenBar(day: day(2026, 6, 15), tokens: 5, requests: 0))
                        .requests)
        XCTAssertEqual(TokenTooltip(bar: TokenBar(day: day(2026, 6, 15), tokens: 5, requests: 3))
                        .requests, 3)
    }

    func testUnattributedUsageIsCarried() {
        let tip = TokenTooltip(bar: TokenBar(day: day(2026, 6, 15), tokens: 100, requests: 2),
                               unattributedTokens: 42)
        XCTAssertEqual(tip.unattributedTokens, 42, accuracy: 1e-9)
    }

    // ── 周期视图不能把非自然日周期叫作「当日」 ──

    func testCalendarDaySpanIsAWholeDay() {
        XCTAssertTrue(TokenTooltip.Span.day(day(2026, 6, 15)).isWholeCalendarDay(in: selTZ))
        XCTAssertTrue(TokenTooltip.Span
            .period(start: day(2026, 6, 15), end: day(2026, 6, 16))
            .isWholeCalendarDay(in: selTZ))
    }

    /// 「每天 14:35 重置」的周期横跨两个自然日，叫它「6 月 15 日」是错的
    func testNonMidnightPeriodIsNotAWholeDay() {
        let start = day(2026, 6, 15).addingTimeInterval(14 * 3600 + 35 * 60)
        let end = start.addingTimeInterval(86400)
        XCTAssertFalse(TokenTooltip.Span.period(start: start, end: end)
            .isWholeCalendarDay(in: selTZ))
    }

    /// 长度不是一天的周期同样不能叫「当日」
    func testMultiDayPeriodIsNotAWholeDay() {
        XCTAssertFalse(TokenTooltip.Span
            .period(start: day(2026, 6, 15), end: day(2026, 6, 22))
            .isWholeCalendarDay(in: selTZ))
    }
}

// MARK: - 完整数字

final class ExactNumberTests: XCTestCase {

    /// 浮层要给准确值：「1.2M」看不出是 1,150,000 还是 1,249,999
    func testExactKeepsEveryDigitWithGrouping() {
        XCTAssertEqual(Fmt.exact(2_152_951_760), "2,152,951,760")
        XCTAssertEqual(Fmt.exact(0), "0")
        XCTAssertEqual(Fmt.exact(999), "999")
    }

    func testExactRoundsFractions() {
        XCTAssertEqual(Fmt.exact(1234.6), "1,235")
    }

    /// 和缩写版并存，各用各的场合
    func testCompactStillAbbreviates() {
        XCTAssertEqual(Fmt.count(2_152_951_760), "2.15B")
    }
}
