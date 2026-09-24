//
//  AccountArchive.swift — 存档的账户列表(EXT-010)
//
//  这个类型小,是因为该按账户分开存的东西早就分开存好了:历史按 `storageKey`、
//  钥匙串按 `fullIdentityKey`、学到的日重置按 `preferenceKey`、通知去重按
//  `notificationNamespace` —— 切走再切回来一样不丢。整个应用里唯一单值的,
//  只有「此刻选中的是哪个」。所以这里要记的只剩「有哪些可选」和「各叫什么」。
//
//  **这里没有新的明文暴露。** 「保存账户列表」听起来像在存一堆凭据,其实存的
//  只有 providerID / baseURL / apiId / 昵称 —— 前三样本来就明文存在
//  UserDefaults 里(见 App/Config.swift 文件头),密钥仍然只在钥匙串。
//
//  放在 Core 而不是直接写进 Config,是为了去重、改名、解码坏数据这几条
//  能被测试覆盖到 —— App 层这套测试框架碰不到。
//

import Foundation

/// 一个存档的账户:身份 + 用户起的名字。
public struct ArchivedAccount: Equatable {
    public let account: AccountIdentity
    public let nickname: String

    public init(account: AccountIdentity, nickname: String) {
        self.account = account
        self.nickname = nickname
    }
}

/// 存档列表。按存入顺序排列,同一身份只出现一次。
public struct AccountArchive: Equatable {

    public private(set) var entries: [ArchivedAccount]

    public init(entries: [ArchivedAccount] = []) {
        self.entries = []
        for entry in entries { save(entry.account, nickname: entry.nickname) }
    }

    /// 存档一个账户;已存过的就地更新昵称,位置不动。
    ///
    /// 判重用**完整身份**(和钥匙串那条的键同一口径):切换时三个字段都要写回去,
    /// 差一个就是另一个账户 —— 同一个中转站 apiId 换了网址,就是两条存档。
    ///
    /// 两种身份绝不能进来,理由和 `Config.apply` 那道门一样:
    /// · 没配置全的 —— 选中它等于把 app 切回「未配置」;
    /// · 占位身份 `unresolvedAccountID` —— 所有这类账户共用一个分区键,
    ///   选中一次历史就串了。
    ///
    /// 昵称为空(去掉首尾空白后)也不收:列表里一行空白没法选。界面应在
    /// 源头拦住,这里是兜底。
    ///
    /// - Returns: 是否真的存进去了
    @discardableResult
    public mutating func save(_ account: AccountIdentity, nickname: String) -> Bool {
        guard account.isConfigured,
              account.apiId != AccountIdentity.unresolvedAccountID else { return false }
        let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }

        let entry = ArchivedAccount(account: account, nickname: name)
        if let index = entries.firstIndex(where: { $0.account == account }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        return true
    }

    /// 改名。只改已存档的;改成空白视为无效,原名保留。
    @discardableResult
    public mutating func rename(_ account: AccountIdentity, to nickname: String) -> Bool {
        guard contains(account) else { return false }
        return save(account, nickname: nickname)
    }

    /// 从列表里拿掉。**只管列表** —— 钥匙串那条由调用方删(那是 App 层的事),
    /// 历史库刻意留着:它按身份分区,同一账户哪天重新加回来会自动接上。
    public mutating func remove(_ account: AccountIdentity) {
        entries.removeAll { $0.account == account }
    }

    public func contains(_ account: AccountIdentity) -> Bool {
        entries.contains { $0.account == account }
    }

    public func nickname(for account: AccountIdentity) -> String? {
        entries.first { $0.account == account }?.nickname
    }

    // MARK: - 存储格式

    /// 存进 UserDefaults 的形状:每条一个字符串字典。
    public var propertyList: [[String: String]] {
        entries.map {
            ["providerID": $0.account.providerID,
             "baseURL": $0.account.baseURL,
             "apiId": $0.account.apiId,
             "nickname": $0.nickname]
        }
    }

    /// 从 UserDefaults 读回来。**坏掉的条目跳过,不连累其余的** ——
    /// 一条读不出来就把整张列表清空,等于替用户删了所有存档。
    /// 跳过的条目也会经过 `save` 那道门,所以占位身份、空昵称、重复项都进不来。
    public init(propertyList: Any?) {
        let raw = propertyList as? [[String: Any]] ?? []
        let decoded = raw.compactMap { item -> ArchivedAccount? in
            guard let providerID = item["providerID"] as? String,
                  let baseURL = item["baseURL"] as? String,
                  let apiId = item["apiId"] as? String,
                  let nickname = item["nickname"] as? String else { return nil }
            return ArchivedAccount(account: AccountIdentity(providerID: providerID,
                                                            baseURL: baseURL,
                                                            apiId: apiId),
                                   nickname: nickname)
        }
        self.init(entries: decoded)
    }
}
