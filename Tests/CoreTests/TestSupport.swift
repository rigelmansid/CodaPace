//
//  TestSupport.swift — 极简测试框架
//
//  为什么需要它:Command Line Tools 不含 XCTest.framework(只随 Xcode.app 分发),
//  所以本机跑不了 `swift test`。这里提供一套同名的断言函数,
//  让测试用例的正文和标准 XCTest 写法保持一致。
//
//  用例通过 TestRegistry.swift 里的清单显式注册 —— 不用 ObjC runtime 自动发现,
//  少一层运行时魔法,行为完全可预测。
//
//  ── 将来装了 Xcode,切回标准 XCTest 只需四步 ──────────────────
//    1. 删掉 TestSupport.swift / TestRegistry.swift / main.swift
//    2. Package.swift 里 .executableTarget → .testTarget(并删掉对应 product)
//    3. 各测试文件顶部加回 `import XCTest`
//    4. 把 `try!` 改回 `throws` + `try`(可选,只是错误信息更友好)
//  测试用例的断言正文一行都不用改。
//

import Foundation

// MARK: - 基类

/// 对应 XCTest 的 XCTestCase。刻意不继承 NSObject —— 不需要任何 ObjC 运行时能力。
class XCTestCase {
    required init() {}
    func setUp() {}
    func tearDown() {}
}

// MARK: - 失败收集

enum TinyTest {
    /// 当前这个 test 方法里累积的失败信息
    static var failures: [String] = []

    static func fail(_ reason: String, file: StaticString, line: UInt) {
        let name = URL(fileURLWithPath: "\(file)").lastPathComponent
        failures.append("\(name):\(line)  \(reason)")
    }
}

// MARK: - 断言(签名与 XCTest 保持一致)

func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T,
                                  _ b: @autoclosure () throws -> T,
                                  _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (x, y) = (try a(), try b())
        guard x != y else { return }
        TinyTest.fail("期望相等,实际 \(x) ≠ \(y)\(suffix(message()))", file: file, line: line)
    } catch {
        TinyTest.fail("求值时抛出错误:\(error)", file: file, line: line)
    }
}

func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T,
                                      _ b: @autoclosure () throws -> T,
                                      accuracy: T,
                                      _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (x, y) = (try a(), try b())
        guard abs(x - y) > accuracy else { return }
        TinyTest.fail("期望 \(x) ≈ \(y)(容差 \(accuracy))\(suffix(message()))", file: file, line: line)
    } catch {
        TinyTest.fail("求值时抛出错误:\(error)", file: file, line: line)
    }
}

func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool,
                   _ message: @autoclosure () -> String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
    do {
        guard try expression() == false else { return }
        TinyTest.fail("期望为真,实际为假\(suffix(message()))", file: file, line: line)
    } catch {
        TinyTest.fail("求值时抛出错误:\(error)", file: file, line: line)
    }
}

func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool,
                    _ message: @autoclosure () -> String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
    do {
        guard try expression() else { return }
        TinyTest.fail("期望为假,实际为真\(suffix(message()))", file: file, line: line)
    } catch {
        TinyTest.fail("求值时抛出错误:\(error)", file: file, line: line)
    }
}

func XCTAssertNil(_ expression: @autoclosure () throws -> Any?,
                  _ message: @autoclosure () -> String = "",
                  file: StaticString = #filePath, line: UInt = #line) {
    do {
        guard let value = try expression() else { return }
        TinyTest.fail("期望为 nil,实际是 \(value)\(suffix(message()))", file: file, line: line)
    } catch {
        TinyTest.fail("求值时抛出错误:\(error)", file: file, line: line)
    }
}

func XCTAssertNotNil(_ expression: @autoclosure () throws -> Any?,
                     _ message: @autoclosure () -> String = "",
                     file: StaticString = #filePath, line: UInt = #line) {
    do {
        guard try expression() == nil else { return }
        TinyTest.fail("期望非 nil,实际是 nil\(suffix(message()))", file: file, line: line)
    } catch {
        TinyTest.fail("求值时抛出错误:\(error)", file: file, line: line)
    }
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T,
                             _ message: @autoclosure () -> String = "",
                             file: StaticString = #filePath, line: UInt = #line,
                             _ errorHandler: (Error) -> Void = { _ in }) {
    do {
        _ = try expression()
        TinyTest.fail("期望抛出错误,但没有\(suffix(message()))", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

func XCTFail(_ message: String = "",
             file: StaticString = #filePath, line: UInt = #line) {
    TinyTest.fail(message.isEmpty ? "主动判定失败" : message, file: file, line: line)
}

private func suffix(_ message: String) -> String {
    message.isEmpty ? "" : " — \(message)"
}

// MARK: - 运行器

/// 一组用例:套件名 → [(用例名, 执行体)]
typealias TestSuite = (name: String, cases: [(name: String, run: () -> Void)])

enum TinyTestRunner {

    /// 返回进程退出码:0 全过,1 有失败
    static func run(_ suites: [TestSuite]) -> Int32 {
        var passed = 0
        var failedCases: [String] = []

        for suite in suites {
            print("\n\(suite.name)")

            for testCase in suite.cases {
                TinyTest.failures = []
                testCase.run()

                if TinyTest.failures.isEmpty {
                    passed += 1
                    print("  ✓ \(testCase.name)")
                } else {
                    failedCases.append("\(suite.name).\(testCase.name)")
                    print("  ✗ \(testCase.name)")
                    for f in TinyTest.failures { print("      \(f)") }
                }
            }
        }

        print("\n" + String(repeating: "─", count: 52))
        print("通过 \(passed) · 失败 \(failedCases.count)")
        if !failedCases.isEmpty {
            print("\n失败的用例:")
            for name in failedCases { print("  · \(name)") }
        }

        return failedCases.isEmpty ? 0 : 1
    }
}
