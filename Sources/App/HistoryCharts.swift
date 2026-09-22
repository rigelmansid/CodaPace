//
//  HistoryCharts.swift — 历史数据的读取与绘制
//
//  绘图规则(与 Core 的序列构建配套):
//  · 段号不同的点之间不连线 —— 空档和重置都会开新段
//  · 空档区间画成阴影,明确表示「这段时间没有数据」而不是「这段时间没用量」
//  · 没记录过的日子不补零柱
//

import SwiftUI
import Charts

// MARK: - 数据源

/// 图上的一段空档
struct GapSpan: Identifiable {
    let id = UUID()
    let from: Date
    let to: Date
}

/// 带下标的点,供 Chart 的 ForEach 用(采样时刻可能重复,不能拿时间当 id)
private struct IndexedPoint: Identifiable {
    let id: Int
    let point: QuotaPoint
}

private struct IndexedBar: Identifiable {
    let id: Int
    let bar: TokenBar
}

private struct IndexedConnector: Identifiable {
    let id: Int
    let connector: QuotaConnector
}

@MainActor
final class HistoryModel: ObservableObject {

    @Published private(set) var quotaPoints: [QuotaPoint] = []
    @Published private(set) var quotaConnectors: [QuotaConnector] = []
    @Published private(set) var gaps: [GapSpan] = []
    @Published private(set) var tokenBars: [TokenBar] = []
    @Published private(set) var sampleCount = 0

    /// 曲线时间范围内**一共有多少条采样**,不管画不画得出点。
    ///
    /// `quotaPoints` 为空有两种完全不同的原因,而空数组本身区分不出来:
    /// 一是这段时间根本没有采样,二是有采样但一条都算不出百分比
    /// (当时不限额,或升级前的老记录没记过上限)。界面要对用户说清是哪一种,
    /// 就必须有这第二个信号。
    @Published private(set) var quotaSamplesInRange = 0

    /// 范围内**画不出百分比、因而没能上图**的采样条数(OPT-012)。
    ///
    /// 上面那个信号只在曲线**完全为空**时才用得上,于是漏掉了第三种情形:
    /// 一部分画得出、一部分画不出。只要有一个点能画,曲线就照画,那些被跳过的
    /// 采样既不在线上也不在任何一句文案里 —— 用户看到一张几乎空白的图,
    /// 却得不到任何解释,只能自己去排查一个并不存在的问题。
    ///
    /// 这正是 OPT-008 之后老用户必然经历的一段:升级前的采样没记过当时的上限,
    /// 在新采样填满窗口之前,长窗口里必然是「少量画得出 + 大量画不出」。
    ///
    /// 刻意**不区分**是「当时不限额」还是「老记录没记上限」:两者都是真实成因,
    /// 挑一个说出来就是在断言我们并不知道的事。文案沿用 `historyNoLimitMessage`
    /// 已确立的口径 —— 两种可能都摆出来。
    @Published private(set) var quotaSamplesWithoutPercentage = 0

    /// 这个账户的历史里出现过哪些额度桶。额度选择器的内容由它和当前快照合并而来 ——
    /// 离线时快照是 nil,没有它选择器会整个空掉,用户连攒下的历史都翻不了。
    @Published private(set) var knownBucketIDs: [String] = []

    /// - Parameters:
    ///   - bucketID: 要画哪条额度。**nil 表示当前没有可画的额度**(没有快照、
    ///     历史里也没有任何桶)—— 此时曲线为空,但 token 柱状图和采样计数照常给,
    ///     它们和额度是两条独立的链路。
    ///   - rule: 该额度的重置规则。用来把历史上每次重置的确切时刻按其自身算法推出来。
    ///   - quotaDays: 额度曲线往前取多少天
    ///   - tokenDays: token 柱状图往前取多少天(通常比曲线长得多)
    ///
    /// 这里**刻意不收当前上限**:每个历史点用的是它自己那条采样当时的上限
    /// (见 `QuotaSeriesBuilder.build`),当前上限在绘图里没有任何位置。
    func reload(bucketID: String?, rule: ResetRule?,
                quotaDays: Int, tokenDays: Int) {
        let to = Date()
        let recorder = HistoryRecorder.shared

        let samples = recorder.samples(from: to.addingTimeInterval(-Double(quotaDays) * 86400),
                                       to: to)
        quotaSamplesInRange = samples.count

        // 重置边界和「是否跨过重置」都由这条规则算,不会两处不一致。
        // 规则算不出周期(滑动窗口、未知)时,退回「计数器下降」这条补充证据。
        quotaPoints = bucketID.map {
            QuotaSeriesBuilder.build(samples: samples, bucketID: $0, rule: rule)
        } ?? []

        // 差额即被跳过的条数。算式在这里落成一个有名字的信号,而不是留给视图现减 ——
        // 光看 `总数 − 点数` 看不出它在回答什么问题,下一个人很容易当冗余删掉。
        quotaSamplesWithoutPercentage = max(0, samples.count - quotaPoints.count)

        quotaConnectors = bucketID.map {
            QuotaSeriesBuilder.connectors(samples: samples, bucketID: $0, rule: rule)
        } ?? []
        gaps = QuotaSeriesBuilder.gaps(samples: samples).map { GapSpan(from: $0.from, to: $0.to) }

        tokenBars = TokenSeriesBuilder.build(
            days: recorder.tokenDays(from: to.addingTimeInterval(-Double(tokenDays) * 86400),
                                     to: to)
        )
        sampleCount = recorder.sampleCount()
        knownBucketIDs = recorder.knownBucketIDs()
    }

