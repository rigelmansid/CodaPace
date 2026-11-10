//
//  SecretVault.swift — 钥匙串怎么覆盖才不丢旧值
//
//  从前覆盖一条密钥是「先删再加」(KeychainStore.set):删成功、加失败时,旧值已经没了。
//  调用方 Config.apply 的前提却是「写密钥失败就停在上一个能用的状态」—— 于是重新保存一个
//  正在用的账户失败时,它当场变成「缺少密钥」,用户只看到一句保存失败(OPT-031)。
//  删的那一步也不看返回码:删不掉时接着加,报出来的是一句对不上的「条目已存在」。
//
//  现在是「新的先落地,再撤旧的」:新值先写进一条暂存条目,写成了才删旧条目,最后把暂存
//  改成正式的名字。任何一步失败,手里都至少有一份能用的 —— 旧的原样还在,或者新的在暂存里
//  (读的时候主条目不在就认暂存)。
//
//  为什么不是「已存在就原地更新」:条目的访问控制记的是创建它的那个程序,而 ad-hoc 签名下
//  每次重新构建都是另一个程序(坑 2)。原地更新留着旧构建的访问控制,更新那一下和之后的
//  每次读都可能弹授权框;新建的条目才属于当前构建,重新粘一次 key 就不再弹。先删再加原本
//  就有这个好处,暂存再改名照样保住它。
//
//  顺序放在 Core 而不放在 App:最少走到、最难发现的正是那几条失败分支,在这里能拿一个假的
//  钥匙串逐条注入故障来测。App 的 KeychainStore 只剩四个原子操作。
//

import Foundation

/// 钥匙串的四个原子操作。Core 不碰 Security 框架 —— App 用 SecItem* 实现,测试用假的。
public protocol SecretVault {
    /// 读一条。没有就返回 nil,**不作为错误**
    func readItem(_ account: String) throws -> String?
    /// 新建一条。已经有了也算失败 —— 覆盖由 `write(_:to:)` 按顺序编排,不靠这一步
    func addItem(_ secret: String, account: String) throws
    /// 删一条。本来就没有也算成功
    func deleteItem(_ account: String) throws
    /// 改名。新名字已被占用算失败
    func renameItem(_ account: String, to newAccount: String) throws
}

public extension SecretVault {

    /// 暂存条目的名字。它只在一次覆盖的中途存在,主条目在的时候它从来不算数。
    /// 正式条目的名字是 `credential.` / `session.` 加 64 位十六进制,撞不上这个后缀
    static func stagingAccount(for account: String) -> String { account + ".pending" }

    /// 读取。主条目不在、暂存在,说明上一次覆盖已经删掉旧值、只差改名 —— 暂存的就是最新值。
    /// 主条目**读失败**(拒绝授权、钥匙串锁着)照样抛出,不拿暂存顶上。
    func read(_ account: String) throws -> String? {
        if let secret = try readItem(account) { return secret }
        return try readItem(Self.stagingAccount(for: account))
    }

    /// 写入或覆盖。**失败时旧值原样保留** —— 只有最后改名那一步失败时旧值已经删掉,
    /// 那时新值留在暂存里,`read` 认它,这个账户照样能用。
    func write(_ secret: String, to account: String) throws {
        let staging = Self.stagingAccount(for: account)

        // 上一次中途失败留下的暂存先清掉
        try deleteItem(staging)
        try addItem(secret, account: staging)
        do {
            try deleteItem(account)
        } catch {
            // 旧值删不掉就原样留着,撤掉刚写的暂存。撤不掉也无妨:主条目在时它不算数,
            // 下一次写入第一步就会清掉它。报出去的是删除自己的原因
            try? deleteItem(staging)
            throw error
        }
        try renameItem(staging, to: account)
    }

    /// 删除,连暂存一起。暂存先删、主条目后删:中途失败时主条目还在,
    /// 调用方据此保持原样(比如存档列表不动)不会说错。
    func remove(_ account: String) throws {
        try deleteItem(Self.stagingAccount(for: account))
        try deleteItem(account)
    }
}
