//
//  Provider.swift — 供应商适配器与能力声明
//
//  适配器负责**协议**:路径、认证、响应映射、管理后台地址。
//  通用服务负责**调度**:定时刷新、账户切换、错误状态、历史记录、通知。
//  这条分界的意义是,接入新供应商不该逼着刷新流程里长出一堆 if。
//
//  适配器按**服务协议**划分,不按 Codex / Claude Code 这类产品名划分 ——
//  同一个供应商完全可能在一个接口里返回多个产品的额度。
//
//  放在 Core 而不是 App:detect / parseConnection / managementURL / capabilities
//  全是纯逻辑,放这儿才能单测。只有 fetchUsage 碰网络。
//

import Foundation

// MARK: - 能力声明

/// 供应商**确实提供**哪些统计数据。
///
/// 这不是功能开关,而是事实陈述。缺哪一项就如实显示未知或隐藏对应界面,
/// 绝不拿默认值顶上 —— 和项目一贯的立场一致:不发明数据。
///
/// 所以每一项都应该有真实的消费者。比如 `dailyResetTime` 为假,app 才需要
/// 自己从「计数器归零」里观测日重置时刻,并把结果标注为推算。
public struct ProviderCapabilities: OptionSet, Equatable, Hashable {

    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// 金额口径的用量与上限(带币种)
    public static let costAmounts         = ProviderCapabilities(rawValue: 1 << 0)

    /// **累计** token 计数。每日用量靠相邻采样做差得出,不是对方直接给的。
    public static let cumulativeTokens    = ProviderCapabilities(rawValue: 1 << 1)

    /// 累计请求数
    public static let cumulativeRequests  = ProviderCapabilities(rawValue: 1 << 2)

    /// 服务端直接给出限流窗口的起止时刻
    public static let windowResetTimes    = ProviderCapabilities(rawValue: 1 << 3)

    /// 服务端直接给出周重置规则(星期 + 小时)
    public static let weeklyResetSchedule = ProviderCapabilities(rawValue: 1 << 4)

    /// 服务端直接给出**日**重置时刻。
    /// 没有这项,app 只能自己观测并标注「推算」—— 见 DailyResetLearner。
    public static let dailyResetTime      = ProviderCapabilities(rawValue: 1 << 5)

    /// 服务端可查历史用量。没有这项,历史只能从装上那天起本地积累。
    public static let usageHistory        = ProviderCapabilities(rawValue: 1 << 6)

    /// 按月聚合的消费
    public static let monthlyAggregate    = ProviderCapabilities(rawValue: 1 << 7)
}

// MARK: - 适配器

public protocol UsageProviderAdapter {

    /// 稳定标识。写进配置用它,**不用展示名** —— 展示名会随本地化和措辞变。
    var providerID: String { get }

    /// 给人看的名字
    var displayName: String { get }

    var capabilities: ProviderCapabilities { get }

    /// 连接里那个标识的性质。决定它能不能明文存 —— 见 CredentialSensitivity。
    var credentialSensitivity: CredentialSensitivity { get }

    /// 一个能让用户照着填的网址示例。设置界面拿它当提示,
    /// 所以提示文案不该在通用层硬编码某一家的格式。
    var inputExample: String { get }

    /// 这个适配器**可能**认识这个输入。
    ///
    /// 只是候选判断,不是结论:域名本身不足以证明对方跑的是这套协议
    /// (自建中转站什么域名都有)。真正的确认要靠一次真实请求。
    func detect(_ input: String) -> Bool

    /// 从用户粘贴的网址解析出连接身份。解析不出来就是 nil。
    func parseConnection(_ input: String) -> AccountIdentity?

    /// 管理后台地址。由适配器构造 —— 它和统计接口不一定同源同路径,
    /// 所以不能在通用层硬编码一条统一路径。
    func managementURL(for account: AccountIdentity) -> URL?

