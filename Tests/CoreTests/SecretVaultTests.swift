import Foundation
import CodaPaceCore

//
//  SecretVaultTests.swift — 钥匙串覆盖的顺序(OPT-031)
//
//  拿一个内存里的假钥匙串逐步注入故障。真钥匙串在 App 层,这里测不到;而要测的恰恰是
//  那几条最少走到的失败分支 —— 覆盖到一半失败时,手里还剩不剩一份能用的。
//

private struct InjectedFailure: Error, Equatable {}
private struct AlreadyExists: Error {}

/// 内存里的钥匙串。`fails` 判定哪些操作失败,`items` 就是钥匙串里此刻的全部条目
private final class FakeVault: SecretVault {

    enum Operation: Equatable {
        case read(String), add(String), delete(String), rename(String)
    }

    var items: [String: String] = [:]
    var fails: (Operation) -> Bool = { _ in false }

    func readItem(_ account: String) throws -> String? {
        try check(.read(account))
        return items[account]
    }

    func addItem(_ secret: String, account: String) throws {
        try check(.add(account))
        guard items[account] == nil else { throw AlreadyExists() }
        items[account] = secret
    }

    func deleteItem(_ account: String) throws {
        try check(.delete(account))
        items[account] = nil
    }

    func renameItem(_ account: String, to newAccount: String) throws {
        try check(.rename(account))
        guard let secret = items[account], items[newAccount] == nil else { throw AlreadyExists() }
        items[account] = nil
        items[newAccount] = secret
    }

    private func check(_ operation: Operation) throws {
        if fails(operation) { throw InjectedFailure() }
    }
}

private let key = "credential.abc"
private let staging = FakeVault.stagingAccount(for: key)

final class SecretVaultTests: XCTestCase {

    /// 正常路径:新建、覆盖,都只留下一条正式条目,不留暂存
    func testWritingCreatesOrReplacesTheItem() {
        let vault = FakeVault()
        XCTAssertNoThrow(try vault.write("sk-old", to: key))
        XCTAssertEqual(vault.items, [key: "sk-old"])

        XCTAssertNoThrow(try vault.write("sk-new", to: key))
        XCTAssertEqual(vault.items, [key: "sk-new"])
        XCTAssertEqual(try vault.read(key), "sk-new")
    }

    /// 本条的起因:写新值失败时,旧值必须原样还在。从前是先删旧的再加新的 ——
    /// 加失败时旧密钥已经没了,正在用的账户当场变成「缺少密钥」
    func testAFailedAddKeepsTheOldValue() {
        let vault = FakeVault()
        vault.items = [key: "sk-old"]
        vault.fails = { if case .add = $0 { return true } else { return false } }

        XCTAssertThrowsError(try vault.write("sk-new", to: key))
        XCTAssertEqual(try vault.read(key), "sk-old")
        XCTAssertEqual(vault.items, [key: "sk-old"])
    }

    /// 旧值删不掉(比如拒绝授权):旧值留着,刚写的暂存撤掉,报出去的是删除自己的原因 ——
    /// 从前删的返回码没人看,接着加,报出来的是一句对不上的「条目已存在」
    func testAFailedDeleteKeepsTheOldValueAndReportsItsOwnError() {
        let vault = FakeVault()
        vault.items = [key: "sk-old"]
        vault.fails = { $0 == .delete(key) }

        XCTAssertThrowsError(try vault.write("sk-new", to: key)) { error in
            XCTAssertTrue(error is InjectedFailure, "\(error)")
        }
        XCTAssertEqual(vault.items, [key: "sk-old"])
    }

    /// 最后改名失败:旧值已经删了,新值留在暂存里 —— 读的时候认它,账户照样能用
    func testAFailedRenameLeavesTheNewValueReadable() {
        let vault = FakeVault()
        vault.items = [key: "sk-old"]
        vault.fails = { if case .rename = $0 { return true } else { return false } }

        XCTAssertThrowsError(try vault.write("sk-new", to: key))
        XCTAssertEqual(try vault.read(key), "sk-new")
    }

    /// 上一次中途失败留下的暂存:主条目在时它不算数,下一次写入先把它清掉
    func testALeftoverStagingItemNeverShadowsTheMainItem() {
        let vault = FakeVault()
        vault.items = [key: "sk-old", staging: "sk-abandoned"]
        XCTAssertEqual(try vault.read(key), "sk-old")

        XCTAssertNoThrow(try vault.write("sk-new", to: key))
        XCTAssertEqual(vault.items, [key: "sk-new"])
    }

    /// 删除连暂存一起删 —— 否则那份能花钱的 key 会留成删不掉的孤儿,读的时候还会被认回来。
    /// 主条目删失败时它原样还在,调用方据此保持存档列表不动
    func testRemovingDeletesTheStagedCopyToo() {
        let vault = FakeVault()
        vault.items = [key: "sk-new", staging: "sk-abandoned"]
        XCTAssertNoThrow(try vault.remove(key))
        XCTAssertEqual(vault.items, [:])
        XCTAssertNil(try vault.read(key))

        vault.items = [key: "sk-new"]
        vault.fails = { $0 == .delete(key) }
        XCTAssertThrowsError(try vault.remove(key))
        XCTAssertEqual(vault.items, [key: "sk-new"])
    }

    /// 主条目**读失败**和「没有」是两回事(OPT-018):照样抛出,不拿暂存顶上
    func testAReadFailureIsNotTakenForAMissingItem() {
        let vault = FakeVault()
        vault.items = [staging: "sk-abandoned"]
        vault.fails = { $0 == .read(key) }
        XCTAssertThrowsError(try vault.read(key))
    }
}