    /// 只刷新「历史里有哪些桶」。
    ///
    /// 单独留一个入口,是因为**选择器得先有内容,才谈得上选中谁**:
    /// 窗口刚打开时还没选中任何桶,`reload` 无从知道该默认选哪条。
    func refreshBuckets() {
        knownBucketIDs = HistoryRecorder.shared.knownBucketIDs()
    }
}

// MARK: - 额度曲线

struct QuotaChart: View {
    let points: [QuotaPoint]
    var connectors: [QuotaConnector] = []
    let gaps: [GapSpan]
    var showsAxes = false

    private var indexed: [IndexedPoint] {
        points.enumerated().map { IndexedPoint(id: $0.offset, point: $0.element) }
    }

    private var indexedConnectors: [IndexedConnector] {
        connectors.enumerated().map { IndexedConnector(id: $0.offset, connector: $0.element) }
    }

    private let dash = StrokeStyle(lineWidth: 1, dash: [3, 3])

    @ViewBuilder
    var body: some View {
        if showsAxes {
            baseChart
                .chartYAxis {
                    AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let ratio = value.as(Double.self) {
                                Text(Fmt.percent(ratio)).font(.system(size: 9))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
        } else {
            // 缩略图不要坐标轴,空间全留给曲线本身
            baseChart
                .chartYAxis(.hidden)
                .chartXAxis(.hidden)
        }
    }

    private var baseChart: some View {
        Chart {
            // 先画空档阴影,让曲线压在上面
            ForEach(gaps) { gap in
                RectangleMark(xStart: .value("起", gap.from),
                              xEnd: .value("止", gap.to))
                    .foregroundStyle(Color.secondary.opacity(0.10))
            }

            // 虚线连接段:表示「这一段是连出来的,不是实测的」。
            // 每段各自成 series,否则几段虚线会被首尾串成一条。
            //
            // 边界时刻本身是推算的那些画得更淡 —— 未知不能和已知长得一样。
            ForEach(indexedConnectors) { item in
                LineMark(
                    x: .value("时间", item.connector.from.at),
                    y: .value("剩余", item.connector.from.remainingRatio),
                    series: .value("段", "c\(item.id)")
                )
                .lineStyle(dash)
                .foregroundStyle(Color.accentColor.opacity(item.connector.isBoundaryInferred
                                                          ? 0.22 : 0.45))

                LineMark(
                    x: .value("时间", item.connector.to.at),
                    y: .value("剩余", item.connector.to.remainingRatio),
                    series: .value("段", "c\(item.id)")
                )
                .lineStyle(dash)
                .foregroundStyle(Color.accentColor.opacity(item.connector.isBoundaryInferred
                                                          ? 0.22 : 0.45))
            }

            ForEach(indexed) { item in
                // series 把不同段拆成独立的实线,段与段之间自然断开
                LineMark(
                    x: .value("时间", item.point.at),
                    y: .value("剩余", item.point.remainingRatio),
                    series: .value("段", "s\(item.point.series)")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
            }
        }
        .chartYScale(domain: 0...1)
    }
}

// MARK: - token 柱状图

struct TokenChart: View {
    let bars: [TokenBar]
    var showsAxes = false

    private var indexed: [IndexedBar] {
        bars.enumerated().map { IndexedBar(id: $0.offset, bar: $0.element) }
    }

    @ViewBuilder
    var body: some View {
        if showsAxes {
            baseChart
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let tokens = value.as(Double.self) {
                                Text(Fmt.count(tokens)).font(.system(size: 9))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
        } else {
            baseChart
                .chartYAxis(.hidden)
                .chartXAxis(.hidden)
        }
    }

    private var baseChart: some View {
        Chart {
            ForEach(indexed) { item in
                BarMark(
                    x: .value("日期", item.bar.day, unit: .day),
                    y: .value("tokens", item.bar.tokens)
                )
                .foregroundStyle(Color.teal)
                .cornerRadius(2)
            }
        }
    }
}

// MARK: - 空数据占位

/// 历史是从装上那天开始攒的,前期没数据很正常 —— 要说清楚,而不是显示一张空白图
struct ChartPlaceholder: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
