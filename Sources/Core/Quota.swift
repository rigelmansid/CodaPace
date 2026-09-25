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

    /// 快到重置了:剩余时间不足 `QuotaThresholds.nearingReset`。
    ///
    /// 菜单栏的时间环 / 时间条和面板的「剩余时间」条都靠它变蓝色,平时和额度正常态一样。
    /// 意思是「额度还剩很多就抓紧用;已经在等重置的话,快到了」。两处共用这一个判断,
    /// 不各自比一遍比例(不变量 5)。零长度窗口 remainingRatio 恒为 1,不会误亮。
    public func isNearingReset(now: Date) -> Bool {
        remainingRatio(now: now) < QuotaThresholds.nearingReset
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

// MARK: - 计量单位

/// 这条额度按什么计量。
///
/// 存在的理由很具体:tu-zi 的 `daily_used` **没有任何单位标记**,而同一份响应里
/// `fuel_pack.available_usd` 明确带了 `_usd`。把前者也当美元打成 `$29.22`,
/// 就是凭空给一个我们并不知道单位的数字安一个币种 —— 正是「不发明数据」禁止的事。
///
/// 所以单位是**供应商声明的事实**:声明得出就带上,声明不出就是 `.unknown`,
/// 界面显示裸数字。这比默认美元诚实,也比隐藏整条额度有用。
public enum QuotaUnit: Equatable {
    case money(currency: String)
    case tokens
    case requests
    /// 对方没说单位。显示裸数字,不加任何符号。
    case unknown

    /// 按本单位把一个量排成文字。
    public func amount(_ value: Double) -> String {
        switch self {
        case .money(let currency):
            // 非美元只给「数字 + 币种代码」,不猜符号 ——
            // €/£/¥ 各有各的位置和空格习惯,猜错比不猜更难看。
            return currency == "USD" ? Fmt.money2(value) : "\(Fmt.decimal2(value)) \(currency)"
        case .tokens, .requests:
            return Fmt.exact(value)
        case .unknown:
            return Fmt.decimal2(value)
        }
    }

    /// 菜单栏用的紧凑写法。那里空间按像素算,千分位和两位小数都是奢侈品。
    public func compactAmount(_ value: Double) -> String {
        switch self {
        case .money(let currency):
            return currency == "USD" ? Fmt.money(value) : "\(Fmt.count(value)) \(currency)"
        case .tokens, .requests:
            return Fmt.count(value)
        case .unknown:
            return Fmt.count(value)
        }
    }
}

// MARK: - 额度名称

/// 这条额度叫什么。
///
/// 两态是刻意的:能对上我们已有语义的(每日、限流窗口)用本地化名;对不上的
/// **原样用供应商自己的名字**。tu-zi 的 `"Codex(月卡mini)"` 是一个套餐名,
/// 我们的词汇表里没有对应概念,硬塞进「本周 Opus」之类只会让界面说出一件不是事实的事。
public enum BucketTitle: Equatable {
    case localized(LangKey)
    case provider(String)

    public func text(_ language: Language) -> String {
        switch self {
        case .localized(let key): return L10n.text(key, language)
        case .provider(let name): return name
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
    /// 剩余**时间**低于此比例 → 快到重置。和 `critical` 同值但是两件事,
    /// 哪天想单独调其中一个不该牵动另一个。
    public static let nearingReset = 0.20

    /// 周期短于这个长度就算「高频窗口」,菜单栏自动选择会避开它。
    ///
    /// 取 6 小时是为了把「限流窗口」这类一小时一轮的和「每日」清楚分开,
    /// 中间留足余量。定成一个阈值而不是记住某条额度的名字,是为了让
    /// 新供应商的 15 分钟窗口自动落进同一条规则。
    public static let volatileWindow: TimeInterval = 6 * 3600
}

// MARK: - 一条额度(EXT-001 的额度桶)

public struct QuotaBucket: Equatable {

    /// 供应商范围内稳定的标识。**不拿展示名当主键** —— 展示名会随本地化和措辞变。
    ///
    /// 中转站那四个 id(`total` / `daily` / `weeklyOpus` / `window`)的取值
    /// **刻意等于**从前 `QuotaKind`(EXT-001 阶段 2 已删除)的 rawValue ——
    /// 因为这个字符串同时出现在三处存量数据里:
    /// 菜单栏固定选择的偏好、通知去重键、历史表的四个固定额度列。
    /// 取值一改,老用户的菜单栏选择、当前周期的去重记录和历史曲线会同时出问题。**不要改。**
    public let id: String

    public let title: BucketTitle
    public let used: Double
    public let limit: Double          // 0 表示不限
    public let unit: QuotaUnit
    public let window: TimeWindow?    // nil 表示没有时间维度

    /// 产生 window 的那条规则。历史图靠它按**各自的算法**反推过去的周期边界 ——
    /// 统一按秒数往回减会在夏令时切换日错位。没有规则时就不画重置虚线。
    public let rule: ResetRule?

    public init(id: String, title: BucketTitle, used: Double, limit: Double,
                unit: QuotaUnit = .money(currency: "USD"),
                window: TimeWindow? = nil, rule: ResetRule? = nil) {
        self.id = id
        self.title = title
        self.used = used
        self.limit = limit
        self.unit = unit
        self.window = window
        self.rule = rule
    }

    public func label(_ language: Language) -> String { title.text(language) }

    /// 把一个量按本桶的单位排成文字。用量、上限、剩余都该走它,
    /// 而不是各自去调 `Fmt.money2` —— 那样单位未知的桶照样会被打上 `$`。
    public func amount(_ value: Double) -> String { unit.amount(value) }

    public var unlimited: Bool { limit <= 0 }

    /// 周期短到会让菜单栏的数字和颜色不停跳。
    ///
    /// 从**周期长度**推出,而不是记住某个供应商的某条额度叫什么:
    /// 后者会把供应商细节漏进通用层(不变量 6),而且新供应商的短窗口
    /// 还得靠适配器作者记得去标一下。
    public var hasVolatileWindow: Bool {
        guard let window, window.duration > 0 else { return false }
        return window.duration < QuotaThresholds.volatileWindow
    }

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
