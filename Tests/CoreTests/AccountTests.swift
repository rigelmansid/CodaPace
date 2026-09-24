import Foundation
import CodaPaceCore

/// 身份测试只关心字段的组合方式,用哪个供应商无关紧要
private let testProvider = "test-provider"

private let accountA = AccountIdentity(providerID: testProvider, baseURL: "https://a.example.com", apiId: "id-a")
private let accountB = AccountIdentity(providerID: testProvider, baseURL: "https://b.example.com", apiId: "id-b")

// MARK: - 账户身份

final class AccountIdentityTests: XCTestCase {

    func testSameFieldsAreTheSameAccount() {
        XCTAssertEqual(accountA, AccountIdentity(providerID: testProvider, baseURL: "https://a.example.com", apiId: "id-a"))
    }

    func testDifferentApiIdIsADifferentAccount() {
        XCTAssertFalse(accountA == AccountIdentity(providerID: testProvider, baseURL: accountA.baseURL, apiId: "id-b"))
    }

    /// 网址变了也算换了账户 —— 发往另一台中继的请求,旧响应不能算数
    func testDifferentBaseURLIsADifferentAccount() {
        XCTAssertFalse(accountA == AccountIdentity(providerID: testProvider, baseURL: "https://other.example.com",
                                                   apiId: accountA.apiId))
    }

    func testEmptyFieldsAreNotConfigured() {
        XCTAssertFalse(AccountIdentity.none.isConfigured)
        XCTAssertFalse(AccountIdentity(providerID: testProvider, baseURL: "https://a.example.com", apiId: "").isConfigured)
        XCTAssertFalse(AccountIdentity(providerID: testProvider, baseURL: "", apiId: "id-a").isConfigured)
        XCTAssertTrue(accountA.isConfigured)
    }

    /// 身份比较连 baseURL 一起比,但**分区键只看 apiId**:
    /// 中继换了网址还是同一个 key 的同一份用量,历史不该被割成两半。
    func testStorageKeyIgnoresBaseURL() {
        let moved = AccountIdentity(providerID: testProvider, baseURL: "https://moved.example.com", apiId: accountA.apiId)
        XCTAssertFalse(accountA == moved)
        XCTAssertEqual(accountA.storageKey, moved.storageKey)
    }

    func testStorageKeyDistinguishesApiIds() {
        XCTAssertFalse(accountA.storageKey == accountB.storageKey)
    }

    func testStorageKeyDoesNotLeakTheRawApiId() {
        XCTAssertFalse(accountA.storageKey.contains("id-a"))
        XCTAssertFalse(accountA.storageKey.contains(accountA.providerID))
    }
}

// MARK: - 刷新准入

final class RefreshGateTests: XCTestCase {

    func testIdleGateIsNotLoading() {
        let gate = RefreshGate()
        XCTAssertFalse(gate.isLoading)
        XCTAssertNil(gate.loadingAccount)
    }

    func testBeginMarksTheAccountAsInFlight() {
        var gate = RefreshGate()
        XCTAssertTrue(gate.begin(accountA))
        XCTAssertTrue(gate.isLoading)
        XCTAssertEqual(gate.loadingAccount, accountA)
    }

    /// 定时刷新、唤醒补刷、手动刷新会撞在一起 —— 同一个账户只放行一次
    func testSameAccountDoesNotReenter() {
        var gate = RefreshGate()
        XCTAssertTrue(gate.begin(accountA))
        XCTAssertFalse(gate.begin(accountA))
    }

    /// 这条是这次修的 bug:旧实现用一个不区分账户的布尔量拦门,
    /// 于是「保存新账户」触发的刷新会被上一个账户还没结束的刷新挡掉,
    /// 新账户要干等一整个定时周期才出数。
    func testDifferentAccountIsLetThroughWhileAnotherIsInFlight() {
        var gate = RefreshGate()
        XCTAssertTrue(gate.begin(accountA))
        XCTAssertTrue(gate.begin(accountB))
        XCTAssertEqual(gate.loadingAccount, accountB)
    }

    /// 同样是这次修的 bug:旧账户的刷新收尾时,不能把新账户正在进行的
    /// 在飞标记抹成空闲 —— 那样 UI 的加载态和实际不符,也会让同账户的重入判断失效。
    func testStaleFinishDoesNotClearTheNewerInFlightMarker() {
        var gate = RefreshGate()
        _ = gate.begin(accountA)
        _ = gate.begin(accountB)

        gate.finish(accountA)            // A 的请求这时才回来
        XCTAssertTrue(gate.isLoading)
        XCTAssertEqual(gate.loadingAccount, accountB)

        gate.finish(accountB)
        XCTAssertFalse(gate.isLoading)
    }

    func testFinishByTheInFlightAccountFreesTheGate() {
        var gate = RefreshGate()
        _ = gate.begin(accountA)
        gate.finish(accountA)
        XCTAssertFalse(gate.isLoading)
        XCTAssertTrue(gate.begin(accountA))
    }

    /// 没配置过的账户不该发起请求
    func testUnconfiguredAccountIsRejected() {
        var gate = RefreshGate()
        XCTAssertFalse(gate.begin(.none))
        XCTAssertFalse(gate.isLoading)
    }

