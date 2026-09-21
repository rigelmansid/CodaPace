//
//  Quota.swift — 额度、时间窗口与消费速度
//
//  这里是整个应用的核心概念:
//  不只看「用了多少」,而是把「剩余额度%」和「剩余时间%」放在一起比,
//  额度掉得比时间快就是「超速」—— 说明照这个速度会提前用完。
//

import Foundation

// MARK: - 时间窗口

/// 一个额度的重置周期。没有时间维度的额度(如账户总配额)不会有窗口。
public struct TimeWindow: Equatable {
    public let start: Date
    public let end: Date

    /// 重置时刻是本地推断的、而非接口明确给出的。
    /// 界面上要如实标注,不能让推断值看起来像精确值。
    public let isInferred: Bool

    public init(start: Date, end: Date, isInferred: Bool = false) {
        self.start = start
        self.end = end
        self.isInferred = isInferred
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public func remainingSeconds(now: Date) -> TimeInterval {
        max(0, end.timeIntervalSince(now))
    }

    /// 已过去的比例 0…1
    public func elapsedRatio(now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(now.timeIntervalSince(start) / duration, 0), 1)
    }

    /// 剩余时间比例 0…1
    public func remainingRatio(now: Date) -> Double {
        1 - elapsedRatio(now: now)
    }

    /// 这个时刻落在本周期里吗。右端开区间:走到 end 就已经是下一个周期了。
    ///
    /// 历史上某次重置发生在什么时刻,**不要**拿本窗口的秒数长度往回减 ——
    /// 那假定所有周期等长,而「每天当地 0 点」在夏令时切换日只有 23 小时。
    /// 该由 ResetRule.period(containing:) 按各自的规则算。
    public func contains(_ moment: Date) -> Bool {
        moment >= start && moment < end
    }
}

// MARK: - 额度种类

public enum QuotaKind: String, CaseIterable, Equatable {
    case total          // 账户总配额,无时间窗口
    case daily          // 每日
    case weeklyOpus     // 每周 Opus
    case window         // 限流窗口

    public func label(_ language: Language) -> String {
        switch self {
        case .total:      return L10n.text(.quotaTotal, language)
        case .daily:      return L10n.text(.quotaDaily, language)
        case .weeklyOpus: return L10n.text(.quotaWeeklyOpus, language)
        case .window:     return L10n.text(.quotaWindow, language)
        }
    }
}

// MARK: - 消费速度

public enum PaceVerdict: Equatable {
    /// 额度剩得比时间多 —— 按当前速度用得完
    case onPace(delta: Double)
    /// 额度掉得比时间快 —— 会提前用完
    case overPace(delta: Double)
    /// 没有时间窗口,或数据不足。**不做判断,也不猜。**
    case unavailable

    public func label(_ language: Language) -> String {
        switch self {
        case .onPace:      return L10n.text(.paceOnPace, language)
        case .overPace:    return L10n.text(.paceOverPace, language)
        case .unavailable: return ""
        }
    }

    /// 配色盲友好:状态必须有图标/文字,不能只靠颜色
    public var symbolName: String? {
        switch self {
        case .onPace:      return "checkmark.circle.fill"
        case .overPace:    return "exclamationmark.triangle.fill"
        case .unavailable: return nil
        }
    }

    public var isOverPace: Bool {
        if case .overPace = self { return true }
        return false
    }
}

// MARK: - 状态

public enum QuotaStatus: Equatable {
    case normal
    case warning     // 超速
    case critical    // 剩余不足
}

public enum QuotaThresholds {
    /// 剩余低于此比例 → 危险
    public static let critical = 0.20
    /// 通知用的更低一档
    public static let notifyLow = 0.10
}

// MARK: - 一条额度

public struct Gauge: Equatable {
    public let kind: QuotaKind
    public let used: Double
    public let limit: Double          // 0 表示不限
    public let window: TimeWindow?    // nil 表示没有时间维度

    /// 产生 window 的那条规则。历史图靠它按**各自的算法**反推过去的周期边界 ——
    /// 统一按秒数往回减会在夏令时切换日错位。没有规则时就不画重置虚线。
    public let rule: ResetRule?

    public init(kind: QuotaKind, used: Double, limit: Double,
                window: TimeWindow? = nil, rule: ResetRule? = nil) {
        self.kind = kind
        self.used = used
        self.limit = limit
        self.window = window
        self.rule = rule
    }

    public func label(_ language: Language) -> String { kind.label(language) }

    public var unlimited: Bool { limit <= 0 }

    /// 已用比例 0…1
    public var usedRatio: Double {
        guard !unlimited else { return 0 }
        return min(max(used / limit, 0), 1)
    }

    /// 剩余额度比例 0…1
    public var remainingRatio: Double { unlimited ? 1 : 1 - usedRatio }

    public var remaining: Double { unlimited ? 0 : max(limit - used, 0) }

    // MARK: 速度判断

    /// paceDelta = 剩余额度% − 剩余时间%
    /// >= 0 正常;< 0 超速。算不出就是 .unavailable —— 绝不臆造。
    ///
    /// **窗口必须包含此刻**。窗口一旦走完,剩余时间归零,于是任何还有余额的旧数据
    /// 都会算成「正常速度」—— 断网跨过重置时刻就是这个情形:那句「正常」
    /// 没有任何当期数据支撑,纯粹是过期窗口的算术副产品。
    /// 旧快照可以继续显示数字,但不该配一个它撑不起的判断。
    public func pace(now: Date) -> PaceVerdict {
        guard !unlimited, let window, window.duration > 0, window.contains(now)
        else { return .unavailable }

        let delta = remainingRatio - window.remainingRatio(now: now)
        return delta >= 0 ? .onPace(delta: delta) : .overPace(delta: delta)
    }

    /// 颜色优先级:剩余不足 > 超速 > 正常
    public func status(now: Date) -> QuotaStatus {
        guard !unlimited else { return .normal }
        if remainingRatio < QuotaThresholds.critical { return .critical }
        if pace(now: now).isOverPace { return .warning }
        return .normal
    }
}
