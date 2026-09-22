//
//  ChartSelection.swift — 指针停在图上时,选中什么、显示什么
//
//  这里只放**判定和内容**,不碰绘制。macOS 13 没有 chartXSelection,
//  指针事件和浮层定位得手写,那部分在 App 层;但「选中哪个点」「浮层里写什么」
//  是纯逻辑,放这儿才能测 —— 而它恰恰是最容易出错、也最容易悄悄撒谎的部分。
//
//  贯穿的一条规则:**只吸附到真实采样点,绝不插值**。
//  空档里没有数据,在那儿生成一个「实测值」就是凭空捏造。指针落在空档里时,
//  返回的仍是一个真实存在的点,并告知它不是指针所在处 ——
//  界面据此如实说明「这是最近的一次采样,时间是 …」。
//

import Foundation

// MARK: - 选点

public enum ChartSelection {

    /// 命中的曲线点
    public struct PointHit: Equatable {
        public let plotted: PlottedPoint

        /// 指针位置与这个点实际时刻的距离(秒,恒 >= 0)
        public let distance: TimeInterval

        public init(plotted: PlottedPoint, distance: TimeInterval) {
            self.plotted = plotted
            self.distance = distance
        }

        public var at: Date { plotted.point.at }
    }

    /// 离 `moment` 最近的那个点。
    ///
    /// 距离相等时取**较早**的那个 —— 重置边界上前后两点可能等距,
    /// 得有个确定的结果,否则同一个位置来回悬停会跳来跳去。
    public static func nearestPoint(to moment: Date, in points: [PlottedPoint]) -> PointHit? {
        var best: PointHit?
        for plotted in points {
            let distance = abs(plotted.point.at.timeIntervalSince(moment))
            // 严格小于:等距时保留先遇到的(即较早的)那个
            if best == nil || distance < best!.distance {
                best = PointHit(plotted: plotted, distance: distance)
            }
        }
        return best
    }

    /// `moment` 落在哪根柱子上。
    ///
    /// - Returns: 那一天**没有柱子就返回 nil**。缺失的一天不是「用了 0」——
    ///   显示成 0 等于宣称那天确实没用过,而我们只是没有数据。
    public static func bar(at moment: Date, in bars: [TokenBar],
                           timeZone: TimeZone = .current) -> TokenBar? {
        let key = DayKey.string(for: moment, timeZone: timeZone)
        return bars.first { DayKey.string(for: $0.day, timeZone: timeZone) == key }
    }
}

// MARK: - 额度曲线的浮层

/// 悬停在额度曲线上时要显示的内容。纯数据,排版是界面的事。
public struct QuotaTooltip: Equatable {

    /// 采样的**真实时刻**
    public let at: Date

    /// 指针并不在这个点上(落在两点之间,或落在空档里)。
    ///
    /// 为真时界面必须如实说明「这是最近一次采样」并给出它的真实时间,
    /// 否则用户会以为那就是指针位置处的值 —— 空档里根本没有值。
    public let isNearest: Bool

    /// 这条浮层说的是**哪个桶**。存 ID 而不是展示名 ——
    /// 展示名会随本地化和措辞变,拿它当身份对不回快照里的那条额度。
    public let bucketID: String

    /// 该点所属的重置周期。规则算不出就是 nil(滑动窗口、未知)。
    public let period: TimeWindow?

    public let remainingRatio: Double

    /// 剩余金额。历史点记了当时的上限才算得出。
    public let remainingAmount: Double?

    public init(at: Date, isNearest: Bool, bucketID: String,
                period: TimeWindow?, remainingRatio: Double, remainingAmount: Double?) {
        self.at = at
        self.isNearest = isNearest
        self.bucketID = bucketID
        self.period = period
        self.remainingRatio = remainingRatio
        self.remainingAmount = remainingAmount
    }
}

public extension QuotaTooltip {

    /// 从一次命中构造。
    ///
    /// 剩余金额用**采样当时的上限**算,不是当前上限 —— 和曲线用的是同一个口径,
    /// 否则浮层里的数字会和它指着的那个点对不上。
    init(hit: ChartSelection.PointHit, bucketID: String, rule: ResetRule?) {
        let sample = hit.plotted.sample
        let reading = sample.reading(bucketID)

        // 上限未知(nil)、当时不限额(0)、这次采样没有这条额度(reading 为 nil)——
        // 三种都算不出剩余金额,一律不给数字,而不是退回一个 0。
        let remainingAmount: Double? = reading.flatMap { reading in
            guard let limit = reading.limit, limit > 0 else { return nil }
            return max(limit - reading.used, 0)
        }

        self.init(at: hit.plotted.point.at,
                  // 距离为 0 才是「正好指着它」
                  isNearest: hit.distance > 0,
                  bucketID: bucketID,
                  period: rule?.period(containing: hit.plotted.point.at),
                  remainingRatio: hit.plotted.point.remainingRatio,
                  remainingAmount: remainingAmount)
    }
}

// MARK: - token 柱状图的浮层

public struct TokenTooltip: Equatable {

    /// 这根柱子涵盖的时间。
    ///
    /// 每日视图是一个自然日;按额度周期看时是一段起止 —— 两者必须分开表达,
    /// 因为「每天 14:35 重置」的周期横跨两个自然日,把它叫作某一天是错的。
    public enum Span: Equatable {
        case day(Date)
        case period(start: Date, end: Date)
    }

    public let span: Span

    /// 完整数量。界面要用 `Fmt.exact` 给准确值,不能只给 K/M/B 缩写。
    public let tokens: Double

    /// 请求数。**只在可信时给** —— 拿不准就是 nil,不填 0 充数。
    public let requests: Int?

    /// 这段时间里另有多少用量归不到具体某天(跨日界的那些,见 TokenAttribution)。
    /// 大于 0 时界面该说明一句,否则用户会以为柱子的高度就是全部。
    public let unattributedTokens: Double

    public init(span: Span, tokens: Double, requests: Int?, unattributedTokens: Double = 0) {
        self.span = span
        self.tokens = tokens
        self.requests = requests
        self.unattributedTokens = unattributedTokens
    }
}

public extension TokenTooltip {

    init(bar: TokenBar, unattributedTokens: Double = 0) {
        self.init(span: .day(bar.day),
                  // 请求数为 0 时无法区分「真的没有请求」和「接口没给」,
                  // 与其显示一个可能是假的 0,不如不显示
                  tokens: bar.tokens,
                  requests: bar.requests > 0 ? bar.requests : nil,
                  unattributedTokens: unattributedTokens)
    }
}

public extension TokenTooltip.Span {

    /// 这一段能不能如实叫作「某一天」。
    ///
    /// 只有正好从当地某日零点到次日零点才算。「每天 14:35 重置」的周期横跨两个自然日,
    /// 叫它「6 月 15 日」会让人以为它就是那一整天。
    func isWholeCalendarDay(in timeZone: TimeZone = .current) -> Bool {
        switch self {
        case .day:
            return true

        case let .period(start, end):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone

            guard calendar.startOfDay(for: start) == start,
                  let next = calendar.date(byAdding: .day, value: 1, to: start)
            else { return false }
            return next == end
        }
    }
}
