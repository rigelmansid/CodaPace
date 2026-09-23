//
//  Account.swift — 账户身份与刷新准入
//
//  这两个类型解决同一个问题:一次刷新横跨两个 await,期间用户可能已经换了账户。
//
//  旧实现全程直接读可变的全局配置 —— 第一个请求读到账户 A,第二个读到 B,
//  落历史时又读第三次,于是 A 的用量被写进 B 的库,面板上出现 A 的额度配 B 的月消费。
//
//  规则只有两条:
//  · 刷新开始时把身份**取一次、定住**,一路传下去,中途不再回头读全局配置;
//  · 提交前再比一次身份,不是当前账户就整份丢掉 —— 不显示、不入库、不发通知。
//

import Foundation

// MARK: - 账户身份

/// 一次刷新所绑定的账户。值类型 + Equatable,是「这份结果还属不属于当前账户」的唯一判据。
public struct AccountIdentity: Equatable, Hashable {

    /// 哪个供应商适配器负责这个账户。
    /// 同一个网址在不同协议下含义完全不同,所以它是身份的一部分。
    public let providerID: String

    public let baseURL: String
    public let apiId: String

    public init(providerID: String, baseURL: String, apiId: String) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.apiId = apiId
    }

    /// 还没配置过
    public static let none = AccountIdentity(providerID: "", baseURL: "", apiId: "")

    /// 身份的**占位值**,只活在「解析完成、还没 verify」这一小段里。
    ///
    /// 有的供应商的账户标识不在用户输入里,而在响应里(tu-zi 的 `key_id`)——
    /// 那种适配器声明 `accountIDComesFromResponse`,保存流程必须先经过
    /// `ProviderRegistry.resolvedForSaving` 把它换成真身份。
    ///
    /// **它永远不该进存储。** 真进去了就说明保存流程漏掉了那道门:
    /// 所有这类账户会共用同一个分区键,历史和偏好当场串在一起。
    public static let unresolvedAccountID = "__unresolved__"

    public var isConfigured: Bool {
        !providerID.isEmpty && !baseURL.isEmpty && !apiId.isEmpty
    }

    /// 历史库的分区键:**providerID + apiId**,刻意不含 baseURL。
    ///
    /// 不含 baseURL 的理由没变:中继换了网址还是同一个 key 的同一份用量,历史不该被割成两半;
    /// 但刷新的身份要连 baseURL 一起比 —— 网址变了就是发往别处的另一次请求,旧响应不能算数。
    ///
    /// **providerID 是 EXT-009 加进来的,起因是一个真实的碰撞风险。**
    /// 从前只有一个适配器,键里不含 providerID 没有后果。接入第二家之后就有了:
    /// tu-zi 的账户标识是响应里的 `key_id`,一个短整数(`4439` 这种),
    /// 而自建中转站的 apiId 可以是任意字符串。两者撞上,**两个账户的历史会静默合并** ——
    /// 曲线对不上、token 增量互相污染,而且合了就再也分不开。
    ///
    /// 老用户的历史靠 `legacyStorageKey` 惰性迁移,一条都不会丢。
    public var storageKey: String { AccountKey.derive([providerID, apiId]) }

    /// 加 providerID **之前**的历史分区键 —— 那时只由 apiId 派生。
    ///
    /// `HistoryStore` 拿它做一次惰性认领:新键下一行都没有、旧键下有,就地改名。
    /// 惰性而不是启动时一次迁完,是因为哈希单向、库自己算不出这个映射,
    /// 只有「用户切到哪个账户」的那一刻才同时知道两个键。代价是迁移时机分散,
    /// 换来的是**没有任何一个账户的历史会被孤立**。
    ///
    /// **只有兜底适配器的账户才有老分区。** 存量配置里没有 providerID,
    /// 读出来一律按兜底适配器算(见 `Config.account`),所以那个年代的历史
    /// 只可能属于它。让别家也来认领,认领到的正好会是**另一家的历史** ——
    /// 那恰恰是加 providerID 要修的那个碰撞,反而在迁移里又犯一遍。
    public var legacyStorageKey: String? {
        guard providerID == ProviderRegistry.fallback.providerID else { return nil }
        return AccountKey.derive(apiId: apiId)
    }

    /// 偏好存储的分区键,**连服务地址一起算**。
    ///
    /// 又是一个刻意不同的口径。历史用量按 `storageKey`(只看 apiId)分区,是因为用量本身
    /// 不随网址变;但存在这里的是**那个部署的配置**,比如「日重置在几点」——
    /// 换了地址就不能假定它照旧。
    ///
    /// 宁可作废重学、界面如实标回「推算」,也不要拿旧规则算出一个看着很确定的倒计时。
    public var preferenceKey: String { AccountKey.derive([baseURL, apiId]) }

    /// 通知去重的命名空间:**完整身份**(供应商 + 服务地址 + 账户标识)。
    ///
    /// 第三种口径,理由是这里**没有迁移成本**:历史换了键会孤立掉用户攒下的曲线,
    /// 偏好换了键会丢掉学到的重置时刻;而去重账本最坏的后果只是多发一条通知。
    /// 所以这里可以用最严格的口径,方向也对 —— 宁可重复提醒,不可漏报。
    public var notificationNamespace: String { fullIdentityKey }

    /// **完整身份**(供应商 + 服务地址 + 账户标识)派生出的键。
    ///
    /// 两个用处共用它:通知去重的命名空间,以及钥匙串里那条密钥的键。
    /// 两者的理由不同,但要的口径恰好相同 —— 一把 key 是某一家的某个部署上的
    /// 某个账户的,三样有一样变了就是另一回事。算一次就够,不留两份会各自漂移
    /// 的实现(不变量 5)。
    public var fullIdentityKey: String {
        AccountKey.derive([providerID, baseURL, apiId])
    }

    // `preferenceKey` **仍然不含 providerID**,而且不需要含。
    //
    // 它已经带了 baseURL,而两家供应商的服务地址不可能相同 —— 撞不上。
    // storageKey 的那个碰撞恰恰来自它连 baseURL 都不含(有意的:中继换网址
    // 不该割裂历史),于是只剩 apiId 一个维度在扛。
    //
    // 键加得越多,能撞上的越少,而每加一个都要付一次迁移的代价。
    // 只在真会撞的地方加。
}

