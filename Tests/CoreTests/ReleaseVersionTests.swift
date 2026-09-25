import Foundation
import CodaPaceCore

final class ReleaseVersionTests: XCTestCase {

    func testLeadingVIsStrippedForDisplay() {
        XCTAssertEqual(ReleaseVersion("v2.1")?.text, "2.1")
        XCTAssertEqual(ReleaseVersion(" V2.10 \n")?.text, "2.10")
        XCTAssertEqual(ReleaseVersion("2.0")?.text, "2.0")
    }

    /// 解析不了就是 nil,调用方据此不提醒 —— 不猜
    func testMalformedTagsAreRejected() {
        for tag in ["", "v", "2.x", "2..1", "2.1-beta", ".2", "2.", "latest", "２.1"] {
            XCTAssertNil(ReleaseVersion(tag), "不该解析:\(tag)")
        }
    }

    /// 字典序会得出 "2.10" < "2.9",那样发了 2.10 反而不提醒
    func testComponentsCompareAsIntegersNotText() {
        guard let v210 = ReleaseVersion("2.10"), let v29 = ReleaseVersion("2.9") else {
            return XCTFail("应能解析")
        }
        XCTAssertTrue(v210 > v29)
        XCTAssertFalse(v29 > v210)
    }

    /// 本机 2.0、Release 标 v2.0.0 —— 同一个版本,不该提醒
    func testMissingTrailingComponentsCountAsZero() {
        guard let short = ReleaseVersion("2.0"), let long = ReleaseVersion("v2.0.0") else {
            return XCTFail("应能解析")
        }
        XCTAssertEqual(short, long)
        XCTAssertFalse(long > short)
        XCTAssertFalse(short > long)
    }

    func testHigherMajorWinsRegardlessOfMinor() {
        guard let v3 = ReleaseVersion("3"), let v299 = ReleaseVersion("2.9.9"),
              let v201 = ReleaseVersion("2.0.1"), let v20 = ReleaseVersion("2.0") else {
            return XCTFail("应能解析")
        }
        XCTAssertTrue(v3 > v299)
        XCTAssertTrue(v201 > v20)
    }
}
