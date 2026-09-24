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

    /// 存档列表在它身上(EXT-010)。观察它,面板那边切了账户,这里「当前」标记跟着变
    @ObservedObject private var service = UsageService.shared

    /// 输入框每次打开都是空的。
    ///
    /// 从前预填当前账户的网址,且窗口只建一次、保存后也不清 —— 于是再打开时
    /// 框里总是上一次配置的东西,像是还没保存。存过的账户现在在下面的存档列表里,
    /// 输入框只管「配置一个新的」(EXT-010,用户实机后提出)。
    @State private var input = ""
    @State private var result: TestResult = .idle

    /// 密钥默认遮起来。**刻意给一个「显示」开关** —— 粘贴错一个字符
    /// 却看不见,只会对着一句「连接失败」反复试。
    @State private var revealSecret = false

    /// 在飞的那次测试对应的是**哪一段输入**。
    /// 没有它就会出现:测试在飞时用户改了网址,旧结果回来照样写进界面,
    /// 于是显示「连接成功」,而那说的是上一个网址。
    @State private var probe = InFlightGate<String>()

    /// 保存时是否同时存档,以及叫什么(EXT-010)。
    ///
    /// 默认勾上:这个功能的全部意义就是下次不用再粘一遍。
    /// 昵称在测试通过那一刻预填 —— 已存过的沿用用户起的名字,没存过的用
    /// `ConnectionReport.accountName`。强制从空白填起是给常见路径加摩擦。
    @State private var archiveOnSave = true
    @State private var nickname = ""

    /// 等待确认删除的那一条。删除要连带钥匙串,必须先问
    @State private var pendingDelete: ArchivedAccount?

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

    /// 存档的时机是「测试通过」—— 没测过的连接不给存档选项
    private var offersArchive: Bool { report != nil && saveable != nil }

    /// 勾了存档却把名字清空了。保存按钮因此灰着,理由就是旁边那个空着的名字框
    private var archiveNameMissing: Bool {
        offersArchive && archiveOnSave
            && nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 管理列表占的高度。窗口是固定尺寸的,列表多一行就得跟着长;
    /// 超过四行在列表里滚,不让窗口无限变高。
    private var archiveListHeight: CGFloat {
        service.archive.entries.isEmpty ? 0 : CGFloat(min(service.archive.entries.count, 4)) * 26
    }

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

            if !service.archive.entries.isEmpty {
                archiveList
            }

            Spacer(minLength: 0)

            HStack {
                // 直接落到 README 的支持列表那一节,不是仓库首页
                Link(l10n.t(.setupSupportedLink),
                     destination: URL(string: "https://github.com/rigelmansid/CodaPace#supported-services")!)
                    .font(.system(size: 10))

                Spacer()

                Button(l10n.t(.setupTest)) { test() }
                    .disabled(resolved == nil || probe.isBusy)

                Button(l10n.t(.setupSave)) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saveable == nil || archiveNameMissing)
            }
        }
        .padding(20)
        .frame(width: 560,
               height: 290
                   + (offersArchive ? 28 : 0)
                   + (archiveListHeight > 0 ? archiveListHeight + 36 : 0))
        .alert(l10n.f(.archiveDeleteTitleFormat, pendingDelete?.nickname ?? ""),
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { entry in
            Button(l10n.t(.archiveDelete), role: .destructive) { forget(entry) }
            Button(l10n.t(.archiveCancel), role: .cancel) {}
        } message: { entry in
            // 密钥和历史各自的去向都要说;不带密钥的那家没有钥匙串这回事,不提
            let hasSecret = ProviderRegistry.adapter(for: entry.account).credentialSensitivity == .secret
            Text(l10n.t(hasSecret ? .archiveDeleteMessageSecret : .archiveDeleteMessagePlain))
        }
    }

    // MARK: 存档管理(EXT-010)

    /// 切换、改名、删除都在这里。切换原先放在面板顶上的下拉里,用户看过实机后
    /// 决定面板头部只显示账户名,切换挪到这张列表(EXT-010)。
    private var archiveList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.t(.archiveSectionTitle))
                .font(.system(size: 11, weight: .medium))
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(service.archive.entries, id: \.account) { entry in
                        ArchiveRow(entry: entry,
                                   isCurrent: entry.account == Config.account,
                                   onDelete: { pendingDelete = entry })
                            // 名字在别处改了(或改名被拒)时,重建这一行以丢掉旧草稿
                            .id(entry.nickname)
                    }
                }
            }
            .frame(height: archiveListHeight)
        }
    }

    private func forget(_ entry: ArchivedAccount) {
        do {
            try service.forgetArchived(entry.account)
        } catch {
            // 钥匙串删失败时列表原样不动 —— 如实说出来,别让人以为删掉了
            result = .failure(error.localizedDescription)
        }
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
                if offersArchive {
                    HStack(spacing: 6) {
                        Toggle(l10n.t(.archiveOnSave), isOn: $archiveOnSave)
                            .font(.system(size: 11))
                        TextField(l10n.t(.archiveNicknamePlaceholder), text: $nickname)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .frame(width: 200)
                            .disabled(!archiveOnSave)
                    }
                    .padding(.top, 4)
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
                // 预填昵称。已存过的沿用用户起的名字 —— 重测一次不该把它冲掉
                let account = ProviderRegistry.resolvedForSaving(resolved.connection, report: report)?.account
                nickname = account.flatMap { service.archive.nickname(for: $0) } ?? report.accountName
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
            // 存档在 apply 成功之后:钥匙串写失败时不该留下一条取不到密钥的存档
            if offersArchive && archiveOnSave {
                service.archiveCurrentAccount(nickname: nickname)
            }
            // 窗口只是藏起来,视图的状态会留到下次打开 —— 保存完就清回初始样子
            input = ""
            result = .idle
            revealSecret = false
            archiveOnSave = true
            nickname = ""
            SettingsWindow.shared.close()
        } catch {
            // 钥匙串写失败时**窗口不关**:关掉的话界面会显示已配置,
            // 而每次刷新都取不到密钥,用户只看得到一句「请求失败」。
            result = .failure(error.localizedDescription)
        }
    }
}

