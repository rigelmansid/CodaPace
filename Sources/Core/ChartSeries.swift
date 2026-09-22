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

/// 一个画出来的点,以及它来自的那条采样。
public struct PlottedPoint: Equatable {
    public let point: QuotaPoint
    public let sample: Sample

    public init(point: QuotaPoint, sample: Sample) {
        self.point = point
        self.sample = sample
    }
}

/// 连接两段实线的虚线段。虚线表示「这一段是连出来的,不是实测的」。
public struct QuotaConnector: Equatable {
    public let from: QuotaPoint
    public let to: QuotaPoint
    public let reason: BreakReason

    /// 这一段的**起点时刻是推算出来的**,不是观测或服务端给的。
    ///
    /// 只对重置连接段有意义:它的起点画在「重置发生的那一刻」。
    /// 如果那个时刻本身是推算的(比如日重置时刻还没观测到,先当作本地零点),
    /// 就不能把它画得和服务端明确给出的边界一模一样 —— 那等于把未知当成已知事件。
    /// 界面该用不同画法或标注区分,和「(估算)」那个标签是同一件事。
    public let isBoundaryInferred: Bool

    public init(from: QuotaPoint, to: QuotaPoint, reason: BreakReason,
                isBoundaryInferred: Bool = false) {
        self.from = from
        self.to = to
        self.reason = reason
        self.isBoundaryInferred = isBoundaryInferred
    }
}

public enum QuotaSeriesBuilder {

    /// 每个点用**它自己那条采样当时**的上限算百分比,不是当前上限。
    ///
    /// 统一除以当前上限会把过去按今天重写:50/100(剩 50%)在上限调到 200 之后
    /// 会显示成剩 75%,那一刻的紧张程度凭空消失。上限调低则反过来,凭空制造紧张。
    ///
    /// 三种点画不出百分比,一律跳过而不是编一个:
    /// · 这次采样里**根本没有这条额度**(供应商没报,或那时还没接这家)
    /// · 上限**未知**(升级前的老记录没记过)
    /// · 当时**不限额**(上限为 0)—— 没有上限就没有「剩余百分比」可言
    public static func build(samples: [Sample],
                             bucketID: String,
                             rule: ResetRule? = nil,
                             gapThreshold: TimeInterval = HistoryGaps.threshold) -> [QuotaPoint] {
        plotted(samples: samples, bucketID: bucketID, rule: rule,
                gapThreshold: gapThreshold).map(\.point)
    }

    /// 画出来的点,**连同它来自哪条采样**。
    ///
    /// 选点、浮层都需要回到原始采样(取当时的上限、算剩余金额),
    /// 而点的序号和采样的序号**对不上** —— 有些采样画不出点(上限未知或当时不限额)。
    /// 所以配好对一起给出去,调用方不必也不该自己拿下标去凑。
    public static func plotted(samples: [Sample],
                               bucketID: String,
                               rule: ResetRule? = nil,
                               gapThreshold: TimeInterval = HistoryGaps.threshold)
    -> [PlottedPoint] {
        drawablePoints(samples: samples, bucketID: bucketID, rule: rule, gapThreshold: gapThreshold)
            .map { PlottedPoint(point: $0.point, sample: samples[$0.index]) }
    }

