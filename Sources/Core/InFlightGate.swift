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
//  后来又在「对象」上栽了一次,两处各栽一遍(刷新 OPT-021,测试连接 OPT-034):
//  A → B → A 之后,先后两次 A 的对象一模一样,先发的那次回来照样能提交,它的收尾
//  还会把后发那次的在飞标记抹成空闲,于是第三次 A 又被放了进来。对象只答得了
//  「挡不挡」(同一个不重入),答不了「还算不算数」。所以每次放行发一张票 ——
//  对象加一个序号 —— 提交和收尾都认票。刷新和测试连接共用这一份。
//

import Foundation

public struct InFlightGate<Token: Equatable> {

    /// 一次放行的凭证。对象之外带一个序号:A → B → A 之后先后两次 A 对象相同,序号不同
    public struct Ticket: Equatable {
        public let token: Token
        let serial: Int
    }

    private var inFlight: Ticket?
    private var issued = 0

    public init() {}

    public var isBusy: Bool { inFlight != nil }

    /// 在飞的那个;空闲时为 nil
    public var token: Token? { inFlight?.token }

    /// 能不能为 `token` 开一次。放行时返回这次的票,它已被记为在飞的那张。
    /// 同一个对象不重入,**不同对象必须放行** —— 它们是两件事,不该互相排队。
    public mutating func begin(_ token: Token) -> Ticket? {
        guard inFlight?.token != token else { return nil }
        issued += 1
        let ticket = Ticket(token: token, serial: issued)
        inFlight = ticket
        return ticket
    }

    /// 这一次还算不算数:它之后没有别的被放行过。**提交前必须问** ——
    /// 光比对象不够,先后两次同一个对象长得一样。
    public func isCurrent(_ ticket: Ticket) -> Bool {
        inFlight == ticket
    }

    /// 收尾。只有 `ticket` 仍是在飞的那张才把门空出来 ——
    /// 否则先发起的那次收尾时会把后来者的在飞标记抹成空闲。
    public mutating func finish(_ ticket: Ticket) {
        if inFlight == ticket { inFlight = nil }
    }
}
