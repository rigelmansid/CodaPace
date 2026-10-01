//
//  ResetSchedule.swift — 各额度的重置周期推算
//
//  接口给出的时间信息有三个层次,可信度依次递减:
//    1. 限流窗口:直接给了 windowStartTime / windowEndTime —— 精确
//    2. 每周 Opus:给了 weeklyResetDay / weeklyResetHour —— 需按时区还原,准确
//    3. 每日:接口**没有**任何日重置字段 —— 只能推断
//
//  对第 3 种的处理:先用「本地 0 点」兜底,同时从历史里观测真实的重置时刻
//  (日计数器归零的那一刻),观测到之后就用观测值,并在界面上不再标注为推断。
//

import Foundation

public struct ResetSchedule {

    /// 服务端重置所依据的时区。默认跟随本机 —— 用户与中转站通常在同一时区。
    public var timeZone: TimeZone

    /// 日额度重置的小时数(0…23)
    public var dailyResetHour: Int

    /// 日额度重置的分钟数(0…59)。半小时时区(印度 +5:30、尼泊尔 +5:45)下,
    /// 服务端的 UTC 0 点落在当地的半点上 —— 只有小时会差出半小时(OPT-025)
    public var dailyResetMinute: Int

    /// 上面这个值是从历史观测来的(true),还是默认兜底的(false)
    public var dailyResetHourIsObserved: Bool

    public init(timeZone: TimeZone = .current,
                dailyResetHour: Int = 0,
                dailyResetMinute: Int = 0,
                dailyResetHourIsObserved: Bool = false) {
        self.timeZone = timeZone
        self.dailyResetHour = dailyResetHour
        self.dailyResetMinute = dailyResetMinute
        self.dailyResetHourIsObserved = dailyResetHourIsObserved
    }

    // MARK: - 限流窗口(精确)

    /// 限流窗口**怎么重复**。按绝对秒数循环,所以是固定时长而非日历规则 ——
    /// 它不该受夏令时影响。只给历史图反推过去的周期边界用。
    ///
    /// 注意它和 `windowInterval` 的分工:那个给的是「服务端说的这一段」,
    /// 过期了就该让 pace 变成不可判断(见 Gauge.pace),**不能**拿这条规则外推出
    /// 一个包含此刻的新周期 —— 那会把上一个周期的用量安到新周期头上。
    public func windowRule(limits: Limits, now: Date) -> ResetRule? {
        guard let current = windowInterval(limits: limits, now: now),
              current.duration > 0
        else { return nil }

        return ResetRule(.fixedDuration(anchor: current.start, seconds: current.duration),
                         provenance: .server)
    }

    /// 优先用接口给的起止时间戳;缺失时退回「剩余秒数 + 窗口长度」反推。
    /// 两者都没有就返回 nil —— 上层据此不显示 pace。
    public func windowInterval(limits: Limits, now: Date) -> TimeWindow? {
        // 毫秒时间戳
        if limits.windowStartTime > 0, limits.windowEndTime > limits.windowStartTime {
            return TimeWindow(
                start: Date(timeIntervalSince1970: limits.windowStartTime / 1000),
                end: Date(timeIntervalSince1970: limits.windowEndTime / 1000),
                isInferred: false
            )
        }

        // 退路:现在 + 剩余秒数 = 结束,再往前推一个窗口长度。
        //
        // 结束时刻**取整到分钟**(OPT-026)。`now` 带小数,又和服务端算剩余秒数的时刻差着
        // 一点网络延迟,于是每次刷新反推出的起点都差一两秒 —— 而告警去重键和历史周期 ID
        // 都拿起点当周期的身份:同一个窗口里低额度告警几乎每分钟重发一次。
        // 剩余时间因此最多差 30 秒,对小时级的窗口无关紧要
        if limits.rateLimitWindow > 0, limits.windowRemainingSeconds > 0 {
            let raw = now.timeIntervalSince1970 + TimeInterval(limits.windowRemainingSeconds)
            let end = Date(timeIntervalSince1970: (raw / 60).rounded() * 60)
            let start = end.addingTimeInterval(-TimeInterval(limits.rateLimitWindow * 60))
            return TimeWindow(start: start, end: end, isInferred: false)
        }

        return nil
    }

    // MARK: - 每周 Opus

    /// weeklyResetDay 用服务端 JS `getDay()` 的约定:0=周日 … 6=周六。
    /// Foundation 的 weekday 是 1=周日 … 7=周六,所以要 +1。
    public func weeklyRule(limits: Limits) -> ResetRule? {
        let day = limits.weeklyResetDay
        let hour = limits.weeklyResetHour
        guard (0...6).contains(day), (0...23).contains(hour) else { return nil }

        return ResetRule(.calendarWeekly(timeZone: timeZone,
                                         weekday: day + 1,     // getDay() → Foundation
                                         hour: hour, minute: 0),
                         provenance: .server)
    }

    public func weeklyInterval(limits: Limits, now: Date) -> TimeWindow? {
        weeklyRule(limits: limits)?.period(containing: now)
    }

    // MARK: - 每日(推断)

    /// 日重置是**日历规则**,不是每隔 86400 秒 —— 夏令时切换日只有 23 小时,
    /// 但下一次重置仍在当地同一时刻。
    public func dailyRule() -> ResetRule {
        ResetRule(.calendarDaily(timeZone: timeZone, hour: dailyResetHour, minute: dailyResetMinute),
                  // 观测到过真实的归零事件才算确定,否则只是「先当作这个点」
                  provenance: dailyResetHourIsObserved ? .observed : .inferred)
    }

