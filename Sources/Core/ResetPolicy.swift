//
//  ResetPolicy.swift — 额度怎么重置
//
//  核心区分:**日历规则**和**固定时长**不是一回事,夏令时切换那天会分道扬镳。
//
//    · 每天当地 0 点重置 —— 日历规则。纽约 2026-03-08 那天只有 23 小时,
//      但它照样是「一天」,下一次重置仍在当地 0 点。
//    · 每隔 24 小时重置 —— 固定时长。同一天里它会在当地 1 点到期,而不是 0 点。
//
//  旧实现只有一种算法:拿当前窗口的秒数长度反复往回减。对限流窗口这类
//  确实按秒计的周期是对的,对「每天 0 点」则会在夏令时切换日整体错位一小时 ——
//  于是历史图上那条重置虚线要么起点错了,要么被有效性检查直接丢掉。
//
//  所以把「怎么重置」显式表达出来,让每种规则各用各的算法。
//

import Foundation

// MARK: - 来源

/// 这条规则是**怎么来的**。决定可信度,也决定界面要不要标注「推算」。
///
/// 顺序即优先级:服务端明确数据 > 已验证的协议或用户配置 > 历史观测 > 默认假设 > 未知。
public enum ResetProvenance: String, Equatable, Comparable {

    /// 服务端明确给出的时刻
    case server

    /// 已验证的供应商协议,或用户自己配置的
    case configured

    /// 从历史里**真实观测到**的重置事件(计数器归零的那一刻)
    case observed

    /// 按默认假设推算的,比如「先当作本地零点」
    case inferred

    /// 还定不下来
    case unknown

    private var rank: Int {
        switch self {
        case .server:     return 0
        case .configured: return 1
        case .observed:   return 2
        case .inferred:   return 3
        case .unknown:    return 4
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }

    /// 这个时刻算不算「确定的」。
    /// 观测到的重置事件算确定 —— 那是发生过的事实,不是假设;
    /// 只有默认假设和未知才该在界面上标注「推算」。
    public var isCertain: Bool { self <= .observed }
}

// MARK: - 规则

public enum ResetPolicy: Equatable {

    /// 服务端直接给出的一段起止。**不往外推** ——
    /// 对方只说了这一段,它之前之后怎么排我们并不知道。
    case serverProvided(start: Date, end: Date)

    /// 每天在指定时区的 hour:minute 重置。用日历算,跨夏令时仍落在当地同一时刻。
    case calendarDaily(timeZone: TimeZone, hour: Int, minute: Int)

    /// 每周。weekday 用 Foundation 约定:1=周日 … 7=周六。
    case calendarWeekly(timeZone: TimeZone, weekday: Int, hour: Int, minute: Int)

    /// 从锚点起每隔固定秒数。**不受夏令时影响** —— 它数的是绝对时间。
    case fixedDuration(anchor: Date, seconds: TimeInterval)

    /// 订阅周年:每个自然月的某一天。用日历算,月份长短不一。
    case subscriptionAnniversary(timeZone: TimeZone, day: Int, hour: Int, minute: Int)

    /// 最近一段时间的滑动统计,**没有统一的归零时刻**。
    /// 不能套用「距离归零还有多久」,更不能套 pace 公式。
    case rollingWindow(seconds: TimeInterval)

    /// 还不知道怎么重置
    case unknown

    /// 周期 ID 的前缀,用来保证不同规则算出的同一时刻不会撞成同一个周期
    fileprivate var tag: String {
        switch self {
        case .serverProvided:          return "server"
        case .calendarDaily:           return "daily"
        case .calendarWeekly:          return "weekly"
        case .fixedDuration:           return "fixed"
        case .subscriptionAnniversary: return "month"
        case .rollingWindow:           return "rolling"
        case .unknown:                 return "unknown"
        }
    }
}

// MARK: - 规则 + 来源

public struct ResetRule: Equatable {

    public let policy: ResetPolicy
    public let provenance: ResetProvenance

    public init(_ policy: ResetPolicy, provenance: ResetProvenance) {
        self.policy = policy
        self.provenance = provenance
    }

    public static let unknown = ResetRule(.unknown, provenance: .unknown)

    /// 算不算得出周期。滑动窗口和未知都算不出 —— 调用方据此不显示倒计时、不给 pace。
    public var hasPeriods: Bool {
        switch policy {
        case .rollingWindow, .unknown: return false
        default: return true
        }
    }

