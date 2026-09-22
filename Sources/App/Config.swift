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
    ///
    /// 存的是额度桶 ID(EXT-001)。**存量偏好不需要迁移** —— 从前存的是
    /// `QuotaKind` 的 rawValue,而中转站的桶 ID 取值就等于那些 rawValue,
    /// 所以老用户选的那一条原样还在。读不到就退回「今日」,不认识的 ID
    /// 会在 `menuBarGauge` 里自然退回自动选择,不必在这里判。
    static var menuBarSource: MenuBarSource {
        get {
            let raw = defaults.string(forKey: "menuBarSource") ?? Self.defaultBucketID
            return raw == "auto" ? .auto : .fixed(bucketID: raw)
        }
        set {
            switch newValue {
            case .auto:                defaults.set("auto", forKey: "menuBarSource")
            case .fixed(let bucketID): defaults.set(bucketID, forKey: "menuBarSource")
            }
        }
    }

    /// 默认盯「今日」:日常最该看的是今天还能用多少、离重置还有多久,不是账户总配额。
    /// 这个字符串同时是中转站那条日额度的桶 ID。
    static let defaultBucketID = "daily"

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

    // MARK: - 学到的日重置规则(按账户分开)

    /// 从历史中观测到的日重置规则,**每个账户各存一份**。
    ///
    /// 从前这是一个全局的小时数:A 学到的值会直接拿给 B 用,而学习逻辑一发现已有值
    /// 就不再更新,于是一条错规则能长期影响倒计时、pace 判断和「推算」标注。
    /// 详见 Core/ResetSchedule.swift 的 LearnedDailyReset。
    static func learnedDailyReset(for account: AccountIdentity) -> LearnedDailyReset? {
        guard let raw = defaults.dictionary(forKey: learnedResetKey(account)),
              let hour = raw["hour"] as? Int, (0...23).contains(hour),
              let zone = raw["timeZone"] as? String, !zone.isEmpty
        else { return nil }

        let record = LearnedDailyReset(hour: hour,
                                       timeZoneIdentifier: zone,
                                       uncertainty: raw["uncertainty"] as? TimeInterval ?? 0)

        // 时区变了就当没学过 —— 下一次观测到重置时会重新学。
        // 这期间界面如实标回「推算」,而不是拿一个前提已不成立的值假装确定。
        return record.applies(in: .current) ? record : nil
    }

    static func setLearnedDailyReset(_ value: LearnedDailyReset, for account: AccountIdentity) {
        defaults.set(["hour": value.hour,
                      "timeZone": value.timeZoneIdentifier,
                      "uncertainty": value.uncertainty],
                     forKey: learnedResetKey(account))
    }

    private static func learnedResetKey(_ account: AccountIdentity) -> String {
        "learnedDailyReset.\(account.preferenceKey)"
    }

    /// 清掉旧版那个**全局**的日重置小时。
    ///
    /// 刻意**不迁移**到当前账户:那个值不知道是从哪个账户学来的,把它安到某个账户头上
    /// 等于把同一个 bug 再犯一遍。丢掉之后各账户自己重学,期间界面如实标注「推算」——
    /// 这比留一个来源不明却看着很确定的值要好。
    static func discardLegacyGlobalResetHour() {
        defaults.removeObject(forKey: "observedDailyResetHour")
    }

    // MARK: - 账户身份

    /// 当前配置的账户,取成一个不可变的值。
    ///
    /// 刷新流程必须**开头取一次就定住**,不要在两个 await 之间反复读 ——
    /// 否则用户中途换账户,一次刷新会横跨两个账户。详见 Core/Account.swift。
    static var account: AccountIdentity {
        // 存量配置是在只有一个供应商的年代写下的,没有 providerID ——
        // 读不到就按兜底适配器算,这样老用户升级后无需重新配置。
        let provider = defaults.string(forKey: "providerID") ?? ProviderRegistry.fallback.providerID
        return AccountIdentity(providerID: provider, baseURL: baseURL, apiId: apiId)
    }

    /// 负责当前账户的适配器
    static var adapter: UsageProviderAdapter { ProviderRegistry.adapter(for: account) }

    /// 整体写入账户。三个字段必须一起换:分开写会留下「A 的网址 + B 的 apiId」这种
    /// 谁都不是的中间态,而恰好在那一刻读到它的刷新会发往错误的地方。
    static func apply(_ account: AccountIdentity) {
        // 明文存 UserDefaults 的前提是「它只是个只读统计标识」(理由见文件头)。
        // 这个前提属于**具体那家供应商**,不是通用假设 —— 以后接入带密钥的供应商时,
        // 这里会拦住它,逼着为它设计真正的存储,而不是顺手沿用现在这套。
        guard ProviderRegistry.canStoreInPlainText(ProviderRegistry.adapter(for: account)) else {
            assertionFailure("\(account.providerID) 带的是敏感凭据,不能沿用明文存储")
            return
        }

        defaults.set(account.providerID, forKey: "providerID")
        defaults.set(account.baseURL, forKey: "baseURL")
        defaults.set(account.apiId, forKey: "apiId")
    }

    static var isConfigured: Bool { account.isConfigured }

    /// 网页控制台地址。路径由**适配器**构造 —— 不同供应商的后台地址和统计接口
    /// 未必同源同路径,通用层不该硬编码一条。
    static var consoleURL: URL? { adapter.managementURL(for: account) }

    /// 当前生效的重置周期推算规则。
    ///
    /// **必须按账户取** —— 不同账户的日重置时刻本来就不一样,
    /// 而且刷新流程里要用开头定住的那个身份,不能中途回头读全局配置。
    static func schedule(for account: AccountIdentity) -> ResetSchedule {
        let learned = learnedDailyReset(for: account)
        return ResetSchedule(timeZone: .current,
                             dailyResetHour: learned?.hour ?? 0,
                             dailyResetHourIsObserved: learned != nil)
    }

}
