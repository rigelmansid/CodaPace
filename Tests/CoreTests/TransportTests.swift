import Foundation
import CodaPaceCore

//
//  TransportTests.swift — 抓取路径上的失败情形(EXT-009)
//
//  这一片覆盖的是**只有接上网络才会发生、却最需要测试**的那些:
//  认证失效、超时、对方返回了一份根本不是这个接口的东西。
//
//  从前它们一条都测不到 —— 适配器直连 `URLSession.shared`,没有地方插手。
//  于是「401 会不会被报成一句看得懂的话」「超时的错误会不会被吞掉」
//  这类问题，只能等用户碰上了才知道。
//

// MARK: - 桩

/// 按预设结果回话的传输层。**不碰网络。**
///
/// 是 class 而不是 struct:它要记下收到的请求,而 struct 得另外拿个引用盒子装。
/// `HTTPTransport` 没有值语义约束,class 照样满足。
private final class StubTransport: HTTPTransport, @unchecked Sendable {

    enum Outcome {
        case status(Int, Data)
        case failure(Error)
    }

    let outcome: Outcome

    /// 实际发出去的那些请求。用来断言「该带的头带了」「不该发的请求没发」。
    var requests: [URLRequest] = []

    init(outcome: Outcome) { self.outcome = outcome }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)

        switch outcome {
        case .failure(let error):
            throw error
        case .status(let code, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: code,
                                           httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    static func ok(_ json: String) -> StubTransport {
        StubTransport(outcome: .status(200, Data(json.utf8)))
    }
}

private let relayAccount = AccountIdentity(providerID: RelayProvider.id,
                                           baseURL: "https://relay.example.com",
                                           apiId: "abc123")

private let tuziKey = "sk-abcdef0123456789"

/// 一份最小的、能解得通的中转站响应
private let relayOK = #"""
{"success": true, "data": {
  "name": "eva", "isActive": true,
  "usage": {"total": {"allTokens": 1000, "requests": 10, "cost": 5}},
  "limits": {"currentTotalCost": 100, "currentDailyCost": 42,
             "weeklyOpusCost": 7, "currentWindowCost": 3,
             "dailyCostLimit": 70, "totalCostLimit": 3000}
}}
"""#

/// 一份最小的、能解得通的 tu-zi 响应
private let tuziOK = #"""
{"code": 0, "message": "success", "data": {
  "key_id": 1001, "status": "active",
  "subscription": {"group_name": "Codex", "daily_used": 1, "daily_limit": 30}
}}
"""#

// MARK: - 认证失效

final class AuthFailureTests: XCTestCase {

    /// key 被吊销、过期、或压根填错 —— 用户最该看懂的就是这一类。
    /// 状态码必须出现在文案里,否则「请求失败」和「你的 key 不对了」长得一模一样。
    func testRelaySurfacesAnUnauthorizedStatus() {
        let relay = RelayProvider(transport: StubTransport(outcome: .status(401, Data())))

        XCTAssertThrowsError(try runAsync {
            try await relay.fetchUsage(Connection(account: relayAccount),
                                       schedule: ResetSchedule(), language: .zhHans)
        }) { error in
            XCTAssertTrue((error as? APIError)?.message.contains("401") ?? false)
        }
    }

    func testTuziSurfacesAnUnauthorizedStatus() {
        let tuzi = TuziProvider(transport: StubTransport(outcome: .status(401, Data())))

        XCTAssertThrowsError(try runAsync {
            try await tuzi.fetchUsage(TuziProvider().parseConnection(tuziKey)!,
                                      schedule: ResetSchedule(), language: .zhHans)
        }) { error in
            XCTAssertTrue((error as? APIError)?.message.contains("401") ?? false)
        }
    }

    /// 服务端在 200 里说失败时,要把**对方给的原因**报出来,
    /// 而不是替它编一句 —— 那句话往往才是能定位问题的
    func testAServerSideFailureInsideA200IsSurfacedVerbatim() {
        let body = #"{"code": 40101, "message": "api key has been revoked"}"#
        let tuzi = TuziProvider(transport: StubTransport.ok(body))

        XCTAssertThrowsError(try runAsync {
            try await tuzi.fetchUsage(TuziProvider().parseConnection(tuziKey)!,
                                      schedule: ResetSchedule(), language: .zhHans)
        }) { error in
            XCTAssertEqual((error as? APIError)?.message, "api key has been revoked")
        }
    }
}

// MARK: - 超时与网络故障

final class TransportFailureTests: XCTestCase {

    /// 超时要**原样传上去**,不能被换成别的错误。
    ///
    /// 只断言「会抛」是不够的 —— 初版就栽在这儿:把传输错误吞掉、拿空数据继续走,
    /// 解码照样会失败,于是照样抛,测试照样通过。可用户看到的从「连接超时」
    /// 变成了「无法解析响应」,后者会把他送去检查一个其实没问题的网址。
    func testATimeoutReachesTheUserAsATimeout() {
        let relay = RelayProvider(
            transport: StubTransport(outcome: .failure(URLError(.timedOut))))

        XCTAssertThrowsError(try runAsync {
            try await relay.fetchUsage(Connection(account: relayAccount),
                                       schedule: ResetSchedule(), language: .zhHans)
        }) { error in
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    /// 同上:连不上就是连不上,不该在路上变成一个解析错误
    func testAConnectionFailureReachesTheUserAsANetworkError() {
        let tuzi = TuziProvider(
            transport: StubTransport(outcome: .failure(URLError(.cannotConnectToHost))))

        XCTAssertThrowsError(try runAsync {
            try await tuzi.fetchUsage(TuziProvider().parseConnection(tuziKey)!,
                                      schedule: ResetSchedule(), language: .zhHans)
        }) { error in
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
    }

    /// 网址填错指到了一个返回 HTML 的页面 —— 200,但根本不是这个接口的响应
    func testAnHTMLPageAtTheRightURLGivesAReadableError() {
        let relay = RelayProvider(transport: StubTransport.ok("<html><body>404</body></html>"))

        XCTAssertThrowsError(try runAsync {
            try await relay.fetchUsage(Connection(account: relayAccount),
                                       schedule: ResetSchedule(), language: .zhHans)
        }) { error in
            XCTAssertNotNil((error as? APIError)?.message)
        }
    }
}

// MARK: - 请求本身

final class RequestShapeTests: XCTestCase {

    /// 密钥要放进 Authorization 头。放错地方的话对方一律回 401,
    /// 而 401 看起来就像「你的 key 失效了」—— 会把人引到完全错误的方向。
    func testTuziSendsTheKeyAsABearerToken() {
        let stub = StubTransport.ok(tuziOK)
        let tuzi = TuziProvider(transport: stub)

        _ = try? runAsync {
            try await tuzi.fetchUsage(TuziProvider().parseConnection(tuziKey)!,
                                      schedule: ResetSchedule(), language: .en)
        }

        let header = stub.requests.first?
            .value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(header, "Bearer \(tuziKey)")
    }

    /// **没有密钥时一个请求都不该发出去。**
    ///
    /// 发了的话对方回 401,用户看到的是「认证失败」,于是去检查一把其实没问题的
    /// key。真正的原因是钥匙串里那条不见了(换过机器、重装过系统),
    /// 而那需要完全不同的处置。
    func testNoRequestIsSentWithoutACredential() {
        let stub = StubTransport.ok(tuziOK)
        let tuzi = TuziProvider(transport: stub)
        let naked = Connection(account: AccountIdentity(providerID: TuziProvider.id,
                                                        baseURL: "https://coding.tu-zi.com",
                                                        apiId: "1001"))

        XCTAssertThrowsError(try runAsync {
            try await tuzi.fetchUsage(naked, schedule: ResetSchedule(), language: .en)
        })
        XCTAssertEqual(stub.requests.count, 0, "没有密钥就不该发请求")
    }

    /// 中转站把 apiId 放在请求体里,不该往 Authorization 头上塞什么
    func testTheRelaySendsNoAuthorizationHeader() {
        let stub = StubTransport.ok(relayOK)
        let relay = RelayProvider(transport: stub)

        _ = try? runAsync {
            try await relay.fetchUsage(Connection(account: relayAccount),
                                       schedule: ResetSchedule(), language: .en)
        }

        XCTAssertNil(stub.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }
}

// MARK: - 成功路径

final class TransportHappyPathTests: XCTestCase {

    /// 接缝装上之后正常路径不能变 —— 这条守的是「加了个协议把线接断了」
    func testTheRelayStillBuildsASnapshotThroughTheSeam() {
        let relay = RelayProvider(transport: StubTransport.ok(relayOK))

        let snapshot: Snapshot = try! runAsync {
            try await relay.fetchUsage(Connection(account: relayAccount),
                                       schedule: ResetSchedule(), language: .en)
        }
        XCTAssertEqual(snapshot.name, "eva")
        XCTAssertEqual(snapshot.gauges.map(\.id), ["total", "daily", "weeklyOpus", "window"])
    }

    func testTuziStillBuildsASnapshotThroughTheSeam() {
        let tuzi = TuziProvider(transport: StubTransport.ok(tuziOK))

        let snapshot: Snapshot = try! runAsync {
            try await tuzi.fetchUsage(TuziProvider().parseConnection(tuziKey)!,
                                      schedule: ResetSchedule(), language: .en)
        }
        XCTAssertEqual(snapshot.name, "Codex")
        XCTAssertEqual(snapshot.gauges.map(\.id), ["daily"])
    }

    /// verify 走的是和正式刷新**完全相同**的抓取,并额外把账户标识带出来。
    /// 这一条同时守住「保存前那次验证是真的跑了一次请求」。
    func testVerifyReportsTheAccountIDFromTheSameRequest() {
        let stub = StubTransport.ok(tuziOK)
        let tuzi = TuziProvider(transport: stub)

        let report: ConnectionReport = try! runAsync {
            try await tuzi.verify(TuziProvider().parseConnection(tuziKey)!, language: .en)
        }
        XCTAssertEqual(report.stableAccountID, "1001")
        XCTAssertEqual(stub.requests.count, 1, "只该发一次请求")
    }
}