    /// 切回去也要能再刷 —— A → B → A 期间 A 的旧刷新可能还在飞,
    /// 但它已经不占门了,新的 A 刷新必须放行。
    func testSwitchingBackAllowsAFreshRefresh() {
        var gate = RefreshGate()
        _ = gate.begin(accountA)
        _ = gate.begin(accountB)
        XCTAssertTrue(gate.begin(accountA))
        XCTAssertEqual(gate.loadingAccount, accountA)
    }
}

// MARK: - 存档列表(EXT-010)

final class AccountArchiveTests: XCTestCase {

    func testSavedAccountsKeepInsertionOrder() {
        var archive = AccountArchive()
        archive.save(accountB, nickname: "B")
        archive.save(accountA, nickname: "A")
        XCTAssertEqual(archive.entries.map(\.account), [accountB, accountA])
    }

    /// 同一账户再存一次(比如 tu-zi 换了把 key、key_id 没变)只更新昵称,不多出一行
    func testSavingTheSameAccountAgainUpdatesInPlace() {
        var archive = AccountArchive()
        archive.save(accountA, nickname: "旧名")
        archive.save(accountB, nickname: "B")
        archive.save(accountA, nickname: "新名")
        XCTAssertEqual(archive.entries.count, 2)
        XCTAssertEqual(archive.entries.first?.nickname, "新名")
    }

    /// 判重用完整身份:同一 apiId 换了网址是另一条存档 ——
    /// 切换时三个字段都要写回去,合成一条就切不回其中一个了
    func testSameApiIdOnAnotherURLIsASeparateEntry() {
        let moved = AccountIdentity(providerID: accountA.providerID,
                                    baseURL: "https://moved.example.com", apiId: accountA.apiId)
        var archive = AccountArchive()
        archive.save(accountA, nickname: "A")
        archive.save(moved, nickname: "A 新址")
        XCTAssertEqual(archive.entries.count, 2)
    }

    /// 占位身份进了列表,选中一次历史就串 —— 和 Config.apply 那道门同一理由
    func testUnresolvedOrUnconfiguredAccountsAreRejected() {
        var archive = AccountArchive()
        let unresolved = AccountIdentity(providerID: accountA.providerID, baseURL: accountA.baseURL,
                                         apiId: AccountIdentity.unresolvedAccountID)
        XCTAssertFalse(archive.save(unresolved, nickname: "x"))
        XCTAssertFalse(archive.save(.none, nickname: "x"))
        XCTAssertTrue(archive.entries.isEmpty)
    }

    func testBlankNicknameIsRejectedAndRenameKeepsTheOldName() {
        var archive = AccountArchive()
        XCTAssertFalse(archive.save(accountA, nickname: "  \n"))
        XCTAssertTrue(archive.entries.isEmpty)

        archive.save(accountA, nickname: " 主力 ")
        XCTAssertEqual(archive.nickname(for: accountA), "主力")
        XCTAssertFalse(archive.rename(accountA, to: " "))
        XCTAssertEqual(archive.nickname(for: accountA), "主力")
    }

    /// 改名不能顺手把一个没存过的账户加进来
    func testRenamingAnUnarchivedAccountDoesNothing() {
        var archive = AccountArchive()
        XCTAssertFalse(archive.rename(accountA, to: "A"))
        XCTAssertTrue(archive.entries.isEmpty)
    }

    func testRemoveTakesOutOnlyThatAccount() {
        var archive = AccountArchive()
        archive.save(accountA, nickname: "A")
        archive.save(accountB, nickname: "B")
        archive.remove(accountA)
        XCTAssertEqual(archive.entries.map(\.account), [accountB])
    }

    func testPropertyListRoundTrips() {
        var archive = AccountArchive()
        archive.save(accountA, nickname: "A")
        archive.save(accountB, nickname: "B")
        XCTAssertEqual(AccountArchive(propertyList: archive.propertyList), archive)
    }

    /// 一条坏掉的不能把整张列表清空 —— 那等于替用户删了所有存档
    func testCorruptEntriesAreSkippedNotFatal() {
        let stored: [[String: Any]] = [
            ["providerID": accountA.providerID, "baseURL": accountA.baseURL, "apiId": accountA.apiId, "nickname": "A"],
            ["providerID": accountB.providerID, "baseURL": 42, "apiId": accountB.apiId, "nickname": "B"],
            ["providerID": accountA.providerID, "baseURL": accountA.baseURL,
             "apiId": AccountIdentity.unresolvedAccountID, "nickname": "占位"],
            ["providerID": accountA.providerID, "baseURL": accountA.baseURL, "apiId": accountA.apiId, "nickname": "重复"],
        ]
        let archive = AccountArchive(propertyList: stored)
        XCTAssertEqual(archive.entries.map(\.account), [accountA])
        XCTAssertEqual(archive.nickname(for: accountA), "重复")
    }

    func testMissingOrWrongShapedStorageIsAnEmptyList() {
        XCTAssertTrue(AccountArchive(propertyList: nil).entries.isEmpty)
        XCTAssertTrue(AccountArchive(propertyList: "garbage").entries.isEmpty)
    }
}
