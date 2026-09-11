//
//  AlertPolicy.swift — 什么时候该发通知
//
//  难点不在「判断额度低」,而在**不骚扰**:
//  刷新每 60 秒一次,同一个条件会连续成立几十上百次。
//  去重键是「类型 + 额度 + 本轮重置周期」——
//  同一个周期内只提醒一次,跨过重置边界才允许再提醒。
//

import Foundation

public struct QuotaAlert: Equatable {

    public enum Kind: String, Equatable {
        case lowQuota   // 剩余额度不足
        case overPace   // 消费速度超前,会提前用完
    }

    public let kind: Kind
    public let quota: QuotaKind
    /// 本轮重置周期的起点。没有时间窗口的额度用当天零点,于是退化成「每天最多提醒一次」。
    public let cycleStart: Date
    public let remainingRatio: Double
    public let remaining: Double

    public init(kind: Kind, quota: QuotaKind, cycleStart: Date,
                remainingRatio: Double, remaining: Double) {
        self.kind = kind
        self.quota = quota
        self.cycleStart = cycleStart
        self.remainingRatio = remainingRatio
        self.remaining = remaining
    }

    public var dedupeKey: String {
        "\(kind.rawValue)|\(quota.rawValue)|\(Int(cycleStart.timeIntervalSince1970))"
    }
}

public enum AlertPolicy {

    /// 剩余低于这个比例就提醒
    public static let lowThreshold = QuotaThresholds.notifyLow      // 0.10

    /// 窗口刚开始时别提醒超速 —— 前几分钟用掉一点就判"超速"没有意义
    public static let minElapsedForPace = 0.25

    /// 剩余还很充裕时也别提醒超速,等消耗到一定程度再说
    public static let maxRemainingForPace = 0.60

    /// 当前**成立**的告警(还没去重)
    public static func candidates(for snapshot: Snapshot,
                                  now: Date,
                                  timeZone: TimeZone = .current,
                                  lowThreshold: Double = lowThreshold) -> [QuotaAlert] {
        snapshot.gauges.compactMap { gauge in
            guard !gauge.unlimited else { return nil }

            let cycleStart = gauge.window?.start ?? startOfDay(now, timeZone: timeZone)

            // 额度不足优先。此时不再叠加超速提醒 —— 两条说的是同一件事,
            // 而且"快用完了"比"用得偏快"更该被看到。
            if gauge.remainingRatio < lowThreshold {
                return QuotaAlert(kind: .lowQuota, quota: gauge.kind,
                                  cycleStart: cycleStart,
                                  remainingRatio: gauge.remainingRatio,
                                  remaining: gauge.remaining)
            }

            guard let window = gauge.window,
                  gauge.pace(now: now).isOverPace,
                  window.elapsedRatio(now: now) >= minElapsedForPace,
                  gauge.remainingRatio <= maxRemainingForPace
            else { return nil }

            return QuotaAlert(kind: .overPace, quota: gauge.kind,
                              cycleStart: window.start,
                              remainingRatio: gauge.remainingRatio,
                              remaining: gauge.remaining)
        }
    }

    /// 去掉本周期内已经发过的
    public static func newAlerts(for snapshot: Snapshot,
                                 now: Date,
                                 alreadySent: Set<String>,
                                 timeZone: TimeZone = .current,
                                 lowThreshold: Double = lowThreshold) -> [QuotaAlert] {
        candidates(for: snapshot, now: now, timeZone: timeZone, lowThreshold: lowThreshold)
            .filter { !alreadySent.contains($0.dedupeKey) }
    }

    private static func startOfDay(_ date: Date, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: date)
    }
}
