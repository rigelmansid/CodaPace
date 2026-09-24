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
    /// `QuotaKind`(已删除)的 rawValue,而中转站的桶 ID 取值就等于那些 rawValue,
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

    /// 整体写入一个连接。三个身份字段必须一起换:分开写会留下
    /// 「A 的网址 + B 的 apiId」这种谁都不是的中间态,而恰好在那一刻读到它的
    /// 刷新会发往错误的地方。
    ///
    /// 密钥先落钥匙串、后落身份 —— **顺序是有讲究的**:
    /// 反过来的话,钥匙串写失败时身份已经存进去了,app 会带着一个取不到密钥的
    /// 账户一直刷不出数,而用户看到的只是「请求失败」。先写密钥,失败就整个抛出,
    /// 配置停在上一个能用的状态。
    ///
    /// - Throws: 钥匙串写入失败。调用方**必须**把它显示出来,不能吞掉。
    static func apply(_ connection: Connection) throws {
        let account = connection.account
        let adapter = ProviderRegistry.adapter(for: account)

        // 占位身份绝不能落盘:所有这类账户会共用同一个分区键,
        // 历史和偏好当场串在一起。正常流程走 `resolvedForSaving` 换过真身份了,
        // 走到这儿还是占位就说明那道门被绕开了。
        guard account.apiId != AccountIdentity.unresolvedAccountID else {
            assertionFailure("\(connection) 的身份还没解析出来,不能保存")
            return
        }

        switch adapter.credentialSensitivity {
        case .readOnlyIdentifier:
            // apiId 只是个只读统计标识,明文可接受(理由见文件头)。
            // 这家不该带密钥来 —— 带了说明适配器的声明和实现对不上。
            assert(connection.secret == nil, "\(adapter.providerID) 声明不带密钥,却给了一个")

        case .secret:
            // 这条分支正是 EXT-003 建 CredentialSensitivity 时留的出口:
            // 声明带密钥的供应商在这里被引向钥匙串,而不是顺手沿用明文存储。
            guard let secret = connection.secret, !secret.isEmpty else {
                assertionFailure("\(adapter.providerID) 声明需要密钥,却没给")
                return
            }
            try KeychainStore.set(secret, for: credentialKey(account))
        }

        writeIdentity(account)
    }

    /// 三个身份字段一起写。`apply` 和 `select` 共用这一处 —— 两条路径各写一份的话,
    /// 哪天身份多一个字段,漏改的那条就会留下「谁都不是」的中间态。
    private static func writeIdentity(_ account: AccountIdentity) {
        defaults.set(account.providerID, forKey: "providerID")
        defaults.set(account.baseURL, forKey: "baseURL")
        defaults.set(account.apiId, forKey: "apiId")
    }

    // MARK: - 账户存档(EXT-010)

    /// 存档的账户列表。存的只有身份和昵称,**不含密钥** —— 理由见 Core/AccountArchive.swift。
    static var archive: AccountArchive {
        get { AccountArchive(propertyList: defaults.array(forKey: "accountArchive")) }
        set { defaults.set(newValue.propertyList, forKey: "accountArchive") }
    }

    /// 切到一个已存档的账户。
    ///
    /// **不能复用 `apply`**:`apply` 是「配置一个新账户」,要写钥匙串所以必须拿到密钥;
    /// 切换时手里没有密钥,也不该有 —— 只写身份,密钥照旧由 `connection(for:)`
    /// 去钥匙串取。那条不在了的话,刷新会报「缺少密钥」,见该函数的注释。
    ///
    /// 只接受列表里有的:列表是经过 `AccountArchive.save` 那道门的,
    /// 占位身份和没配置全的进不来。
    static func select(_ account: AccountIdentity) {
        guard archive.contains(account) else {
            assertionFailure("\(account) 不在存档里,不能直接切过去")
            return
        }
        writeIdentity(account)
    }

    /// 删掉一个账户在钥匙串里的密钥。**只给删除存档用**(`UsageService.forgetArchived`)——
    /// 「删除」的语义是「我不再用这个账户了」,把能花钱的密钥留在钥匙串里不干净。
    /// 历史库刻意不动,理由见那边。
    ///
    /// 不带密钥的供应商没有这一条,直接算成功。
    static func removeCredential(for account: AccountIdentity) throws {
        guard ProviderRegistry.adapter(for: account).credentialSensitivity == .secret else { return }
        try KeychainStore.remove(credentialKey(account))
    }

    /// 当前这个账户要用的连接(身份 + 密钥)。
    ///
    /// 刷新流程拿它一次取齐,一路传到适配器 —— 适配器不读任何全局配置。
    /// 身份定住了而密钥没定住等于没定住:中途换账户会让 A 的密钥发往 B 的地址。
    ///
    /// 钥匙串里那条不在了(换过机器、重装过系统、用户手动删了)时 `secret` 为 nil,
    /// 适配器会抛出「缺少密钥」而不是发一个没有认证头的请求 —— 后者的报错是
    /// 401,看起来像 key 失效,会把人引到错误的方向。
    static func connection(for account: AccountIdentity) -> Connection {
        let adapter = ProviderRegistry.adapter(for: account)
        guard adapter.credentialSensitivity == .secret else {
            return Connection(account: account)
        }
        return Connection(account: account,
                          secret: try? KeychainStore.get(credentialKey(account)))
    }

    /// 钥匙串里那条密钥的键。
    ///
    /// 用**完整身份**:一把 key 是某一家的某个部署上的某个账户的,
    /// 三样有一样变了就是另一把 key,不能互相顶替。
    private static func credentialKey(_ account: AccountIdentity) -> String {
        "credential.\(account.fullIdentityKey)"
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
