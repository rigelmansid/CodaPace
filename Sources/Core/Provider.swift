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
/// 所以每一项都应该有真实的消费者。比如没有 `usageHistory`,连接报告才会提前告诉
/// 用户历史只能从装上那天起本地积累。
public struct ProviderCapabilities: OptionSet, Equatable, Hashable {

    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    // 位值沿用删除前的编号,空着的那几位就是删掉的声明(D-2)

    /// **累计** token 计数。每日用量靠相邻采样做差得出,不是对方直接给的。
    public static let cumulativeTokens    = ProviderCapabilities(rawValue: 1 << 1)

    /// 服务端可查历史用量。没有这项,历史只能从装上那天起本地积累。
    public static let usageHistory        = ProviderCapabilities(rawValue: 1 << 6)
}

// MARK: - 传输

/// 「把一个请求发出去」这一步的唯一出口。
///
/// 存在的理由只有一个:**让失败路径可测**。认证失效、超时、对方换了内容类型 ——
/// 这些恰恰是最该有测试、又最不可能靠真联网去构造的情形(EXT-009 明确要求覆盖)。
/// 直连 `URLSession.shared` 的话,它们一条都测不到,而它们出问题时用户看到的
/// 只是一句笼统的「请求失败」。
///
/// 生产路径默认就是 `URLSession.shared`,行为和从前一模一样。
public protocol HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// `URLSession` 本来就有这个方法,声明一下即可
extension URLSession: HTTPTransport {}

// MARK: - 连接

/// 一次抓取要用到的全部东西:**身份 + 凭据**。
///
/// 凭据不从全局配置里读,而是由通用层取出来**显式传进适配器**。这条是不变量 2
/// 的直接延伸:一次刷新横跨两个 await,中途回头读配置就会拿到用户刚换上的另一把 key,
/// 于是 A 的密钥发往 B 的地址。身份定住了而凭据没定住,等于没定住。
public struct Connection: Equatable {

    public let account: AccountIdentity

    /// 密钥。**nil 表示这个适配器不需要** —— 中转站的 apiId 本身就在 `account` 里,
    /// 它是只读统计标识,不是密钥(见 `CredentialSensitivity`)。
    ///
    /// 取值由适配器声明的敏感度决定该从哪儿取:`.readOnlyIdentifier` 不需要,
    /// `.secret` 从钥匙串取。通用层负责取,适配器负责用。
    public let secret: String?

    public init(account: AccountIdentity, secret: String? = nil) {
        self.account = account
        self.secret = secret
    }

    /// 换一个身份,凭据不动。tu-zi 那种「身份要等响应才知道」的适配器,
    /// verify 跑完后拿真身份换掉占位身份时走这里。
    public func with(account: AccountIdentity) -> Connection {
        Connection(account: account, secret: secret)
    }
}

extension Connection: CustomStringConvertible {
    /// **密钥不进任何字符串**。错误信息、日志、断言失败都会走到这里,
    /// 一旦原样带出去,一把能花钱的 key 就落在了崩溃报告或剪贴板里。
    public var description: String {
        "Connection(\(account.providerID) @ \(account.baseURL), apiId: \(account.apiId), "
            + "secret: \(secret == nil ? "无" : "已设置"))"
    }
}

// MARK: - 适配器

public protocol UsageProviderAdapter {

    /// 稳定标识。写进配置用它,**不用展示名** —— 展示名会随本地化和措辞变。
    var providerID: String { get }

    /// 给人看的名字。
    ///
    /// 命名规则:**中转站类用软件名**(`claude-relay-service`),一个适配器对应一种软件;
    /// **服务商类用「品牌 + 产品」**(`tu-zi Coding`)—— 同一家常有好几条产品线,
    /// 只写品牌名会让人以为别的产品线也支持(`api.tu-zi.com` 的按量付费站就是这么被
    /// 当成已支持的)。**不写类别**:「中转站」「服务商」是我们的分类,不该让用户先
    /// 给自己归类(见 EXT-011)。
    ///
    /// 只给人看:改它不影响任何存量数据,存进配置的是 `providerID`。
    var displayName: String { get }

    var capabilities: ProviderCapabilities { get }

