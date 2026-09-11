//
//  Format.swift — 纯格式化工具
//
//  Core 层不依赖任何 UI 框架,便于单元测试。
//

import Foundation

public enum Fmt {

    // MARK: - 金额

    /// 菜单栏用:空间紧张,大数就少留小数位
    /// 1234.5 → "$1235"  ·  123.45 → "$123.5"  ·  1.234 → "$1.23"
    public static func money(_ v: Double) -> String {
        if v >= 1000 { return String(format: "$%.0f", v) }
        if v >= 100  { return String(format: "$%.1f", v) }
        return String(format: "$%.2f", v)
    }

    private static let moneyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        // 分隔符显式写死,不跟随系统区域。
        // 注意不能只靠 en_US_POSIX —— 那个 locale 刻意不带分组分隔符。
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.groupingSize = 3
        f.decimalSeparator = "."
        return f
    }()

    /// 明细用:始终两位小数 + 千分位  2432.68887 → "$2,432.69"
    public static func money2(_ v: Double) -> String {
        "$" + (moneyFormatter.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v))
    }

    // MARK: - 数量

    /// 大数字缩写,避免科学计数法  2151263918 → "2.15B"
    public static func count(_ v: Double) -> String {
        if v >= 1e9 { return String(format: "%.2fB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.1fM", v / 1e6) }
        if v >= 1e3 { return String(format: "%.1fK", v / 1e3) }
        return String(format: "%.0f", v)
    }

    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.groupingSize = 3
        f.maximumFractionDigits = 0
        return f
    }()

    /// 24998 → "24,998"
    public static func int(_ v: Int) -> String {
        grouping.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// 0.813 → "81%"(菜单栏与进度条标签统一用整数百分比)
    public static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    // MARK: - 时间

    /// 倒计时:只保留两个量级,读起来才干净
    /// 3.6 天 → "3 天 14 小时"  ·  81 分 → "1 小时 21 分"  ·  45 秒 → "45 秒"
    public static func duration(_ seconds: TimeInterval, _ language: Language) -> String {
        let s = Int(seconds.rounded())
        if s <= 0 { return L10n.text(.resetSoon, language) }

        let days = s / 86400
        let hours = (s % 86400) / 3600
        let minutes = (s % 3600) / 60

        func part(_ key: LangKey, _ value: Int) -> String {
            L10n.format(key, language, value)
        }

        if days > 0 {
            return hours > 0
                ? part(.durDaysFormat, days) + " " + part(.durHoursFormat, hours)
                : part(.durDaysFormat, days)
        }
        if hours > 0 {
            return minutes > 0
                ? part(.durHoursFormat, hours) + " " + part(.durMinutesShortFormat, minutes)
                : part(.durHoursFormat, hours)
        }
        if minutes > 0 { return part(.durMinutesFormat, minutes) }
        return part(.durSecondsFormat, s)
    }

    /// "22 分钟后重置" / "Resets in 22 min"
    public static func resetsIn(_ seconds: TimeInterval, _ language: Language) -> String {
        seconds <= 0
            ? L10n.text(.resetSoon, language)
            : L10n.format(.resetsInFormat, language, duration(seconds, language))
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// "23:58:04"
    public static func time(_ d: Date) -> String { clock.string(from: d) }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    /// 绝对重置时刻:"9月11日 00:00"
    public static func moment(_ d: Date) -> String { stamp.string(from: d) }
}
