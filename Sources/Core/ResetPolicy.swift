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
            return calendarBounds(timeZone: timeZone, weekday: nil,
                                  hour: hour, minute: minute, containing: moment)

        case let .calendarWeekly(timeZone, weekday, hour, minute):
            guard (1...7).contains(weekday) else { return nil }
            return calendarBounds(timeZone: timeZone, weekday: weekday,
                                  hour: hour, minute: minute, containing: moment)

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

    /// 日历规则的通用算法:把 moment 前后几天里每一次「当地 hour:minute」换算成瞬间,
    /// 最晚的不晚于 moment 的那个作起点,最早的晚于 moment 的那个作终点。
    /// 两头都按日历来,夏令时切换日才会得到 23 或 25 小时的那一天。
    ///
    /// 终点曾经是「起点 + 一天(一周)」(OPT-023):重置时刻落在春季跳过的那一小时里
    /// (纽约 3/8 的 02:30)时,起点被挪到 03:00,加一天成了 3/9 03:00,而 3/9 的 02:30
    /// 真实存在 —— 两个周期重叠半小时。所以终点也得回到规则本身去找。
    ///
    /// 之后两头都交给 `Calendar.nextDate(matching:)` 去找,它在夏令时附近会找错,
    /// 而且错得不显眼(OPT-036,全部时区逐分钟对照比出来的,见坑 14):
    /// · 半小时夏令时(Australia/Lord_Howe):切换那天的 02:00 不存在,往回、往前找都会
    ///   跳过这一天,返回一个已经结束的周期,或一个 48 小时长的周期;
    /// · 秋季重复的那一小时(纽约的 01:30、欧洲的 02:30 ……几乎所有夏令时区):从第二次
    ///   01:30 之后往回找,起点落在第二次上,而前一个周期的终点是第一次 —— 同一天里
    ///   周期 ID 变了一次,图上多出一次重置,低额度告警的去重键跟着变,同一天提醒两遍。
    ///
    /// 现在不让 Foundation 去「匹配」,每一天的边界自己换算(`instant(ofWallClock:in:)`):
    /// 当地日期的加减放在没有夏令时的 GMT 里做,换算只用时区的偏移。语义和从前一样 ——
    /// 跳过的时刻取跳过之后的第一刻(即 `.nextTime`),重复的时刻取第一次。
    private func calendarBounds(timeZone: TimeZone, weekday: Int?, hour: Int, minute: Int,
                                containing moment: Date) -> (Date, Date)? {
        // 从前非法的时、分由 nextDate 匹配不上而返回 nil;现在要自己挡,不然 25 点会被换算成次日 1 点
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }

        // moment 那一刻当地钟面上的时刻,按 GMT 记成秒数:在这个表示里一天恒为 86400 秒
        let wall = moment.timeIntervalSince1970 + TimeInterval(timeZone.secondsFromGMT(for: moment))
        let today = (wall / 86_400).rounded(.down) * 86_400
        let timeOfDay = TimeInterval(hour * 3600 + minute * 60)

        // 只拿来问「某天是星期几」。GMT 没有夏令时,和上面的表示对得上
        var gmt = Calendar(identifier: .gregorian)
        gmt.timeZone = TimeZone(secondsFromGMT: 0)!

        // 前后各看两天(周规则八天):够盖住起点在前一天、终点在后一天,
        // 以及跳过的时段把边界挪过午夜的情形
        let reach = weekday == nil ? 2 : 8
        var boundaries: [Date] = []
        for dayOffset in -reach...reach {
            let day = today + TimeInterval(dayOffset) * 86_400
            if let weekday, gmt.component(.weekday, from: Date(timeIntervalSince1970: day)) != weekday {
                continue
            }
            boundaries.append(Self.instant(ofWallClock: day + timeOfDay, in: timeZone))
        }

        // 恰好落在边界上的 moment 属于新周期;边界前不到一秒(23:59:59.5)仍是旧周期
        guard let start = boundaries.last(where: { $0 <= moment }),
              let end = boundaries.first(where: { $0 > moment })
        else { return nil }
        return (start, end)
    }

    /// 钟面时刻 → 瞬间。`wall` 是当地钟面上的那个时刻按 GMT 记的秒数(整秒)。
    ///
    /// 钟面 = 瞬间 + 偏移,偏移只在切换那一刻跳一下。所以看 `wall` 前后 26 小时
    /// (任何时区的偏移都在 ±14 小时以内)两头的偏移:相同就是平常日子,减掉偏移即可;
    /// 不同就二分出切换的那一秒(切换总在整秒上),再分三种:
    /// · 切换之前就走到了这个钟面 —— 含秋季重复时段的**第一次**;
    /// · 钟面落在春季跳过的那一段 —— 取切换那一刻,即跳过之后的第一刻;
    /// · 切换之后才走到。
    ///
    /// 前提是 52 小时里最多切换一次。2026-11-10 扫过全部时区 1970–2037 年的切换,
    /// 最近的两次也隔了 60 小时以上。
    static func instant(ofWallClock wall: TimeInterval, in timeZone: TimeZone) -> Date {
        func offset(at instant: TimeInterval) -> TimeInterval {
            TimeInterval(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: instant)))
        }

        let reach: TimeInterval = 26 * 3600
        var before = wall - reach, after = wall + reach
        let offsetBefore = offset(at: before), offsetAfter = offset(at: after)
        guard offsetBefore != offsetAfter else {
            return Date(timeIntervalSince1970: wall - offsetBefore)
        }

        // 收到相邻两秒为止:before 还是旧偏移,after 是第一个用新偏移的那一秒
        while after - before > 1 {
            let middle = ((before + after) / 2).rounded(.down)
            if offset(at: middle) == offsetBefore { before = middle } else { after = middle }
        }
        let transition = after

        let early = wall - offsetBefore
        if early < transition { return Date(timeIntervalSince1970: early) }
        return Date(timeIntervalSince1970: max(transition, wall - offsetAfter))
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