    /// 连接里那个标识的性质。决定它能不能明文存 —— 见 CredentialSensitivity。
    var credentialSensitivity: CredentialSensitivity { get }

    /// 一句话告诉用户**该粘什么**。用户粘错了东西(比如那家的网站地址)时显示。
    var inputHint: LangKey { get }

    /// 这是不是这家的网站 —— 用户粘的不是凭据,而是那家的某个页面地址。
    ///
    /// 认出来之后:这家要 key 的(`keyFollowsSite`)就接着要 key,不要的只**指路**
    /// (「这是 X 的网站,请改粘 Y」)。这一步不发任何请求。
    /// 服务商类按域名认,中转站类按路径认(自建的什么域名都有)。
    /// 域名匹配必须带点号:只写「以 `tu-zi.com` 结尾」会让 `evil-tu-zi.com` 也命中(EXT-011)。
    func recognizesSite(_ url: URLComponents) -> Bool

    /// 认出网站之后,是不是接着要用户给一把 key。
    ///
    /// 「先粘服务地址」(EXT-011,2026-09-28):用户在编程工具(Claude Code、Codex 等)里本来就填过
    /// Base URL 和 key 两样。先粘地址,由域名认出是哪家、哪个区 —— 各家的 key 都是
    /// `sk-` 开头,光看 key 分不出来。为真时设置窗口在地址下面多出一个 key 框。
    var keyFollowsSite: Bool { get }

    /// 地址 + key 两段拼成一个连接。只有 `keyFollowsSite` 为真的适配器才会被问到。
    func parseConnection(site: URLComponents, key: String) -> Connection?

    /// `recognizesSite` 为真只是**猜测**:通用的中转站软件适配器认任何网址,
    /// 界面上就不能说「已识别」,要说「将按 X 测试」—— 真正确认靠测试连接。
    var siteMatchIsGuess: Bool { get }

    /// 这个适配器**可能**认识这个输入。
    ///
    /// 只是候选判断,不是结论:域名本身不足以证明对方跑的是这套协议
    /// (自建中转站什么域名都有)。真正的确认要靠一次真实请求。
    func detect(_ input: String) -> Bool

    /// 账户标识是不是**只能从响应里拿到**。
    ///
    /// 中转站的 apiId 就写在用户粘贴的网址里,解析出来就是它。tu-zi 的输入是一把
    /// `sk-` key,里面没有任何账户标识 —— 只有真拉一次接口,对方才会告诉我们 `key_id`。
    ///
    /// 为真时通用层**必须先 verify 再保存**(界面上体现为「没测试通过就不给保存」)。
    /// 退而求其次地编一个(比如拿 key 的哈希顶上)看着能跑,代价是真身份到手的那天
    /// 分区键会变 —— 等于把用户攒下的历史劈成两半。不发明数据同样适用于身份。
    var accountIDComesFromResponse: Bool { get }

    /// 哪条额度的日重置时刻需要 **app 自己观测**。nil 表示不需要。
    ///
    /// 日重置学习是一条**有供应商前提**的功能:中转站不报重置时刻,只能从
    /// 「计数器归零」这个事件里观测出来;而 tu-zi 每次都给 `reset_at`,没什么可学的。
    ///
    /// 由声明的一方说出是哪条额度,通用层就不必认识任何一条具体额度的名字
    /// (不变量 6)。从前 `HistoryRecorder` 里写死的那个 "daily" 就是这么漏出去的:
    /// 换一家供应商,它会去一个不存在的桶上学一个学不到的东西。
    var learnableDailyBucketID: String? { get }

    /// 从用户粘贴的那段文字解析出一个连接。解析不出来就是 nil。
    ///
    /// 「那段文字」是什么取决于适配器:中转站要的是用量页面网址,tu-zi 要的是一把 key。
    /// 各家该粘什么写在 README 里,通用层不硬编码某一家的格式。
    func parseConnection(_ input: String) -> Connection?

    /// 管理后台地址。由适配器构造 —— 它和统计接口不一定同源同路径,
    /// 所以不能在通用层硬编码一条统一路径。
    func managementURL(for account: AccountIdentity) -> URL?

