//
//  ChartSeries.swift — 把采样整理成可直接绘图的序列
//
//  核心判断是「哪些点该连成一条线、哪里必须断开」。断开有两种原因:
//    1. 空档 —— app 没运行,中间发生了什么无从得知
//    2. 重置 —— 计数器归零,前后属于不同周期
//  两种都不能连线:连起来等于凭空捏造中间的走势。
//

import Foundation

// MARK: - 额度曲线

public struct QuotaPoint: Equatable {
    public let at: Date
    /// 剩余额度比例 0…1
    public let remainingRatio: Double
    /// 第几段。段号不同的点之间不画连线。
    public let series: Int

    public init(at: Date, remainingRatio: Double, series: Int) {
        self.at = at
        self.remainingRatio = remainingRatio
        self.series = series
    }
}

/// 曲线为什么在这里断开
public enum BreakReason: Equatable {
    case gap      // app 没运行,中间的走势无从得知
    case reset    // 计数器归零,跨到了新的重置周期
}

/// 连接两段实线的虚线段。虚线表示「这一段是连出来的,不是实测的」。
public struct QuotaConnector: Equatable {
    public let from: QuotaPoint
    public let to: QuotaPoint
    public let reason: BreakReason

    public init(from: QuotaPoint, to: QuotaPoint, reason: BreakReason) {
        self.from = from
        self.to = to
        self.reason = reason
    }
}

public enum QuotaSeriesBuilder {

    /// - Parameters:
    ///   - limit: 该额度的上限。<= 0(不限)时返回空 —— 没有上限就没有「剩余百分比」可言。
    public static func build(samples: [Sample],
                             kind: QuotaKind,
                             limit: Double,
                             gapThreshold: TimeInterval = HistoryGaps.threshold) -> [QuotaPoint] {
        guard limit > 0, !samples.isEmpty else { return [] }

        let breaks = breakReasons(samples: samples, kind: kind, gapThreshold: gapThreshold)
        var series = 0

        return samples.enumerated().map { index, sample in
            if breaks[index] != nil { series += 1 }
            let used = min(max(sample.cost(for: kind) / limit, 0), 1)
            return QuotaPoint(at: sample.at, remainingRatio: 1 - used, series: series)
        }
    }

    /// 每个断点对应一段虚线。两种断点的连法**不同**:
    ///
    /// - **空档**:把前一段的末点和后一段的首点连起来,表示「中间这段是连出来的」。
    /// - **重置**:不连前一段 —— 那会画成一条斜着爬升的假线。改为从**重置时刻的 100%**
    ///   连到新周期的第一条实测采样:重置那一刻剩余必然是满的(计数器归零,这是事实),
    ///   而从那一刻到第一次采样之间确实没有数据,所以用虚线。
    ///
    /// - Parameter cycleStart: 给定时刻 → 它所在重置周期的起点。取不到就不画重置的那段虚线。
    public static func connectors(samples: [Sample],
                                  kind: QuotaKind,
                                  limit: Double,
                                  gapThreshold: TimeInterval = HistoryGaps.threshold,
                                  cycleStart: ((Date) -> Date?)? = nil) -> [QuotaConnector] {
        let points = build(samples: samples, kind: kind, limit: limit, gapThreshold: gapThreshold)
        guard points.count > 1 else { return [] }

        let breaks = breakReasons(samples: samples, kind: kind, gapThreshold: gapThreshold)

        return breaks.keys.sorted().compactMap { index -> QuotaConnector? in
            guard index > 0, index < points.count, let reason = breaks[index] else { return nil }

            switch reason {
            case .gap:
                return QuotaConnector(from: points[index - 1], to: points[index], reason: .gap)

            case .reset:
                guard let boundary = cycleStart?(samples[index].at),
                      boundary > samples[index - 1].at,
                      boundary <= samples[index].at
                else { return nil }

                let origin = QuotaPoint(at: boundary,
                                        remainingRatio: 1,
                                        series: points[index].series)
                return QuotaConnector(from: origin, to: points[index], reason: .reset)
            }
        }
    }

    /// 断点位置 → 原因。键是**后一条**采样的下标。
    static func breakReasons(samples: [Sample],
                             kind: QuotaKind,
                             gapThreshold: TimeInterval) -> [Int: BreakReason] {
        guard samples.count > 1 else { return [:] }

        var result: [Int: BreakReason] = [:]
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]

            // 重置优先于空档:计数器下降是**已知事实**,
            // 哪怕这次下降夹在一段长空白里,也确切说明跨过了重置边界。
            // 既然知道是重置,就不该用虚线把两端连起来 —— 那会画成一条斜着爬升的假线。
            // 空白本身仍由阴影标出,信息没有丢。
            if current.cost(for: kind) < previous.cost(for: kind) {
                result[index] = .reset
            } else if current.at.timeIntervalSince(previous.at) > gapThreshold {
                result[index] = .gap
            }
        }
        return result
    }

    /// 空档区间(用于在图上画阴影)。返回的是每段「缺失」的起止时刻。
    public static func gaps(samples: [Sample],
                            threshold: TimeInterval = HistoryGaps.threshold) -> [(from: Date, to: Date)] {
        guard samples.count > 1 else { return [] }

        var result: [(from: Date, to: Date)] = []
        for i in 1..<samples.count {
            let previous = samples[i - 1]
            let current = samples[i]
            if current.at.timeIntervalSince(previous.at) > threshold {
                result.append((from: previous.at, to: current.at))
            }
        }
        return result
    }
}

// MARK: - token 柱状图

public struct TokenBar: Equatable {
    public let day: Date
    public let tokens: Double
    public let requests: Int

    public init(day: Date, tokens: Double, requests: Int) {
        self.day = day
        self.tokens = tokens
        self.requests = requests
    }
}

public enum TokenSeriesBuilder {

    /// 把 "yyyy-MM-dd" 的桶还原成日期。
    /// 只返回**真正记录过**的天 —— 没有数据的日子不补零柱,
    /// 因为「那天没用」和「那天 app 没开」是两回事,补零会把后者说成前者。
    public static func build(days: [TokenDay], timeZone: TimeZone = .current) -> [TokenBar] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        return days.compactMap { day in
            guard let date = parse(day.day, calendar: calendar) else { return nil }
            return TokenBar(day: date, tokens: day.tokens, requests: day.requests)
        }
    }

    static func parse(_ string: String, calendar: Calendar) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0],
                                                  month: parts[1],
                                                  day: parts[2]))
    }
}
