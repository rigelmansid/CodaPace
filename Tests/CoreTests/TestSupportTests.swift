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

    /// OPT-031 的用例要用 `XCTAssertNoThrow`,框架原来没有,补上时一起守住它的语义
    func testNoThrowAssertionReportsAThrow() {
        struct Boom: Error {}
        func explode() throws -> Int { throw Boom() }
        // 包一层局部函数:闭包里直接写 try 会被推断成 throws 闭包,传不进 `failures`
        func assertOnAThrowingCall() { XCTAssertNoThrow(try explode()) }

        XCTAssertEqual(failures { XCTAssertNoThrow(1) }, 0)
        XCTAssertEqual(failures { assertOnAThrowingCall() }, 1)
    }

    /// 漏登记的用例不会运行,也不报错(坑 4)。逐个文件找出 `func test…()` 和登记表对一遍,
    /// 登记了却找不到同名方法的(名字抄错)也报出来(OPT-038)。
    ///
    /// 读的是源码:`#filePath` 指向本文件,同目录就是全部测试。按名字计数而不是按套件,
    /// 不同套件里同名的方法照样分得清个数
    func testEveryTestMethodIsRegistered() {
        let folder = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder,
                                                                        includingPropertiesForKeys: nil)
        else { return XCTFail("读不到测试目录 \(folder.path)") }

        let pattern = try! NSRegularExpression(pattern: #"func\s+(test\w+)\s*\(\s*\)"#)
        var declared: [String: Int] = [:]
        for file in files where file.pathExtension == "swift" && file.lastPathComponent != "TestRegistry.swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                return XCTFail("读不了 \(file.lastPathComponent)")
            }
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let name = Range(match.range(at: 1), in: text) { declared[String(text[name]), default: 0] += 1 }
            }
        }

        var registered: [String: Int] = [:]
        for suite in allSuites {
            for testCase in suite.cases { registered[testCase.name, default: 0] += 1 }
        }

        XCTAssertTrue(declared.count > 100, "只找到 \(declared.count) 个方法,读源码的路子不对")
        XCTAssertEqual(declared.filter { registered[$0.key, default: 0] < $0.value }.keys.sorted(), [],
                       "写了没登记")
        XCTAssertEqual(registered.filter { declared[$0.key, default: 0] < $0.value }.keys.sorted(), [],
                       "登记了却找不到这个方法")
    }
}