// MARK: - 存档行

/// 一条存档:可改的名字、哪一家、切换按钮(当前那条是「当前」标记)、删除按钮。
///
/// 名字用本地草稿,按回车才提交 —— 每敲一个字就写一次的话,清空重打的
/// 中间那一刻会被 `AccountArchive.rename` 以「空白」拒掉,来回跳。
private struct ArchiveRow: View {
    let entry: ArchivedAccount
    let isCurrent: Bool
    let onDelete: () -> Void

    @ObservedObject private var l10n = Localization.shared
    @State private var draft: String

    init(entry: ArchivedAccount, isCurrent: Bool, onDelete: @escaping () -> Void) {
        self.entry = entry
        self.isCurrent = isCurrent
        self.onDelete = onDelete
        _draft = State(initialValue: entry.nickname)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: 200)
                .help(l10n.t(.archiveRenameHelp))
                .onSubmit {
                    // 改成空白被拒时退回原名,不让框里留着一个没生效的名字
                    if !UsageService.shared.renameArchived(entry.account, to: draft) {
                        draft = entry.nickname
                    }
                }

            Text(ProviderRegistry.adapter(for: entry.account).displayName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            // 当前那一行不给切换按钮 —— 切到自己什么也不发生,换成「当前」标记
            if isCurrent {
                Text(l10n.t(.archiveCurrentTag))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Button(l10n.t(.archiveSwitch)) {
                    UsageService.shared.selectAccount(entry.account)
                }
                .controlSize(.small)
            }

            // 当前账户不许删(EXT-010)。灰掉的按钮在 AppKit 里不显示 tooltip,
            // 所以说明挂在外面这层上
            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(isCurrent)
            .padding(2)
            .contentShape(Rectangle())
            .help(l10n.t(isCurrent ? .archiveDeleteCurrentHelp : .archiveDelete))
        }
        .frame(height: 24)
    }
}