    /// 包含 `moment` 的那个周期。
    ///
    /// - Returns: nil 表示**算不出来**,不是「零长度」。绝不返回一个编出来的区间 ——
    ///   那会在界面上变成一个看着很确定的倒计时。
    public func period(containing moment: Date) -> TimeWindow? {
        guard let (start, end) = bounds(containing: moment), end > start else { return nil }
        return TimeWindow(start: start, end: end, isInferred: !provenance.isCertain)
    }

    /// 周期的稳定标识。同一个周期无论什么时候算都得到同一个 ID ——
    /// 历史按周期分段、告警按周期去重都靠它。
    public func periodID(containing moment: Date) -> String? {
        guard let window = period(containing: moment) else { return nil }
        return "\(policy.tag)|\(Int(window.start.timeIntervalSince1970))"
    }

    // MARK: 各自的算法

    private func bounds(containing moment: Date) -> (Date, Date)? {
        switch policy {

        case let .serverProvided(start, end):
            // 只认这一段。moment 落在别处就是不知道,不往外推。
            guard moment >= start, moment < end else { return nil }
            return (start, end)

        case let .calendarDaily(timeZone, hour, minute):
            return calendarBounds(timeZone: timeZone,
                                  match: DateComponents(hour: hour, minute: minute, second: 0),
                                  step: .day, value: 1, containing: moment)

        case let .calendarWeekly(timeZone, weekday, hour, minute):
            guard (1...7).contains(weekday) else { return nil }
            return calendarBounds(timeZone: timeZone,
                                  match: DateComponents(hour: hour, minute: minute, second: 0,
                                                        weekday: weekday),
                                  step: .day, value: 7, containing: moment)

        case let .fixedDuration(anchor, seconds):
            // 纯秒数运算:往前往后都能推,而且不受夏令时影响 —— 它本来数的就是绝对时间
            guard seconds > 0 else { return nil }
            let elapsed = moment.timeIntervalSince(anchor)
            let index = (elapsed / seconds).rounded(.down)
            let start = anchor.addingTimeInterval(index * seconds)
            return (start, start.addingTimeInterval(seconds))

        case let .subscriptionAnniversary(timeZone, day, hour, minute):
            return anniversaryBounds(timeZone: timeZone, day: day,
                                     hour: hour, minute: minute, containing: moment)

        case .rollingWindow, .unknown:
            // 没有统一的归零时刻 —— 如实返回「算不出」
            return nil
        }
    }

    /// 日历规则的通用算法:往回找最近一次匹配,再按**日历**加一个周期。
    /// 用日历加而不是加秒数,夏令时切换日才会得到 23 或 25 小时的那一天。
    private func calendarBounds(timeZone: TimeZone, match: DateComponents,
                                step: Calendar.Component, value: Int,
                                containing moment: Date) -> (Date, Date)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // +1 秒再往回找,保证 moment 恰好落在边界上时返回它自己而不是退一整个周期
        guard let start = calendar.nextDate(after: moment.addingTimeInterval(1),
                                            matching: match,
                                            matchingPolicy: .nextTime,
                                            direction: .backward),
              let end = calendar.date(byAdding: step, value: value, to: start)
        else { return nil }

        return (start, end)
    }

    /// 订阅周年:落在哪个「订阅月」里。
    ///
    /// 月份长短不一,所以 day 要夹到当月的天数上 —— 31 号的订阅在 2 月只能落在月末。
    /// 这个夹取方式是本实现的选择;供应商若另有定义,应以对方的为准。
    private func anniversaryBounds(timeZone: TimeZone, day: Int, hour: Int, minute: Int,
                                   containing moment: Date) -> (Date, Date)? {
        guard (1...31).contains(day) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        func occurrence(monthsFromMomentMonth offset: Int) -> Date? {
            let base = calendar.dateComponents([.year, .month], from: moment)
            guard let monthStart = calendar.date(from: base),
                  let shifted = calendar.date(byAdding: .month, value: offset, to: monthStart),
                  let range = calendar.range(of: .day, in: .month, for: shifted)
            else { return nil }

            var c = calendar.dateComponents([.year, .month], from: shifted)
            c.day = min(day, range.count)      // 夹到当月月末
            c.hour = hour
            c.minute = minute
            c.second = 0
            return calendar.date(from: c)
        }

        guard let thisMonth = occurrence(monthsFromMomentMonth: 0) else { return nil }

        if thisMonth <= moment {
            guard let next = occurrence(monthsFromMomentMonth: 1) else { return nil }
            return (thisMonth, next)
        }
        guard let previous = occurrence(monthsFromMomentMonth: -1) else { return nil }
        return (previous, thisMonth)
    }
}
