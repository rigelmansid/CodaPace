//
//  SettingsWindow.swift — 账号配置窗口
//
//  为什么是独立 NSWindow 而不是 sheet:
//  sheet 挂在 MenuBarExtra(.window) 上,面板一失焦就会被关掉,输入框根本没法用。
//  独立窗口还能让 AppDelegate 在首次启动时直接弹出来。
//

import SwiftUI
import AppKit

// MARK: - 窗口宿主

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // 每次打开都重设标题 —— 窗口只创建一次,语言换了标题得跟上
        window?.title = L10n.text(.setupWindowTitle, Localization.shared.language)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
    }
}

// MARK: - 配置界面

struct SettingsView: View {

    /// 「测试连接」的结果
    private enum TestResult: Equatable {
        case idle
        case testing
        case success(name: String, active: Bool)
        case failure(String)
    }

    @ObservedObject private var l10n = Localization.shared

    @State private var input: String = Config.consoleURL?.absoluteString ?? ""
    @State private var result: TestResult = .idle

    /// 网址能不能解析出 base + apiId
    private var parsed: (base: String, apiId: String)? { Config.parse(input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(l10n.t(.setupTitle))
                    .font(.system(size: 14, weight: .semibold))
                Text(l10n.t(.setupDesc1))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(l10n.t(.setupDesc2))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            TextField(l10n.t(.setupPlaceholder), text: $input)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onChange(of: input) { _ in result = .idle }

            statusLine

            Spacer(minLength: 0)

            HStack {
                Link(l10n.t(.setupSupportedLink),
                     destination: URL(string: "https://github.com/Wei-Shaw/claude-relay-service")!)
                    .font(.system(size: 10))

                Spacer()

                Button(l10n.t(.setupTest)) { test() }
                    .disabled(parsed == nil || result == .testing)

                Button(l10n.t(.setupSave)) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(width: 560, height: 260)
    }

    // MARK: 状态行

    @ViewBuilder
    private var statusLine: some View {
        switch result {
        case .idle:
            if input.isEmpty {
                hint(l10n.t(.setupWaiting), color: .secondary)
            } else if parsed == nil {
                hint(l10n.t(.setupNoApiId), color: .red)
            } else {
                hint(l10n.t(.setupParsable), color: .secondary)
            }

        case .testing:
            hint(l10n.t(.setupTesting), color: .secondary)

        case .success(let name, let active):
            hint(l10n.f(.setupSuccessFormat, name,
                        l10n.t(active ? .statusActive : .statusInactive)),
                 color: .green)

        case .failure(let message):
            hint(l10n.f(.setupFailureFormat, message), color: .red)
        }
    }

    private func hint(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 动作

    /// 用输入的凭据真拉一次接口,**不落盘** —— 保存前先确认它是通的
    private func test() {
        guard let parsed else { return }
        result = .testing

        Task {
            do {
                let stats = try await API.userStats(base: parsed.base, apiId: parsed.apiId)
                result = .success(name: stats.name.isEmpty ? "API Key" : stats.name,
                                  active: stats.isActive)
            } catch {
                result = .failure(error.localizedDescription)
            }
        }
    }

    private func save() {
        guard let parsed else { return }
        Config.baseURL = parsed.base
        Config.apiId = parsed.apiId

        let service = UsageService.shared
        service.restartRefreshTimer()
        Task { await service.refresh() }

        SettingsWindow.shared.close()
    }
}
