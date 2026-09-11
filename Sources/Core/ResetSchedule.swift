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

    /// 上面这个值是从历史观测来的(true),还是默认兜底的(false)
    public var dailyResetHourIsObserved: Bool

    public init(timeZone: TimeZone = .current,
                dailyResetHour: Int = 0,
                dailyResetHourIsObserved: Bool = false) {
        self.timeZone = timeZone
        self.dailyResetHour = dailyResetHour
        self.dailyResetHourIsObserved = dailyResetHourIsObserved
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    // MARK: - 限流窗口(精确)

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

        // 退路:现在 + 剩余秒数 = 结束,再往前推一个窗口长度
        if limits.rateLimitWindow > 0, limits.windowRemainingSeconds > 0 {
            let end = now.addingTimeInterval(TimeInterval(limits.windowRemainingSeconds))
            let start = end.addingTimeInterval(-TimeInterval(limits.rateLimitWindow * 60))
            return TimeWindow(start: start, end: end, isInferred: false)
        }

        return nil
    }

    // MARK: - 每周 Opus

    /// weeklyResetDay 用服务端 JS `getDay()` 的约定:0=周日 … 6=周六。
    /// Foundation 的 weekday 是 1=周日 … 7=周六,所以要 +1。
    public func weeklyInterval(limits: Limits, now: Date) -> TimeWindow? {
        let day = limits.weeklyResetDay
        let hour = limits.weeklyResetHour
        guard (0...6).contains(day), (0...23).contains(hour) else { return nil }

        var match = DateComponents()
        match.weekday = day + 1
        match.hour = hour
        match.minute = 0
        match.second = 0

        guard let start = previousOccurrence(of: match, atOrBefore: now),
              let end = calendar.date(byAdding: .day, value: 7, to: start)
        else { return nil }

        return TimeWindow(start: start, end: end, isInferred: false)
    }

    // MARK: - 每日(推断)

    public func dailyInterval(now: Date) -> TimeWindow? {
        var match = DateComponents()
        match.hour = dailyResetHour
        match.minute = 0
        match.second = 0

        guard let start = previousOccurrence(of: match, atOrBefore: now),
              let end = calendar.date(byAdding: .day, value: 1, to: start)
        else { return nil }

        // 观测到真实重置时刻之前,如实标记为推断值
        return TimeWindow(start: start, end: end, isInferred: !dailyResetHourIsObserved)
    }

    // MARK: - 私有

    /// 距 now 最近的一次匹配时刻(含 now 本身)
    private func previousOccurrence(of components: DateComponents, atOrBefore now: Date) -> Date? {
        // +1 秒再往回找,保证 now 恰好落在边界上时返回 now 而不是退一整个周期
        calendar.nextDate(after: now.addingTimeInterval(1),
                          matching: components,
                          matchingPolicy: .nextTime,
                          direction: .backward)
    }
}

// MARK: - 从历史里学习日重置时刻

public enum DailyResetLearner {

    public struct Observation: Equatable {
        /// 观测到的重置小时(0…23)
        public let hour: Int
        /// 相邻两次采样的间隔 —— 越小说明这个时刻定得越准
        public let uncertainty: TimeInterval
    }

    /// 日累计额度只会在一天之内单调上升,**一旦下降就说明跨过了重置边界**。
    /// 用后一条采样的小时数作为重置时刻;采样间隔就是这个判断的误差范围。
    ///
    /// 采样间隔过大时不予采信 —— 半小时前的一次下降,说不准发生在这半小时里的哪一刻。
    public static func observe(previous: (value: Double, at: Date),
                               current: (value: Double, at: Date),
                               timeZone: TimeZone,
                               maxUncertainty: TimeInterval = 300) -> Observation? {
        guard current.value < previous.value else { return nil }

        let gap = current.at.timeIntervalSince(previous.at)
        guard gap > 0, gap <= maxUncertainty else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // 重置发生在两次采样之间,取后一条所在的整点作为归属
        let hour = calendar.component(.hour, from: current.at)
        return Observation(hour: hour, uncertainty: gap)
    }
}