    /// 拉一次用量。
    ///
    /// - Parameter connection: 身份 + 凭据,**一次取齐**。适配器不读任何全局配置 ——
    ///   见 `Connection` 的说明和不变量 2。
    /// - Parameter schedule: app 侧掌握的重置规则(含观测学来的日重置时刻)。
    ///   适配器把它和服务端给的时间信息合起来算出各额度的周期。
    ///   服务端自己就给重置时刻的适配器(tu-zi)可以整个忽略它。
    /// - Note: `fetchedAt` 由适配器在**拿到数据之后**打点,所以它是数据到达的时刻,
    ///   而不是发起请求的时刻。
    func fetchUsage(_ connection: Connection, schedule: ResetSchedule,
                    language: Language) async throws -> Snapshot

    /// 测试连接。默认实现跑一次真实抓取再据其结果生成报告;
    /// 身份来自响应的适配器覆写它,好在同一次请求里把账户标识一并带出来。
    func verify(_ connection: Connection, language: Language) async throws -> ConnectionReport

    /// 同一个适配器,但登录会话只存进给定的这个存储(OPT-017)。
    ///
    /// 给「测试连接」用:测试时还没决定保存,换来的会话不该落进钥匙串 ——
    /// 用户取消、改了输入、或者后面的请求失败了,那份能代表账户 7 天的凭据就成了
    /// 界面上删不掉的孤儿,也违背 README「测试连接什么都不保存」。保存成功后
    /// 由调用方把会话移交给 `SessionTokens.store`。
    ///
    /// 不用会话的适配器原样返回自己。通用层因此不必知道哪家要会话(不变量 6)。
    func sessionScoped(to store: SessionTokenStore) -> UsageProviderAdapter
}

public extension UsageProviderAdapter {
    /// 绝大多数适配器的身份来自用户输入本身,解析出来就是它
    var accountIDComesFromResponse: Bool { false }

    /// 默认不需要观测日重置 —— 需要的一方自己声明是哪条额度
    var learnableDailyBucketID: String? { nil }

    /// 默认认不出任何网站 —— 认不出就如实说认不出
    func recognizesSite(_ url: URLComponents) -> Bool { false }

    /// 默认只认一段输入(统计页网址,或者一把 key)
    var keyFollowsSite: Bool { false }

    func parseConnection(site: URLComponents, key: String) -> Connection? { nil }

    var siteMatchIsGuess: Bool { false }

    func sessionScoped(to store: SessionTokenStore) -> UsageProviderAdapter { self }
}

// MARK: - 注册表

/// providerID → 适配器。
///
/// 目前只有一个适配器。留着这层不是为了现在,而是为了让「多一个供应商」
/// 变成往数组里加一项,而不是在刷新流程里加分支 —— 那正是 EXT-002 的验收标准。
public enum ProviderRegistry {

