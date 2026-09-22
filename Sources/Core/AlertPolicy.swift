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

    /// 哪条额度。存的是**额度桶 ID**(EXT-001),从前是固定枚举。
    ///
    /// 中转站那四个 ID 的取值等于旧枚举的 rawValue,所以去重键的形状一字没变 ——
    /// 升级之后当前周期里已经发过的告警**不会被重发一遍**。
    public let bucketID: String

    /// 额度名与计量单位,**随告警一起带走**。
    ///
    /// 不在投递时回头按 ID 去当前快照里查:投递要等权限和系统回执,期间快照
    /// 完全可能已经换了一份(甚至换了账户)。那时查到的名字和单位属于另一份数据,
    /// 而通知说的是**发起告警那一刻**的事。单位尤其不能少 —— 少了它就只能
    /// 拿 `Fmt.money2` 打出 `$`,而那正是「凭空安一个币种」。
    public let title: BucketTitle
    public let unit: QuotaUnit

    /// 本轮重置周期的起点。没有时间窗口的额度用当天零点,于是退化成「每天最多提醒一次」。
    public let cycleStart: Date
    public let remainingRatio: Double
    public let remaining: Double

    public init(kind: Kind, bucketID: String,
                title: BucketTitle, unit: QuotaUnit,
                cycleStart: Date, remainingRatio: Double, remaining: Double) {
        self.kind = kind
        self.bucketID = bucketID
        self.title = title
        self.unit = unit
        self.cycleStart = cycleStart
        self.remainingRatio = remainingRatio
        self.remaining = remaining
    }

    public var dedupeKey: String {
        "\(kind.rawValue)|\(bucketID)|\(Int(cycleStart.timeIntervalSince1970))"
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
                return QuotaAlert(kind: .lowQuota, bucketID: gauge.id,
                                  title: gauge.title, unit: gauge.unit,
                                  cycleStart: cycleStart,
                                  remainingRatio: gauge.remainingRatio,
                                  remaining: gauge.remaining)
            }

            guard let window = gauge.window,
                  gauge.pace(now: now).isOverPace,
                  window.elapsedRatio(now: now) >= minElapsedForPace,
                  gauge.remainingRatio <= maxRemainingForPace
            else { return nil }

            return QuotaAlert(kind: .overPace, bucketID: gauge.id,
                              title: gauge.title, unit: gauge.unit,
                              cycleStart: window.start,
                              remainingRatio: gauge.remainingRatio,
                              remaining: gauge.remaining)
        }
    }

    private static func startOfDay(_ date: Date, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: date)
    }
}

// MARK: - 已发送账本

/// 哪些告警已经发过了。
///
/// 两件事从前都没做对:
///
/// · **账本不分账户** —— A 在某周期收到低额度通知后切到 B,B 的同类告警会被当成
///   "已经发过"而静默掉。命名空间解决这个。
/// · **还没送出去就记账** —— 权限被拒、系统拒收,都照样写进"已发过",
///   于是这一整个周期内再也不会重试。只有系统**确实接受**了才记。
///
/// 还要挡住第三种情况:提交是异步的,期间下一次刷新会算出同一条告警。
/// `delivering` 记下正在途中的,避免重复提交 —— 它只活在内存里,不该持久化。
public struct AlertLedger: Equatable {

    /// 最多留多少条。周期键随时间单调增长,不裁剪会无限膨胀。
    public static let capacity = 200

    /// 这本账属于哪个账户
    public let namespace: String

    /// 已成功提交的键,旧的在前 —— 有序是为了裁剪时丢最旧的那些
    private var sent: [String]

    /// 正在提交途中的键。**不持久化**:进程没了,途中的提交也就没了。
    private var delivering: Set<String>

    public init(namespace: String, sent: [String] = []) {
        self.namespace = namespace
        self.sent = Array(sent.suffix(Self.capacity))
        self.delivering = []
    }

    /// 要落盘的内容
    public var storedKeys: [String] { sent }

    /// 账本里的完整键。命名空间在这里拼上,`QuotaAlert.dedupeKey` 本身不掺账户。
    public func key(for alert: QuotaAlert) -> String {
        "\(namespace)|\(alert.dedupeKey)"
    }

    /// 还该不该发:既没发过,也不在提交途中
    public func isPending(_ alert: QuotaAlert) -> Bool {
        let k = key(for: alert)
        return !sent.contains(k) && !delivering.contains(k)
    }

    /// 占住这一条,准备去提交。返回 false 表示不必再提交了。
    public mutating func beginDelivery(_ alert: QuotaAlert) -> Bool {
        guard isPending(alert) else { return false }
        delivering.insert(key(for: alert))
        return true
    }

    /// 系统确实收下了 —— 到这一步才算发过
    public mutating func confirm(_ alert: QuotaAlert) {
        let k = key(for: alert)
        delivering.remove(k)
        guard !sent.contains(k) else { return }
        sent = Array((sent + [k]).suffix(Self.capacity))
    }

    /// 被拒、提交失败或放弃 —— **不留记录**,同周期内下次刷新还能重试
    public mutating func abandon(_ alert: QuotaAlert) {
        delivering.remove(key(for: alert))
    }

    /// 用户在设置里重新打开通知时清账,好让当前周期能再提醒一次
    public mutating func clear() {
        sent = []
        delivering = []
    }
}
