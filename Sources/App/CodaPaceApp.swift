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
        UpdateChecker.shared.start()

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

// MARK: - 菜单栏标签

/// 单独抽成一个 View,只为了拿到**标签所在位置**的 colorScheme(EXT-008)。
///
/// 写在 `App` 里的 `@Environment` 读的是 app 级环境,取回来的是主题设置;
/// 而菜单栏在亮色主题下是深是浅由壁纸决定,两者经常相反。放在这里读,
/// 拿到的才是状态栏那一处的明暗 —— 图标的中性色全靠它解析。
private struct MenuBarLabel: View {

    @ObservedObject var service: UsageService
    /// 也观察语言 —— 否则切换语言后菜单栏那张图不会重绘
    @ObservedObject private var l10n = Localization.shared

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // 整块自绘的原色图,renderingMode(.original) 防止被当模板图渲染成单色
        Image(nsImage: service.menuBarImage(in: appearance))
            .renderingMode(.original)
    }

    /// SwiftUI 只给明暗两态,映射回 AppKit 的外观交给动态颜色解析。
    /// 取不到时退回 app 的外观:那是修复前的老行为,不是更好的选择,只是不至于画不出东西。
    private var appearance: NSAppearance {
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
            ?? NSApplication.shared.effectiveAppearance
    }
}

// MARK: - App

@main
struct CodaPaceApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var service = UsageService.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView(service: service)
        } label: {
            MenuBarLabel(service: service)
        }
        .menuBarExtraStyle(.window)
    }
}