// MARK: - 刷新准入

/// 刷新的重入控制。只记一件事:现在在飞的是**哪个账户**的刷新。
///
/// 两条规则各自对应一个真实出过的问题:
///
/// · **同账户不重入** —— 60 秒的定时刷新、唤醒后的补刷、面板上的手动刷新会撞在一起。
/// · **换账户必须放行** —— 旧实现拿一个不区分账户的布尔 `isLoading` 拦门,于是
///   「保存新账户」触发的那次刷新会被上一个账户还没结束的刷新挡掉,新账户得干等
///   一整个定时周期才出数。两个账户的刷新是两件事,不该互相排队。
///
/// 配套的是 `finish` 按账户核对:旧刷新收尾时不能把后来者的在飞标记抹成空闲。
public struct RefreshGate {

    /// 「在飞的是哪一个」这套逻辑是共用的,见 InFlightGate ——
    /// 设置界面的「测试连接」栽的是同一个跟头,只是那边的身份是用户输入的那段文字。
    private var gate = InFlightGate<AccountIdentity>()

    public init() {}

    public var isLoading: Bool { gate.isBusy }

    /// 在飞刷新所属的账户;空闲时为 nil
    public var loadingAccount: AccountIdentity? { gate.token }

    /// 能不能为 `account` 开一次刷新。返回 true 时它已被记为在飞的那个。
    public mutating func begin(_ account: AccountIdentity) -> Bool {
        // 没配置过的账户根本不该发请求 —— 这一条是刷新独有的,不属于通用的门
        guard account.isConfigured else { return false }
        return gate.begin(account)
    }

    /// 一次刷新结束。只有 `account` 仍是在飞的那个才把门空出来 ——
    /// 否则旧账户的收尾会清掉新账户正在进行的刷新标记,让 UI 的加载态和实际不符。
    public mutating func finish(_ account: AccountIdentity) {
        gate.finish(account)
    }
}
