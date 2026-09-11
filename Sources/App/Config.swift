//
//  Config.swift — 偏好设置
//
//  全部存 UserDefaults,包括 apiId。
//
//  曾经把 apiId 放进钥匙串,但那和 ad-hoc 签名相冲:钥匙串的访问权限绑定
//  代码签名身份,而 ad-hoc 的身份就是二进制的哈希 —— 每次重新构建身份都变,
//  系统于是每次启动都弹窗索要电脑密码。对一个未公证的 app 来说,
//  这个弹窗的形状和恶意软件一模一样,劝退成本远高于它保护的东西:
//  apiId 只是个**只读统计标识**,既不能发起请求,也拿不到 API Key。
//

import Foundation

// MARK: - 配置

enum Config {
    private static let defaults = UserDefaults.standard

    static var baseURL: String {
        get { defaults.string(forKey: "baseURL") ?? "" }
        set { defaults.set(newValue, forKey: "baseURL") }
    }

    /// 只读的统计标识,和 baseURL 一样以明文存储 —— 理由见文件头
    static var apiId: String {
        get { defaults.string(forKey: "apiId") ?? "" }
        set { defaults.set(newValue, forKey: "apiId") }
    }

    /// 刷新间隔(秒),默认 60
    static var interval: TimeInterval {
        get {
            let v = defaults.double(forKey: "refreshInterval")
            return v > 0 ? v : 60
        }
        set { defaults.set(newValue, forKey: "refreshInterval") }
    }

    /// 菜单栏显示哪条额度。默认「今日」——
    /// 日常最该盯的是今天还能用多少、离重置还有多久,而不是账户总配额。
    static var menuBarSource: MenuBarSource {
        get {
            let raw = defaults.string(forKey: "menuBarSource") ?? QuotaKind.daily.rawValue
            if raw == "auto" { return .auto }
            return .fixed(QuotaKind(rawValue: raw) ?? .daily)
        }
        set {
            switch newValue {
            case .auto:            defaults.set("auto", forKey: "menuBarSource")
            case .fixed(let kind): defaults.set(kind.rawValue, forKey: "menuBarSource")
            }
        }
    }

    /// 界面语言。没手动选过就跟随系统偏好。
    static var language: Language {
        get {
            if let raw = defaults.string(forKey: "language"),
               let language = Language(rawValue: raw) {
                return language
            }
            return Language.systemDefault()
        }
        set { defaults.set(newValue.rawValue, forKey: "language") }
    }

    /// 额度不足 / 消费超速时是否发系统通知
    static var notificationsEnabled: Bool {
        get { defaults.object(forKey: "notificationsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notificationsEnabled") }
    }

    /// 菜单栏图形样式
    static var menuBarStyle: MenuBarStyle {
        get { MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .rings }
        set { defaults.set(newValue.rawValue, forKey: "menuBarStyle") }
    }

    /// 从历史中观测到的日额度重置小时;还没观测到就是 nil。
    /// 详见 Core/ResetSchedule.swift 的 DailyResetLearner。
    static var observedDailyResetHour: Int? {
        get {
            guard defaults.object(forKey: "observedDailyResetHour") != nil else { return nil }
            let h = defaults.integer(forKey: "observedDailyResetHour")
            return (0...23).contains(h) ? h : nil
        }
        set {
            if let newValue { defaults.set(newValue, forKey: "observedDailyResetHour") }
            else { defaults.removeObject(forKey: "observedDailyResetHour") }
        }
    }

    static var isConfigured: Bool { !baseURL.isEmpty && !apiId.isEmpty }

    /// 网页控制台地址
    static var consoleURL: URL? {
        guard isConfigured else { return nil }
        return URL(string: "\(baseURL)/admin-next/api-stats?apiId=\(apiId)")
    }

    /// 当前生效的重置周期推算规则
    static var schedule: ResetSchedule {
        let observed = observedDailyResetHour
        return ResetSchedule(timeZone: .current,
                             dailyResetHour: observed ?? 0,
                             dailyResetHourIsObserved: observed != nil)
    }

    /// 从用户粘贴的网址里解析出 baseURL 和 apiId
    /// 例:https://api.42ai.me/admin-next/api-stats?apiId=xxxx
    static func parse(_ input: String) -> (base: String, apiId: String)? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: text),
              let scheme = comps.scheme,
              let host = comps.host,
              let apiId = comps.queryItems?.first(where: { $0.name == "apiId" })?.value,
              !apiId.isEmpty
        else { return nil }

        var base = "\(scheme)://\(host)"
        if let port = comps.port { base += ":\(port)" }
        return (base, apiId)
    }
}
