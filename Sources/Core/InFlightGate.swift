//
//  InFlightGate.swift — 「在飞的是哪一个」
//
//  项目里已经在两处栽过同一个跟头:拿一个**不区分对象**的布尔量当门。
//
//    · 刷新 —— 布尔 isLoading 把「保存新账户」触发的那次刷新挡在门外,
//      新账户要干等一整个定时周期才出数(OPT-001)。
//    · 测试连接 —— 测试在飞时用户改了网址,旧结果回来照样写进界面,
//      于是显示「连接成功」,而那说的是上一个网址(EXT-003)。
//
//  一个布尔量同时犯两种错:既挡住了该放行的,又放过了该丢弃的。
//  记下「在飞的是哪一个」就都解决了 —— 对象不同就放行,收尾时按对象核对。
//

import Foundation

public struct InFlightGate<Token: Equatable> {

    private var inFlight: Token?

    public init() {}

    public var isBusy: Bool { inFlight != nil }

    /// 在飞的那个;空闲时为 nil
    public var token: Token? { inFlight }

    /// 能不能为 `token` 开一次。返回 true 时它已被记为在飞的那个。
    /// 同一个对象不重入,**不同对象必须放行** —— 它们是两件事,不该互相排队。
    public mutating func begin(_ token: Token) -> Bool {
        guard inFlight != token else { return false }
        inFlight = token
        return true
    }

    /// 收尾。只有 `token` 仍是在飞的那个才把门空出来 ——
    /// 否则先发起的那个收尾时会把后来者的在飞标记抹成空闲。
    public mutating func finish(_ token: Token) {
        if inFlight == token { inFlight = nil }
    }
}