    /// 拉一次用量。
    ///
    /// - Parameter schedule: app 侧掌握的重置规则(含观测学来的日重置时刻)。
    ///   适配器把它和服务端给的时间信息合起来算出各额度的周期。
    ///   EXT-004 会把它一般化成完整的重置策略,那之前先按现有形状传。
    /// - Note: `fetchedAt` 由适配器在**拿到数据之后**打点,所以它是数据到达的时刻,
    ///   而不是发起请求的时刻。
    func fetchUsage(_ account: AccountIdentity, schedule: ResetSchedule,
                    language: Language) async throws -> Snapshot
}

// MARK: - 注册表

/// providerID → 适配器。
///
/// 目前只有一个适配器。留着这层不是为了现在,而是为了让「多一个供应商」
/// 变成往数组里加一项,而不是在刷新流程里加分支 —— 那正是 EXT-002 的验收标准。
public enum ProviderRegistry {

    /// 已知适配器,按 detect 的尝试顺序排列
    public static let all: [UsageProviderAdapter] = [RelayProvider()]

    /// 兜底适配器:存量配置里没有 providerID,一律按它算。
    public static var fallback: UsageProviderAdapter { RelayProvider() }

    public static func adapter(id: String) -> UsageProviderAdapter? {
        all.first { $0.providerID == id }
    }

    /// 存量配置没有 providerID,所以取不到时退回兜底而不是报错
    public static func adapter(for account: AccountIdentity) -> UsageProviderAdapter {
        adapter(id: account.providerID) ?? fallback
    }

    /// 哪些适配器**可能**认识这个输入。可能为空,也可能不止一个 ——
    /// 定不下来时应该让用户选,而不是替他猜。
    public static func candidates(for input: String) -> [UsageProviderAdapter] {
        all.filter { $0.detect(input) }
    }

    /// 识别一段输入。
    ///
    /// - Parameter providerID: 用户**手动指定**了协议时传它。定不下来的时候
    ///   应该让用户选,而不是替他猜 —— 所以这里保留一条手动通道。
    public static func resolve(_ input: String,
                               using providerID: String? = nil) -> ProviderResolution {
        if let providerID {
            guard let adapter = adapter(id: providerID),
                  let account = adapter.parseConnection(input)
            else { return .unsupported }
            return .resolved(providerID: adapter.providerID, account: account)
        }

        guard let (adapter, account) = parse(input) else { return .unsupported }
        return .resolved(providerID: adapter.providerID, account: account)
    }

    /// 这个连接能不能按现在的方式(UserDefaults 明文)保存。
    /// 返回 false 说明该适配器带的是敏感凭据,需要另设存储,不能沿用现有假设。
    public static func canStoreInPlainText(_ adapter: UsageProviderAdapter) -> Bool {
        adapter.credentialSensitivity == .readOnlyIdentifier
    }

    /// 解析一个输入:返回第一个能解析出连接身份的适配器及其结果。
    ///
    /// `detect` 只决定**顺序**,不是门槛:认得的先试,其余的照样试一遍。
    /// 不该因为某个适配器的 detect 保守,就把一个其实能用的链接判死。
    public static func parse(_ input: String) -> (adapter: UsageProviderAdapter,
                                                  account: AccountIdentity)? {
        let ordered = candidates(for: input) + all.filter { !$0.detect(input) }
        for adapter in ordered {
            if let account = adapter.parseConnection(input) { return (adapter, account) }
        }
        return nil
    }
}

// MARK: - 凭据性质

/// 连接里那个标识是什么性质的东西。决定它能不能明文存。
///
/// 现在这个中转站的 `apiId` 是**只读统计标识**:既不能发起 API 请求,也拿不到 API Key,
/// 所以明文存在 UserDefaults 里是可以接受的(理由见 Config.swift 文件头)。
///
/// 但这是**那个供应商的性质**,不是全局前提。以后接入需要 API Key、访问令牌或
/// 会话凭据的供应商时,不能顺手沿用这套存储 —— 所以让适配器把它明说出来,
/// 而不是让它继续当一个没人写下来的隐含假设。
public enum CredentialSensitivity: String, Equatable {

