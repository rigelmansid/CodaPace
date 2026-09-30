//
//  TestSupportTests.swift — 测试框架自己的断言语义
//
//  框架是自己写的,断言判错了不会有任何东西提醒我们:用例照样全绿,
//  只是那条断言什么也没在守。OPT-013 就是这么藏住的 —— 容差断言把 NaN 判成了相等,
//  458 例全绿,而 78 处容差断言对 NaN 回归一概放行。
//
//  做法:断言照常调用,事后看它往失败列表里记了几条,再把这几条摘掉,
//  免得「期望它失败」的那一下被运行器当成这条用例本身的失败。
//

import Foundation

final class TestSupportTests: XCTestCase {

    /// 跑一段断言,返回它记下的失败条数,并把这些失败从列表里摘掉
    private func failures(_ body: () -> Void) -> Int {
        let before = TinyTest.failures.count
        body()
        let recorded = TinyTest.failures.count - before
        TinyTest.failures.removeLast(recorded)
        return recorded
    }

    func testAccuracyAssertionPassesWithinTolerance() {
        XCTAssertEqual(failures { XCTAssertEqual(0.5, 0.5004, accuracy: 0.001) }, 0)
        XCTAssertEqual(failures { XCTAssertEqual(0.5, 0.5, accuracy: 0) }, 0)
    }

    func testAccuracyAssertionFailsOutsideTolerance() {
        XCTAssertEqual(failures { XCTAssertEqual(0.0, 0.5, accuracy: 0.001) }, 1)
    }

    /// 本条的起因:NaN 在任一侧都必须报失败
    func testAccuracyAssertionRejectsNaN() {
        XCTAssertEqual(failures { XCTAssertEqual(Double.nan, 0.5, accuracy: 0.001) }, 1)
        XCTAssertEqual(failures { XCTAssertEqual(0.5, Double.nan, accuracy: 0.001) }, 1)
        XCTAssertEqual(failures { XCTAssertEqual(Double.nan, Double.nan, accuracy: 0.001) }, 1)
    }

    /// 同号无穷大算相等(它俩相减是 NaN,只靠容差会判错);异号、与有限数都不相等
    func testAccuracyAssertionHandlesInfinity() {
        XCTAssertEqual(failures { XCTAssertEqual(Double.infinity, .infinity, accuracy: 0.001) }, 0)
        XCTAssertEqual(failures { XCTAssertEqual(Double.infinity, -.infinity, accuracy: 0.001) }, 1)
        XCTAssertEqual(failures { XCTAssertEqual(Double.infinity, 1e300, accuracy: 0.001) }, 1)
    }
}
