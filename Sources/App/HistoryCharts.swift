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

    /// - Parameters:
    ///   - kind/limit: 要画哪条额度,以及它的上限(不限时画不出百分比)
    ///   - window: 该额度当前的重置周期。用来把历史上每次重置的确切时刻推算出来。
    ///   - quotaDays: 额度曲线往前取多少天
    ///   - tokenDays: token 柱状图往前取多少天(通常比曲线长得多)
    func reload(kind: QuotaKind, limit: Double, window: TimeWindow?,
                quotaDays: Int, tokenDays: Int) {
        let to = Date()
        let recorder = HistoryRecorder.shared

        let samples = recorder.samples(from: to.addingTimeInterval(-Double(quotaDays) * 86400),
                                       to: to)
        quotaPoints = QuotaSeriesBuilder.build(samples: samples, kind: kind, limit: limit)

        // 重置周期等长重复,知道当前周期的起点就能推出历史上任意一次
        let cycleStart: ((Date) -> Date?)? = window.map { w in
            { moment in w.cycleStart(containing: moment) }
        }
        quotaConnectors = QuotaSeriesBuilder.connectors(samples: samples,
                                                        kind: kind,
                                                        limit: limit,
                                                        cycleStart: cycleStart)
        gaps = QuotaSeriesBuilder.gaps(samples: samples).map { GapSpan(from: $0.from, to: $0.to) }

        tokenBars = TokenSeriesBuilder.build(
            days: recorder.tokenDays(from: to.addingTimeInterval(-Double(tokenDays) * 86400),
                                     to: to)
        )
        sampleCount = recorder.sampleCount()
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
            ForEach(indexedConnectors) { item in
                LineMark(
                    x: .value("时间", item.connector.from.at),
                    y: .value("剩余", item.connector.from.remainingRatio),
                    series: .value("段", "c\(item.id)")
                )
                .lineStyle(dash)
                .foregroundStyle(Color.accentColor.opacity(0.45))

                LineMark(
                    x: .value("时间", item.connector.to.at),
                    y: .value("剩余", item.connector.to.remainingRatio),
                    series: .value("段", "c\(item.id)")
                )
                .lineStyle(dash)
                .foregroundStyle(Color.accentColor.opacity(0.45))
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