    /// 只读统计标识。明文存储可接受。
    case readOnlyIdentifier

    /// 能代表用户行动的密钥或令牌。**不能**沿用明文存储。
    case secret
}

// MARK: - 识别结果

/// 一段输入能不能对上某个供应商。
///
/// 刻意只有两种结果,没有「大概是」:认不出来就如实说认不出来。
/// 猜一个出来会让用户对着「已识别」的假象排查半天,比直接说不支持更糟。
public enum ProviderResolution: Equatable {

    case resolved(providerID: String, account: AccountIdentity)

    /// 没有适配器能从这段输入解析出连接身份
    case unsupported
}

// MARK: - 连接报告

/// 「测试连接」的结果。不只是通不通,还要说清**认出了什么**、以及有哪些已知局限。
public struct ConnectionReport: Equatable {

    public let providerID: String
    public let displayName: String

    /// 来自真实响应,不是从输入里猜的
    public let accountName: String
    public let isActive: Bool

    public let capabilities: ProviderCapabilities

    /// 用户在保存之前就该知道的事
    public let findings: [Finding]

    /// 每一条都对应一个具体的后续影响,不是泛泛的提示
    public enum Finding: String, Equatable {
        /// 一条有上限的额度都没有 —— 百分比和 pace 都显示不出来
        case noLimitedQuota
        /// 响应里有必要字段缺失或为 null,对应数值是退回来的 0
        case incompleteUsage
        /// 供应商不提供日重置时刻,只能由 app 观测,在那之前标注「推算」
        case dailyResetInferred
        /// 没有任何可信周期,算不出速度判断
        case noResetWindow
        /// 供应商没有历史接口,历史只能从装上这天起本地积累
        case historyIsLocalOnly
    }

    public init(providerID: String, displayName: String,
                accountName: String, isActive: Bool,
                capabilities: ProviderCapabilities, findings: [Finding]) {
        self.providerID = providerID
        self.displayName = displayName
        self.accountName = accountName
        self.isActive = isActive
        self.capabilities = capabilities
        self.findings = findings
    }
}

public extension ConnectionReport {

    /// 从一次**真实响应**推导报告。
    ///
    /// 纯函数,所以「验证了哪些关键字段」这套规则能单测 ——
    /// 否则它只能活在界面代码里,改坏了也没人知道。
    init(snapshot: Snapshot, providerID: String, displayName: String,
         capabilities: ProviderCapabilities) {

        var findings: [Finding] = []

        if snapshot.limited.isEmpty { findings.append(.noLimitedQuota) }
        if !snapshot.hasCompleteUsage { findings.append(.incompleteUsage) }
        if snapshot.gauges.allSatisfy({ $0.window == nil }) { findings.append(.noResetWindow) }
        if !capabilities.contains(.dailyResetTime) { findings.append(.dailyResetInferred) }
        if !capabilities.contains(.usageHistory) { findings.append(.historyIsLocalOnly) }

        self.init(providerID: providerID,
                  displayName: displayName,
                  accountName: snapshot.name,
                  isActive: snapshot.isActive,
                  capabilities: capabilities,
                  findings: findings)
    }
}

// MARK: - 验证连接

public extension UsageProviderAdapter {

    /// 默认实现:跑一次**和正式刷新完全相同**的抓取,再据其结果生成报告。
    ///
    /// 这是有意的 —— 域名像不像、路径对不对都不算数,只有真请求跑通,
    /// 才算确认这个适配器认得对方的协议。`detect` 从头到尾只是个排序提示。
    func verify(_ account: AccountIdentity, language: Language) async throws -> ConnectionReport {
        // 这时还没学到任何重置规则,给一个默认 schedule;
        // 报告里的 dailyResetInferred 本来就是照能力声明给的,不依赖它。
        let snapshot = try await fetchUsage(account, schedule: ResetSchedule(), language: language)
        return ConnectionReport(snapshot: snapshot,
                                providerID: providerID,
                                displayName: displayName,
                                capabilities: capabilities)
    }
}
