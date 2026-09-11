//
//  CodaPaceApp.swift — 程序入口
//

import SwiftUI
import AppKit

// MARK: - 应用委托

/// 用 AppDelegate 而不是在视图里 onAppear 启动服务:
/// MenuBarExtra 的面板内容是**点开时才创建**的,放在那里会导致不点就不刷新。
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        UsageService.shared.start()

        // 没配置过就直接把设置窗口推到眼前 —— 否则新用户只会看到一个
        // 写着「未配置」的菜单栏图标,不知道下一步该干什么
        if !Config.isConfigured {
            SettingsWindow.shared.show()
        }

        // 睡眠唤醒后立刻刷一次,避免显示过期数字
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await UsageService.shared.refresh() }
        }
    }
}

// MARK: - App

@main
struct CodaPaceApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var service = UsageService.shared
    // 也观察语言 —— 否则切换语言后菜单栏那张图不会重绘
    @ObservedObject private var l10n = Localization.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView(service: service)
        } label: {
            // 整块自绘的原色图,renderingMode(.original) 防止被当模板图渲染成单色
            Image(nsImage: service.menuBarImage)
                .renderingMode(.original)
        }
        .menuBarExtraStyle(.window)
    }
}
