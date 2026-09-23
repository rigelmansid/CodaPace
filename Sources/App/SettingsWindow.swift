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

    /// 密钥默认遮起来。**刻意给一个「显示」开关** —— 粘贴错一个字符
    /// 却看不见,只会对着一句「连接失败」反复试。
    @State private var revealSecret = false

    /// 在飞的那次测试对应的是**哪一段输入**。
    /// 没有它就会出现:测试在飞时用户改了网址,旧结果回来照样写进界面,
    /// 于是显示「连接成功」,而那说的是上一个网址。
    @State private var probe = InFlightGate<String>()

    /// 哪个适配器认这段输入,以及它解析出的连接。
    ///
    /// 解析归适配器 —— 「那段输入」是什么本来就因家而异:
    /// 中转站要的是用量页面网址,tu-zi 要的是一把 key。
    private var resolved: (adapter: UsageProviderAdapter, connection: Connection)? {
        ProviderRegistry.parse(input)
    }

    /// 输入里带的是密钥吗。决定输入框要不要遮,以及能不能不测试就保存。
    private var carriesSecret: Bool {
        resolved?.adapter.credentialSensitivity == .secret
    }

    /// 测试成功时的那份报告,否则 nil。
    private var report: ConnectionReport? {
        if case .success(let report) = result { return report }
        return nil
    }

    /// **真正可以保存的那个连接。**
    ///
    /// 身份在响应里的适配器(tu-zi)必须先测试通过 —— 这里才换得出真身份,
    /// 换不出来就是 nil,保存按钮不可用。编一个身份顶上会在真身份到手的那天
    /// 把历史和偏好劈成两半,所以宁可多让用户点一下「测试连接」。
    private var saveable: Connection? {
        guard let resolved else { return nil }
        return ProviderRegistry.resolvedForSaving(resolved.connection, report: report)
    }

    /// 解析得出来、但还差一次测试
    private var needsVerification: Bool { resolved != nil && saveable == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(l10n.t(.setupTitle))
                    .font(.system(size: 14, weight: .semibold))
                // 还认不出是哪家时,不说该填什么 —— 直接把支持列表摆出来,
                // 让用户按自己那家的名字去对。认出来之后再给针对性的指引。
                if resolved == nil {
                    Text(l10n.t(.setupPickYourProvider))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    supportedProviders
                } else {
                    Text(l10n.t(carriesSecret ? .setupDescKey : .setupDesc1))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                // 安全说明**跟着凭据性质走**,不是一句写死的话。
                // 中转站的 apiId 确实动不了钱,而一把 sk- key 能 ——
                // 对后者照搬前者那句,就是做了一个假的安全承诺。
                Text(l10n.t(carriesSecret ? .setupSafetySecret : .setupSafetyIdentifier))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            inputField

            statusLine

            Spacer(minLength: 0)

            HStack {
                Link(l10n.t(.setupSupportedLink),
                     destination: URL(string: "https://github.com/rigelmansid/CodaPace")!)
                    .font(.system(size: 10))

                Spacer()

                Button(l10n.t(.setupTest)) { test() }
                    .disabled(resolved == nil || probe.isBusy)

                Button(l10n.t(.setupSave)) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saveable == nil)
            }
        }
        .padding(20)
        .frame(width: 560, height: 290)
    }

    // MARK: 支持列表

    /// 每家一行:**名字 + 它要什么形状的东西**。
    ///
    /// 这份列表从 `ProviderRegistry.all` 生成,用的是适配器早就有的 `displayName`
    /// 和 `inputExample` —— 通用层不认识任何一家,第三家接进来自动出现在这里
    /// (不变量 6)。
    ///
    /// 它替掉的是原先那句「中转站粘网址,订阅制供应商粘 Key」:那句要求用户
    /// **先给自己归类**,而「中转站」「订阅制」是我们的词。用户知道的是自己用的
    /// 那家叫什么,所以按名字对最省事。
    private var supportedProviders: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(ProviderRegistry.all, id: \.providerID) { adapter in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(adapter.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 130, alignment: .leading)
                    Text(adapter.inputExample)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.top, 1)
    }

    // MARK: 输入框

    /// 带密钥时遮起来,配一个「显示」开关。
    ///
    /// 提示文案取**认出来那家**的示例,认不出来时退回兜底那家 ——
    /// 通用层不该硬编码某一家的格式(不变量 6)。
    @ViewBuilder
    private var inputField: some View {
        HStack(spacing: 6) {
            Group {
                if carriesSecret && !revealSecret {
                    SecureField(placeholder, text: $input)
                } else {
                    TextField(placeholder, text: $input)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .onChange(of: input) { _ in
                // 输入一变,上一次的测试结果就不再说明这段文字了。
                // 对 tu-zi 这还顺带把保存按钮重新锁上 —— 正是要的行为。
                result = .idle
            }

            if carriesSecret {
                Button {
                    revealSecret.toggle()
                } label: {
                    Image(systemName: revealSecret ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help(l10n.t(revealSecret ? .setupHideSecret : .setupRevealSecret))
            }
        }
    }

    private var placeholder: String {
        (resolved?.adapter ?? ProviderRegistry.fallback).inputExample
    }

    // MARK: 状态行

    @ViewBuilder
    private var statusLine: some View {
        switch result {
        case .idle:
            if input.isEmpty {
                hint(l10n.t(.setupWaiting), color: .secondary)
            } else if let resolved {
                VStack(alignment: .leading, spacing: 3) {
                    // 只说「认出是哪家」,不说「能用」—— 那要等真请求跑通
                    hint(l10n.f(.setupRecognizedFormat, resolved.adapter.displayName),
                         color: .secondary)

                    // 保存按钮灰着总得有个理由。这家的账户标识在响应里,
                    // 不测一次就没有身份可存 —— 说清楚,而不是让用户对着
                    // 一个点不动的按钮猜自己哪里填错了。
                    if needsVerification {
                        hint(l10n.t(.setupMustTestFirst), color: .orange)
                    }
                }
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
                let report = try await resolved.adapter.verify(resolved.connection,
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
        guard let saveable else { return }
        do {
            try UsageService.shared.applyAccount(saveable)
            SettingsWindow.shared.close()
        } catch {
            // 钥匙串写失败时**窗口不关**:关掉的话界面会显示已配置,
            // 而每次刷新都取不到密钥,用户只看得到一句「请求失败」。
            result = .failure(error.localizedDescription)
        }
    }
}
