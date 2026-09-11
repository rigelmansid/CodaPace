//
//  Notifier.swift — 系统通知投递
//
//  该不该发由 Core 的 AlertPolicy 判断,这里只负责申请权限、发送、记账。
//  已发过的去重键存在 UserDefaults 里,重启后依然有效 ——
//  否则每次重启都会把当前周期的告警再发一遍。
//

import Foundation
import UserNotifications

@MainActor
final class Notifier {

    static let shared = Notifier()

    private(set) var lastError: String?
    private var didRequestAuthorization = false

    /// 已发送过的去重键。只留最近 200 条,避免无限增长。
    private var sentKeys: [String] {
        get { UserDefaults.standard.stringArray(forKey: "sentAlertKeys") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(200)), forKey: "sentAlertKeys") }
    }

    /// 未打包运行(比如直接跑二进制)时 UserNotifications 用不了,
    /// 而且会硬崩而不是抛错,所以先自查一次。
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    // MARK: 入口

    func process(_ snapshot: Snapshot, now: Date) {
        guard Config.notificationsEnabled, isAvailable else { return }

        let alerts = AlertPolicy.newAlerts(for: snapshot,
                                           now: now,
                                           alreadySent: Set(sentKeys))
        guard !alerts.isEmpty else { return }

        requestAuthorizationIfNeeded()

        var keys = sentKeys
        for alert in alerts {
            deliver(alert)
            keys.append(alert.dedupeKey)
        }
        sentKeys = keys
    }

    /// 用户在设置里重新打开通知时清账,好让当前周期能再提醒一次
    func resetHistory() {
        UserDefaults.standard.removeObject(forKey: "sentAlertKeys")
    }

    // MARK: 权限

    private func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true

        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
                guard let error else { return }
                Task { @MainActor in self?.lastError = error.localizedDescription }
            }
    }

    // MARK: 发送

    private func deliver(_ alert: QuotaAlert) {
        let language = Localization.shared.language
        let quota = alert.quota.label(language)
        let percent = Fmt.percent(alert.remainingRatio)
        let money = Fmt.money2(alert.remaining)

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

        let request = UNNotificationRequest(identifier: alert.dedupeKey,
                                            content: content,
                                            trigger: nil)

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }
    }
}
