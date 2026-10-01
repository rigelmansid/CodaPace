//
//  Notifier.swift — 系统通知投递
//
//  该不该发由 Core 的 AlertPolicy 判断,账本由 Core 的 AlertLedger 管,
//  这里只负责问权限、投递、把账本落盘。
//
//  两处顺序是正确性的一部分:
//  · 权限要**等结果**再投递 —— 从前是 fire-and-forget,拒了也照发;
//  · 只有系统**确实收下**才记进账本 —— 从前不论成败都记,于是失败的那条
//    在这一整个周期内再也不会重试。
//

import Foundation
import UserNotifications

@MainActor
final class Notifier {

    static let shared = Notifier()

    private(set) var lastError: String?

    /// 当前账户的账本。换账户时整本换掉 —— 命名空间不同。
    private var ledger: AlertLedger?

    /// 未打包运行(比如直接跑二进制)时 UserNotifications 用不了,
    /// 而且会硬崩而不是抛错,所以先自查一次。
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    // MARK: 入口

    /// - Parameter account: 这份快照属于哪个账户。由刷新流程在开头定住后传进来 ——
    ///   去重账本要按账户分开,不能在这里读全局配置。
    func process(_ snapshot: Snapshot, now: Date, account: AccountIdentity) {
        guard Config.notificationsEnabled, isAvailable, account.isConfigured else { return }

        var book = ledger(for: account)

        // 先占位再异步投递:投递要等权限和系统回执,期间下一次刷新会算出同一条告警
        let claimed = AlertPolicy.candidates(for: snapshot, now: now)
            .filter { book.beginDelivery($0) }

        ledger = book
        guard !claimed.isEmpty else { return }

        // 存了不止一个账户时,副标题写上是哪个(OPT-028)—— 否则两个账户的同名额度
        // 发来的通知长得一模一样。只有一个账户时不写,多一行字没有信息量
        let archive = Config.archive
        let subtitle = archive.entries.count > 1 ? archive.nickname(for: account) : nil

        Task { await deliver(claimed, namespace: book.namespace, subtitle: subtitle) }
    }

    /// 用户在设置里重新打开通知时清当前账户的账,好让这个周期能再提醒一次
    func resetHistory() {
        var book = ledger(for: Config.account)
        book.clear()
        ledger = book
        persist()
    }

    /// 换账户后调用:丢掉内存里那本,下次按新命名空间重新加载。
    ///
    /// **不清空**旧账户的记录 —— 切回去时它已经发过的告警仍该去重。
    /// 从前靠「切换时清空」来缓解跨账户串扰,现在命名空间本身就隔离了。
    func accountDidChange() {
        ledger = nil
    }

    // MARK: 投递

    private func deliver(_ alerts: [QuotaAlert], namespace: String, subtitle: String?) async {
        guard await isAuthorized() else {
            // 被拒:**不留"已发过"的记录**,权限恢复后同周期内还能补发
            abandon(alerts, namespace: namespace)
            return
        }

        for (index, alert) in alerts.enumerated() {
            // 每条投递前重验(OPT-022)。上面等权限、上一条等系统回执,都跨过了 await ——
            // 首次弹授权框时用户可能盯着它好一会儿,期间切了账户或关了通知。
            // 从前只在账本那一步核对身份,而那时系统已经收下了:旧账户的通知照样弹出来。
            // 开关更是只在最初的 process 里看过一次
            guard Config.notificationsEnabled,
                  Config.account.notificationNamespace == namespace else {
                abandon(Array(alerts[index...]), namespace: namespace)
                return
            }
            do {
                try await UNUserNotificationCenter.current().add(request(for: alert, namespace: namespace, subtitle: subtitle))
                // 到这一步才算发过。面板上那句错误也到此为止 —— 它现在会显示出来(OPT-028),
                // 不清的话一次失败会一直挂在那里
                lastError = nil
                guard update(namespace: namespace, { $0.confirm(alert) }) else { return }
            } catch {
                lastError = error.localizedDescription
                guard update(namespace: namespace, { $0.abandon(alert) }) else { return }
            }
        }
        persist()
    }

    private func abandon(_ alerts: [QuotaAlert], namespace: String) {
        for alert in alerts {
            guard update(namespace: namespace, { $0.abandon(alert) }) else { return }
        }
    }

    /// 改动账本。返回 false 表示**账户已经换了** —— 这批结果不属于当前这本,整批丢掉。
    /// 和刷新、测试连接同一个道理:跨过 await 之后要先验身份。
    private func update(namespace: String, _ change: (inout AlertLedger) -> Void) -> Bool {
        guard var book = ledger, book.namespace == namespace else { return false }
        change(&book)
        ledger = book
        return true
    }

    // MARK: 权限

    /// 每次都读**真实状态**,不缓存结果 ——
    /// 用户可能在系统设置里改过,缓存一个布尔量就再也看不见了。
    private func isAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                lastError = error.localizedDescription
                return false
            }
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    // MARK: 内容

    private func request(for alert: QuotaAlert, namespace: String, subtitle: String?) -> UNNotificationRequest {
        let language = Localization.shared.language
        let quota = alert.title.text(language)
        let percent = Fmt.percent(alert.remainingRatio)
        // 按**那条额度自己的单位**排版。写死 Fmt.money2 会给单位未知的额度
        // 打上一个我们并不知道的币种(EXT-001)。
        let money = alert.unit.amount(alert.remaining)

        let content = UNMutableNotificationContent()
        switch alert.kind {
        case .lowQuota:
            content.title = L10n.format(.notifyLowTitleFormat, language, quota)
            content.body = L10n.format(.notifyLowBodyFormat, language, percent, money)
        case .overPace:
            content.title = L10n.format(.notifyPaceTitleFormat, language, quota)
            content.body = L10n.format(.notifyPaceBodyFormat, language, percent, money)
        }
        content.sound = .default
        if let subtitle { content.subtitle = subtitle }

        // identifier 带上账户命名空间(OPT-022):两个中转站账户的日额度都在 0 点重置时
        // dedupeKey 完全相同,系统会拿后一个账户的通知原地顶掉前一个的
        return UNNotificationRequest(identifier: "\(namespace)|\(alert.dedupeKey)",
                                     content: content, trigger: nil)
    }

    // MARK: 账本存取

    private func ledger(for account: AccountIdentity) -> AlertLedger {
        let namespace = account.notificationNamespace
        if let ledger, ledger.namespace == namespace { return ledger }

        let stored = UserDefaults.standard.stringArray(forKey: Self.storageKey(namespace)) ?? []
        let loaded = AlertLedger(namespace: namespace, sent: stored)
        ledger = loaded
        return loaded
    }

    private func persist() {
        guard let ledger else { return }
        UserDefaults.standard.set(ledger.storedKeys, forKey: Self.storageKey(ledger.namespace))
    }

    private static func storageKey(_ namespace: String) -> String { "sentAlertKeys.\(namespace)" }

    /// 清掉旧版那本**全局**账。
    ///
    /// 刻意不迁移:那些键不带账户,安到任何一个账户头上都是猜。丢掉的代价很小 ——
    /// 最多在当前周期内多发一条通知,而方向是对的(宁可重复,不可漏报)。
    static func discardLegacyGlobalLedger() {
        UserDefaults.standard.removeObject(forKey: "sentAlertKeys")
    }
}