    /// 已知适配器,按 detect 的尝试顺序排列。
    ///
    /// **通用的排最后**:中转站软件认任何网址,排前面会把专门认得的站点抢走(EXT-011)。
    ///
    /// 两个通用的之间 **claude-code-hub 在前**:陌生网址测试时按这个顺序依次试。
    /// 先试 sub2api 的话,它的 `GET /v1/usage` 在 claude-code-hub 站点上会被当成
    /// **一次模型转发请求**(实测返回「No available providers」并开了一个会话)——
    /// 真实站点上那等于借用户的 key 往上游多发一个请求。反过来 claude-code-hub
    /// 走的是 `/api/v1/me/quota` 和 `/api/auth/login`,在 sub2api 站点上只会 401 / 404。
    public static let all: [UsageProviderAdapter] = [RelayProvider(), TuziProvider(),
                                                     ClaudeCodeHubProvider(), Sub2APIProvider()]

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
                  let connection = adapter.parseConnection(input)
            else { return .unsupported }
            return .resolved(providerID: adapter.providerID, connection: connection)
        }

        guard let (adapter, connection) = parse(input) else { return .unsupported }
        return .resolved(providerID: adapter.providerID, connection: connection)
    }

    /// 这个连接能不能按现在的方式(UserDefaults 明文)保存。
    /// 返回 false 说明该适配器带的是敏感凭据,需要另设存储,不能沿用现有假设。
    public static func canStoreInPlainText(_ adapter: UsageProviderAdapter) -> Bool {
        adapter.credentialSensitivity == .readOnlyIdentifier
    }

    /// 把一个刚解析出来的连接变成**可以保存**的连接。
    ///
    /// 绝大多数适配器的身份就在用户输入里,原样返回即可。身份来自响应的那些
    /// (`accountIDComesFromResponse`)必须先跑过一次 verify —— 这里拿报告里的
    /// `stableAccountID` 换掉占位身份。
    ///
    /// - Returns: nil 表示**还不能保存**。调用方据此不让保存,而不是随手编一个身份:
    ///   分区键是历史和偏好的主键,编出来的那个会在真身份到手的那天把它们劈成两半。
    public static func resolvedForSaving(_ connection: Connection,
                                         report: ConnectionReport?) -> Connection? {
        let adapter = adapter(for: connection.account)

        // 陌生网址是**猜**的(OPT-016):解析只是按注册表顺序排了第一家,身份虽然
        // 由 key 哈希当场算得出,协议对不对却只有真请求跑通才知道。不查就放行的话,
        // 一个 sub2api 站会被存成 claude-code-hub,此后每次刷新都走错接口。
        // 「身份已知」和「协议已确认」是两件事 —— 这里要的是后者
        if adapter.siteMatchIsGuess {
            guard let report, report.providerID == connection.account.providerID else { return nil }
        }

        guard adapter.accountIDComesFromResponse else { return connection }

        // 报告得是**这次这个连接**的:换过供应商之后留在界面上的旧报告不算数
        guard let report, report.providerID == connection.account.providerID,
              let accountID = report.stableAccountID, !accountID.isEmpty,
              accountID != AccountIdentity.unresolvedAccountID
        else { return nil }

        return connection.with(account: AccountIdentity(
            providerID: connection.account.providerID,
            baseURL: connection.account.baseURL,
            apiId: accountID))
    }

    /// 解析一个输入:返回第一个能解析出连接身份的适配器及其结果。
    ///
    /// `detect` 只决定**顺序**,不是门槛:认得的先试,其余的照样试一遍。
    /// 不该因为某个适配器的 detect 保守,就把一个其实能用的链接判死。
    public static func parse(_ input: String) -> (adapter: UsageProviderAdapter,
                                                  connection: Connection)? {
        let ordered = candidates(for: input) + all.filter { !$0.detect(input) }
        for adapter in ordered {
            if let connection = adapter.parseConnection(input) { return (adapter, connection) }
        }
        return nil
    }

    /// 解析不出连接时,这段输入是不是**某一家的网站地址**。
    ///
    /// 没写 `https://` 的(`api.tu-zi.com/console`)补上再认:用户从地址栏抄时常常丢掉它。
    public static func siteOwner(for input: String) -> UsageProviderAdapter? {
        guard let url = siteURL(input) else { return nil }
        return all.first { $0.recognizesSite(url) }
    }

    /// 「先粘服务地址」的第二步:地址认出是哪家、这家要 key,就用这把 key 拼出连接。
    public static func parse(site: String, key: String) -> (adapter: UsageProviderAdapter,
                                                            connection: Connection)? {
        guard let url = siteURL(site),
              let owner = all.first(where: { $0.recognizesSite(url) }),
              let connection = owner.parseConnection(site: url, key: key)
        else { return nil }
        return (owner, connection)
    }

    /// 认出网站的**所有**通用适配器(中转站软件)各自拼出的连接,按注册表顺序。
    ///
    /// 陌生网址光看地址分不出跑的是哪种软件,测试连接时依次试 —— 请求只发往
    /// 用户自己填的那个站点,不会发给第三方(EXT-011)。
    public static func guesses(site: String, key: String) -> [(adapter: UsageProviderAdapter,
                                                              connection: Connection)] {
        guard let url = siteURL(site) else { return [] }
        return all.filter { $0.siteMatchIsGuess && $0.recognizesSite(url) }
            .compactMap { adapter in adapter.parseConnection(site: url, key: key).map { (adapter, $0) } }
    }

    /// 站点根地址:scheme + host + port。用户粘的是编程工具里的 Base URL,可能带
    /// `/v1`、`/api` 之类的路径,而中转站软件的用量接口都在根上。
    /// ponytail: 部署在子路径下的站点(反代到 `/relay/`)会被截掉前缀,遇到再说。
    static func siteRoot(_ site: URLComponents) -> String? {
        guard let scheme = site.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = site.host, !host.isEmpty
        else { return nil }
        return site.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    private static func siteURL(_ input: String) -> URLComponents? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return nil }
        guard let url = URLComponents(string: text.contains("://") ? text : "https://" + text),
              url.host?.isEmpty == false
        else { return nil }
        return url
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

    case resolved(providerID: String, connection: Connection)

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

    /// 对方报的**账户标识**,来自这次真实响应。
    ///
    /// 只有 `accountIDComesFromResponse` 的适配器会给(tu-zi 的 `key_id`),其余是 nil。
    /// 存在的理由是**让历史跨密钥轮换保持连续**:用户换一把 `sk-` key,对方报的
    /// key_id 不变,历史分区键就不变。拿 key 本身做哈希的话,轮换一次历史就断一次。
    ///
    /// 展示名不能顶替它 —— 名字会改,而分区键一变,攒下的曲线就孤立了。
    public let stableAccountID: String?

    public let capabilities: ProviderCapabilities

    /// 用户在保存之前就该知道的事
    public let findings: [Finding]

    /// 每一条都对应一个具体的后续影响,不是泛泛的提示
    public enum Finding: String, Equatable {
        /// 一条有上限的额度都没有 —— 百分比和 pace 都显示不出来
        case noLimitedQuota
        /// 响应里有必要字段缺失或为 null,对应数值是退回来的 0
        case incompleteUsage
        /// 至少一条额度的周期是推算出来的(默认假设、按时区推出、尚未观测到),
        /// 界面上会标注「推算」。
        ///
        /// **看这次实际拿到的数据,不看能力声明**:从前按「没声明 `.dailyResetTime`」给出,
        /// 文案写的是「将由观测推算」—— 那只对中转站成立。sub2api 的 key 限额窗口是
        /// 服务端给的,订阅的日重置是按时区推的,两种都不靠观测,那句话对它两头都不对
        /// (EXT-011,2026-09-28)。那项声明后来也删了(D-2)。
        case resetInferred
        /// 没有任何可信周期,算不出速度判断
        case noResetWindow
        /// 供应商没有历史接口,历史只能从装上这天起本地积累
        case historyIsLocalOnly
    }

    public init(providerID: String, displayName: String,
                accountName: String, isActive: Bool,
                stableAccountID: String? = nil,
                capabilities: ProviderCapabilities, findings: [Finding]) {
        self.providerID = providerID
        self.displayName = displayName
        self.accountName = accountName
        self.isActive = isActive
        self.stableAccountID = stableAccountID
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
         capabilities: ProviderCapabilities, stableAccountID: String? = nil) {

        var findings: [Finding] = []

        if snapshot.limited.isEmpty { findings.append(.noLimitedQuota) }
        if !snapshot.hasCompleteUsage { findings.append(.incompleteUsage) }
        if snapshot.gauges.allSatisfy({ $0.window == nil }) { findings.append(.noResetWindow) }
        if snapshot.gauges.contains(where: { $0.window?.isInferred == true }) { findings.append(.resetInferred) }
        if !capabilities.contains(.usageHistory) { findings.append(.historyIsLocalOnly) }

        self.init(providerID: providerID,
                  displayName: displayName,
                  accountName: snapshot.name,
                  isActive: snapshot.isActive,
                  stableAccountID: stableAccountID,
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
    func verify(_ connection: Connection, language: Language) async throws -> ConnectionReport {
        // 这时还没学到任何重置规则,给一个默认 schedule —— 于是要靠观测学日重置的
        // 中转站,日额度此刻按默认假设推算,报告里如实出现 resetInferred。
        let snapshot = try await fetchUsage(connection, schedule: ResetSchedule(), language: language)
        return ConnectionReport(snapshot: snapshot,
                                providerID: providerID,
                                displayName: displayName,
                                capabilities: capabilities)
    }
}
