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
        case success(ConnectionReport)
        case failure(String)
    }

    @ObservedObject private var l10n = Localization.shared

    @State private var input: String = Config.consoleURL?.absoluteString ?? ""
    @State private var result: TestResult = .idle

    /// 在飞的那次测试对应的是**哪一段输入**。
    /// 没有它就会出现:测试在飞时用户改了网址,旧结果回来照样写进界面,
    /// 于是显示「连接成功」,而那说的是上一个网址。
    @State private var probe = InFlightGate<String>()

    /// 哪个适配器认这个网址,以及它解析出的连接身份。
    /// 解析归适配器 —— 不同供应商的链接格式、路径前缀都不一样。
    private var resolved: (adapter: UsageProviderAdapter, account: AccountIdentity)? {
        ProviderRegistry.parse(input)
    }

    private var parsed: AccountIdentity? { resolved?.account }

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

            TextField(ProviderRegistry.fallback.inputExample, text: $input)
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
                    .disabled(parsed == nil || probe.isBusy)

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
            } else if let resolved {
                // 只说「认出是哪家」,不说「能用」—— 那要等真请求跑通
                hint(l10n.f(.setupRecognizedFormat, resolved.adapter.displayName),
                     color: .secondary)
            } else {
                // 认不出来就如实说认不出来,不猜一个出来
                hint(l10n.t(.setupUnsupported), color: .red)
            }

        case .testing:
            hint(l10n.t(.setupTesting), color: .secondary)

        case .success(let report):
            VStack(alignment: .leading, spacing: 3) {
                hint(l10n.f(.setupSuccessFormat, report.accountName,
                            l10n.t(report.isActive ? .statusActive : .statusInactive)),
                     color: .green)
                // 保存之前就把已知局限讲清楚,而不是等用户以后自己发现
                ForEach(report.findings, id: \.self) { finding in
                    hint("· " + l10n.t(label(for: finding)), color: .secondary)
                }
            }

        case .failure(let message):
            hint(l10n.f(.setupFailureFormat, message), color: .red)
        }
    }

    private func label(for finding: ConnectionReport.Finding) -> LangKey {
        switch finding {
        case .noLimitedQuota:      return .findNoLimitedQuota
        case .incompleteUsage:     return .findIncompleteUsage
        case .dailyResetInferred:  return .findDailyResetInferred
        case .noResetWindow:       return .findNoResetWindow
        case .historyIsLocalOnly:  return .findHistoryIsLocalOnly
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

    /// 用输入的凭据真拉一次接口,**不落盘** —— 保存前先确认它是通的。
    ///
    /// 走的是和正式刷新完全相同的入口:域名或路径像不像都不算数,
    /// 只有真请求跑通才算确认这个适配器认得对方的协议。
    private func test() {
        guard let resolved else { return }

        // 整个流程只认这一段输入。和刷新那边同一个道理:
        // 中途用户可能已经把网址改了,那这次的结果就不属于屏幕上这段文字了。
        let probed = input
        guard probe.begin(probed) else { return }
        result = .testing

        Task {
            defer { probe.finish(probed) }
            do {
                // 只验连通性,这时还没学到任何重置规则,所以给一个默认 schedule
                let report = try await resolved.adapter.verify(resolved.account,
                                                               language: l10n.language)
                // 提交前校验:输入变了就整份丢掉 ——
                // 否则界面会显示「连接成功」,而那说的是上一个网址
                guard input == probed else { return }
                result = .success(report)
            } catch {
                guard input == probed else { return }
                result = .failure(error.localizedDescription)
            }
        }
    }

    /// 切换账户的全部收尾都在 applyAccount 里 —— 落盘、清旧状态、重启定时器、立刻刷一次。
    /// 这里不再逐个字段写 Config:分开写会留下半个账户的中间态。
    private func save() {
        guard let parsed else { return }
        UsageService.shared.applyAccount(parsed)
        SettingsWindow.shared.close()
    }
}