    public func dailyInterval(now: Date) -> TimeWindow? {
        dailyRule().period(containing: now)
    }

}

// MARK: - 学到的日重置规则

/// 观测得出的日重置时刻,**连同它成立的前提一起保存**。
///
/// 只存一个小时数是不够的。本地小时脱离时区没有意义 —— 用户从上海搬到纽约以后,
/// 「0 点重置」这个结论不再指向同一个瞬间,可它看上去依然像个确定值,
/// 于是倒计时和 pace 会一起错,而界面上却不再标注「推算」。
/// 所以时区是结论的一部分:前提变了就该作废重学。
public struct LearnedDailyReset: Equatable {

    /// 观测到的重置小时(0…23)
    public let hour: Int

    /// 观测到的重置分钟,对齐到 15 分钟(OPT-025)。这一项加上之前学到的结论没有它,按 0 读
    public let minute: Int

    /// 学到它时所在时区的标识符
    public let timeZoneIdentifier: String

    /// 当时那次观测的误差范围(相邻采样间隔),越小越准
    public let uncertainty: TimeInterval

    public init(hour: Int, minute: Int = 0, timeZoneIdentifier: String, uncertainty: TimeInterval) {
        self.hour = hour
        self.minute = minute
        self.timeZoneIdentifier = timeZoneIdentifier
        self.uncertainty = uncertainty
    }

    /// 这条结论在给定时区下还成立吗
    public func applies(in timeZone: TimeZone) -> Bool {
        timeZoneIdentifier == timeZone.identifier
    }
}

// MARK: - 从历史里学习日重置时刻

public enum DailyResetLearner {

    public struct Observation: Equatable {
        /// 观测到的重置小时(0…23)
        public let hour: Int
        /// 观测到的重置分钟,对齐到 15 分钟
        public let minute: Int
        /// 相邻两次采样的间隔 —— 越小说明这个时刻定得越准
        public let uncertainty: TimeInterval
    }

    /// 日累计额度只会在一天之内单调上升,**一旦下降就说明跨过了重置边界**。
    /// 用后一条采样的小时数作为重置时刻;采样间隔就是这个判断的误差范围。
    ///
    /// 采样间隔过大时不予采信 —— 半小时前的一次下降,说不准发生在这半小时里的哪一刻。
    ///
    /// **只认像归零的下降**(OPT-025):降到前值的一半以下。服务端一次小幅冲正
    /// (`3.20 → 3.19`)也是下降,从前照收,于是重置时刻被改到冲正发生的那一点,
    /// 还标成「已观测」。真的重置后几分钟内又花掉一半以上的情况极少,漏掉也只是晚一天学到。
    public static func observe(previous: (value: Double, at: Date),
                               current: (value: Double, at: Date),
                               timeZone: TimeZone,
                               maxUncertainty: TimeInterval = 300) -> Observation? {
        guard current.value < previous.value, current.value <= previous.value / 2 else { return nil }

        let gap = current.at.timeIntervalSince(previous.at)
        guard gap > 0, gap <= maxUncertainty else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // 重置发生在两次采样之间,取后一条所在的时刻,分钟**往下对齐到 15 分钟**(OPT-025)。
        // 从前只取整点:印度时区里 UTC 0 点的重置被学成 05:00,比真实早半小时,
        // 那半小时里面板套着新周期显示旧用量,低额度告警还会提前占掉当天的去重键。
        // 采样间隔最多 5 分钟,对齐到刻钟足以吸收这点误差,又不会把 :30 / :45 抹掉
        let parts = calendar.dateComponents([.hour, .minute], from: current.at)
        return Observation(hour: parts.hour ?? 0,
                           minute: (parts.minute ?? 0) / 15 * 15,
                           uncertainty: gap)
    }

    /// 一条新观测应该把已有结论改成什么。
    ///
    /// - Returns: 要写回的新结论;**nil 表示保持原样**,连盘都不用写。
    ///
    /// 规则:
    /// · 还没有结论 → 采纳。
    /// · 时区变了 → 采纳新的。旧结论的前提已经不成立,留着只会算出错的倒计时。
    /// · 时刻(时 + 分)相同 → 不动。否则每天重置一次就重复写一遍同样的值。
    /// · 时刻不同 → **采纳新的**。计数器归零是个没有歧义的事件:它现在发生在 14 点,
    ///   那重置时刻现在就是 14 点 —— 中转站改配置、用户换套餐都会这样。
    ///   固守旧值等于拿上个月的证据否决眼前的观测。
    ///
    /// 从前这里根本没有「更新」这回事:学到一次就封存,错了也一直错下去。
    public static func reconcile(stored: LearnedDailyReset?,
                                 observation: Observation,
                                 timeZone: TimeZone) -> LearnedDailyReset? {
        let fresh = LearnedDailyReset(hour: observation.hour,
                                      minute: observation.minute,
                                      timeZoneIdentifier: timeZone.identifier,
                                      uncertainty: observation.uncertainty)

        guard let stored, stored.applies(in: timeZone) else { return fresh }
        let same = stored.hour == observation.hour && stored.minute == observation.minute
        return same ? nil : fresh
    }
}
