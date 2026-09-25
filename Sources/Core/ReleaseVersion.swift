//
//  ReleaseVersion.swift — 发布版本号的解析与比较
//
//  面板底部的「有新版本」提醒靠它判断：GitHub 上最新 Release 的 tag（`v2.1`）
//  比本机 `CFBundleShortVersionString`（`2.0`）新，才显示那一行。
//
//  不能按字符串比：`"2.10" < "2.9"` 在字典序里成立，于是发了 2.10 反而不提醒。
//  也不能按 Double 比：`2.10` 和 `2.1` 是同一个数。只能逐段按整数比。
//
//  解析不了的一律返回 nil，调用方据此**不显示提醒**，而不是猜一个版本号出来
//  （不变量 3）—— 提醒漏一次无害，误报一次用户会白跑一趟 Release 页面。
//

import Foundation

public struct ReleaseVersion: Comparable, CustomStringConvertible {

    /// 去掉前缀 v 之后的原文，用来显示（`2.10` 不该被写回成别的样子）
    public let text: String
    private let components: [Int]

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part -> Int? in
            // 只收纯数字段：`2.1-beta` 这类预发布号不在提醒范围内
            // （GitHub 的 releases/latest 本就跳过预发布版）
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        guard !parts.isEmpty, numbers.count == parts.count else { return nil }

        self.text = text
        self.components = numbers
    }

    public var description: String { text }

    /// 短的一方补 0 再逐段比：`2.0` 与 `2.0.0` 相等
    private static func padded(_ lhs: ReleaseVersion, _ rhs: ReleaseVersion) -> ([Int], [Int]) {
        let length = max(lhs.components.count, rhs.components.count)
        func pad(_ c: [Int]) -> [Int] { c + Array(repeating: 0, count: length - c.count) }
        return (pad(lhs.components), pad(rhs.components))
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let (l, r) = padded(lhs, rhs)
        return l == r
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let (l, r) = padded(lhs, rhs)
        return l.lexicographicallyPrecedes(r)
    }
}