    /// 断点是按采样序号记的,所以内部要留着这个序号
    private static func drawablePoints(samples: [Sample],
                                       bucketID: String,
                                       rule: ResetRule?,
                                       gapThreshold: TimeInterval)
    -> [(index: Int, point: QuotaPoint)] {
        guard !samples.isEmpty else { return [] }

        let breaks = breakReasons(samples: samples, bucketID: bucketID,
                                  gapThreshold: gapThreshold, rule: rule)
        var series = 0

        return samples.enumerated().compactMap { index, sample in
            // 断点照样推进段号,哪怕这条采样本身画不出来 —— 否则后面的点会被并进前一段
            if breaks[index] != nil { series += 1 }

            guard let reading = sample.reading(bucketID),
                  let limit = reading.limit, limit > 0 else { return nil }

            let used = min(max(reading.used / limit, 0), 1)
            return (index, QuotaPoint(at: sample.at, remainingRatio: 1 - used, series: series))
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
    /// - Parameter rule: 重置边界由它算 —— 和判断「是否跨过重置」用的是同一条规则,
    ///   不会出现「按 A 判断断开、按 B 画边界」这种不一致。
    public static func connectors(samples: [Sample],
                                  bucketID: String,
                                  rule: ResetRule? = nil,
                                  gapThreshold: TimeInterval = HistoryGaps.threshold)
    -> [QuotaConnector] {
        let drawable = drawablePoints(samples: samples, bucketID: bucketID, rule: rule,
                                      gapThreshold: gapThreshold)
        guard drawable.count > 1 else { return [] }

        // 采样序号 → 画出来的那个点。画不出点的采样不在表里。
        let pointBySample = Dictionary(uniqueKeysWithValues: drawable.map { ($0.index, $0.point) })
        let breaks = breakReasons(samples: samples, bucketID: bucketID,
                                  gapThreshold: gapThreshold, rule: rule)

        return breaks.keys.sorted().compactMap { index -> QuotaConnector? in
            guard index > 0, let reason = breaks[index],
                  let to = pointBySample[index]
            else { return nil }

            switch reason {
            case .gap:
                // 两端都得有实际画出来的点,否则这条虚线无处可连
                guard let from = pointBySample[index - 1] else { return nil }
                return QuotaConnector(from: from, to: to, reason: .gap)

            case .reset:
                guard let period = rule?.period(containing: samples[index].at),
                      period.start > samples[index - 1].at,
                      period.start <= samples[index].at
                else { return nil }

                let origin = QuotaPoint(at: period.start, remainingRatio: 1, series: to.series)
                // 边界时刻是不是推算的,跟着周期本身的可信度走
                return QuotaConnector(from: origin, to: to, reason: .reset,
                                      isBoundaryInferred: period.isInferred)
            }
        }
    }

    /// 断点位置 → 原因。键是**后一条**采样的下标。
    /// - Parameter rule: 该额度的重置规则。有它时,「周期 ID 变了」是**直接证据**;
    ///   没有它(或规则算不出周期)时,只能退回计数器下降这条补充证据。
    static func breakReasons(samples: [Sample],
                             bucketID: String,
                             gapThreshold: TimeInterval,
                             rule: ResetRule? = nil) -> [Int: BreakReason] {
        guard samples.count > 1 else { return [:] }

        var result: [Int: BreakReason] = [:]
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]

            // 重置优先于空档:跨过重置边界是**已知事实**,
            // 哪怕它夹在一段长空白里,也确切说明前后属于不同周期。
            // 既然知道是重置,就不该用虚线把两端连起来 —— 那会画成一条斜着爬升的假线。
            // 空白本身仍由阴影标出,信息没有丢。
            if crossedReset(from: previous, to: current, bucketID: bucketID, rule: rule) {
                result[index] = .reset
            } else if current.at.timeIntervalSince(previous.at) > gapThreshold {
                result[index] = .gap
            }
        }
        return result
    }

    /// 两条证据,任一成立即算跨过重置:
    ///
    /// · **周期 ID 变了** —— 直接证据。规则明确告诉我们边界在哪,
    ///   哪怕两侧用量恰好相同(比如整个周期都没用过),也照样能认出来。
    /// · **计数器下降** —— 补充证据。规则不知道的重置(管理员手动清零、
    ///   服务端改了配置)只剩它能看出来,所以不能因为有了规则就丢掉它。
    private static func crossedReset(from previous: Sample, to current: Sample,
                                     bucketID: String, rule: ResetRule?) -> Bool {
        if let rule,
           let before = rule.periodID(containing: previous.at),
           let after = rule.periodID(containing: current.at),
           before != after {
            return true
        }
        // 有一侧没有这条额度就**没有证据** —— 缺数据不等于计数器下降过。
        guard let before = previous.used(bucketID),
              let after = current.used(bucketID) else { return false }
        return after < before
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
