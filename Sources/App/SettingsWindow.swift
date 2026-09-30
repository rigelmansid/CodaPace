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
        } else if window?.isVisible == false {
            // 窗口关上只是藏起来,视图的 @State 会一直留着(OPT-020):没保存就关窗,
            // 再打开时框里还是上次粘的 key 和旧的测试结果,存档行里没回车的改名也像是已生效。
            // 所以每次**重新打开**都换一个新视图。开着的时候再点一次不重建 —— 那会冲掉正在填的
            window?.contentViewController = NSHostingController(rootView: SettingsView())
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

    /// 第二个框:地址认出是哪家、这家要 key 时才出现(「先粘服务地址」,EXT-011)
    @State private var keyInput = ""
    @State private var result: TestResult = .idle

    /// 测试**实际跑通**的那个连接。陌生网址会依次试几种中转站软件,跑通的未必是
    /// `resolved` 里排第一的那家 —— 保存的必须是验过的这一个(EXT-011)
    @State private var verifiedConnection: Connection?

    /// 测试时换来的登录会话先放这里,**保存成功才移交**给正式存储(钥匙串)。
    /// 测试连接什么都不落盘(OPT-017);输入一变就换一份新的,旧的随之丢掉
    @State private var probeSessions = InMemorySessionTokenStore()

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
        ProviderRegistry.parse(input) ?? ProviderRegistry.parse(site: input, key: keyInput)
    }

    /// 第一个框里粘的是服务地址,认出是哪家,而这家接着要一把 key。
    /// 有值时才显示 key 框。
    private var keyOwner: UsageProviderAdapter? {
        guard ProviderRegistry.parse(input) == nil,
              let owner = ProviderRegistry.siteOwner(for: input), owner.keyFollowsSite
        else { return nil }
        return owner
    }

    /// 第一个框里粘的就是密钥(单独粘 key 的老用法)。决定第一个框要不要遮。
    private var inputIsSecret: Bool {
        ProviderRegistry.parse(input)?.adapter.credentialSensitivity == .secret
    }

    /// 这次配置带不带密钥。决定说明文案、安全提示,以及要不要显示「显示密钥」开关。
    private var carriesSecret: Bool {
        (resolved?.adapter ?? keyOwner)?.credentialSensitivity == .secret
    }

    /// 在飞的测试认的是**两个框合起来**那段输入 —— 改了任一个,旧结果都不再说明屏幕上的东西
    private var probeKey: String { input + "\n" + keyInput }

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
        return ProviderRegistry.resolvedForSaving(verifiedConnection ?? resolved.connection, report: report)
    }

    /// 陌生网址会被依次试的那几种中转站软件,给状态行用:「将按 A / B 测试」
    private var guessNames: String {
        ProviderRegistry.all.filter(\.siteMatchIsGuess).map(\.displayName).joined(separator: " / ")
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
            // 只有标题和一个输入框(用户 2026-09-29):从前这里摆着一整份支持列表、
            // 一句「在下面找到你那家」和安全说明,没粘任何东西时就让人不知所措。
            // 各家该粘什么挪进 README,左下角的链接直达;安全说明认出是哪家之后再出现
            Text(l10n.t(.setupTitle))
                .font(.system(size: 14, weight: .semibold))

            inputField

            statusLine

            // 安全说明**跟着凭据性质走**,不是一句写死的话。
            // 中转站的 apiId 确实动不了钱,而一把 sk- key 能 ——
            // 对后者照搬前者那句,就是做了一个假的安全承诺。
            // 认出是哪家之前不说:那时还不知道凭据是哪一种
            if resolved != nil || keyOwner != nil {
                Text(l10n.t(carriesSecret ? .setupSafetySecret : .setupSafetyIdentifier))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !service.archive.entries.isEmpty {
                archiveList
            }

            Spacer(minLength: 0)

            HStack {
                // 直接落到 README 的「支持的服务」那一节,不是仓库首页;
                // 界面是中文就开中文 README —— 各家该粘什么都写在那里
                Link(l10n.t(.setupSupportedLink), destination: supportedServicesURL)
                    .font(.system(size: 10))

                Spacer()

                // 只挡「正在测的就是这段输入」(OPT-020)。改过输入之后旧测试还在飞也要能重测 ——
                // 旧结果回来时过不了提交前的校验,本来就会作废;从前挡的是 isBusy,
                // 陌生网址依次试两家、每个请求 15 秒超时,按钮能灰上几十秒
                Button(l10n.t(.setupTest)) { test() }
                    .disabled(resolved == nil || probe.token == probeKey)

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

    // MARK: 说明文档

    private var supportedServicesURL: URL {
        switch l10n.language {
        case .zhHans, .zhHant:
            return URL(string: "https://github.com/rigelmansid/CodaPace/blob/main/README.zh-CN.md#支持的服务")!
        default:
            return URL(string: "https://github.com/rigelmansid/CodaPace#supported-services")!
        }
    }

    // MARK: 输入框

    /// 带密钥时遮起来,配一个「显示」开关。
    ///
    /// 提示文案取**认出来那家**的示例,认不出来时退回兜底那家 ——
    /// 通用层不该硬编码某一家的格式(不变量 6)。
    @ViewBuilder
    private var inputField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Group {
                    if inputIsSecret && !revealSecret {
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
                    verifiedConnection = nil
                    probeSessions = InMemorySessionTokenStore()
                }

                if inputIsSecret { revealToggle }
            }

            // 地址认出是哪家、这家要 key 时才出现 —— 平时仍是一个框
            if keyOwner != nil {
                HStack(spacing: 6) {
                    Group {
                        if revealSecret {
                            TextField(l10n.t(.setupKeyPlaceholder), text: $keyInput)
                        } else {
                            SecureField(l10n.t(.setupKeyPlaceholder), text: $keyInput)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onChange(of: keyInput) { _ in
                        result = .idle
                        verifiedConnection = nil
                        probeSessions = InMemorySessionTokenStore()
                    }

                    revealToggle
                }
            }
        }
    }

    private var revealToggle: some View {
        Button {
            revealSecret.toggle()
        } label: {
            Image(systemName: revealSecret ? "eye.slash" : "eye")
                .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .help(l10n.t(revealSecret ? .setupHideSecret : .setupRevealSecret))
    }

    /// 第一个框提示的是服务地址 —— 用户在编程工具(Claude Code、Codex 等)里本来就填过的那个(EXT-011)。
    /// 各家具体要什么,在上方的支持列表里按名字对。
    private var placeholder: String { l10n.t(.setupAddressPlaceholder) }

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
                    hint(resolved.adapter.siteMatchIsGuess
                            ? l10n.f(.setupWillTestAsFormat, guessNames)
                            : l10n.f(.setupRecognizedFormat, resolved.adapter.displayName),
                         color: .secondary)

                    // 保存按钮灰着总得有个理由。这家的账户标识在响应里,
                    // 不测一次就没有身份可存 —— 说清楚,而不是让用户对着
                    // 一个点不动的按钮猜自己哪里填错了。
                    // 两种「先测试」理由不同:陌生网址是协议没确认(OPT-016),
                    // tu-zi 是身份在响应里 —— 各说各的,别拿一句去解释另一件事
                    if needsVerification {
                        hint(l10n.t(resolved.adapter.siteMatchIsGuess ? .setupMustTestGuess : .setupMustTestFirst),
                             color: .orange)
                    }
                }
            } else if let keyOwner {
                // 地址认出来了,还差 key。key 填了却拼不出连接,多半是粘错了东西
                if keyInput.isEmpty {
                    hint(l10n.f(keyOwner.siteMatchIsGuess ? .setupSiteGuessFormat : .setupSiteNeedsKeyFormat,
                                keyOwner.siteMatchIsGuess ? guessNames : keyOwner.displayName), color: .secondary)
                } else {
                    hint(l10n.f(.setupKeyUnrecognizedFormat, keyOwner.displayName), color: .orange)
                }
            } else if let owner = ProviderRegistry.siteOwner(for: input) {
                // 粘的是那家的网站而不是凭据。认得出是哪家,就直接指路,
                // 而不是只说一句「认不出」让用户自己去猜该粘什么
                hint(l10n.f(.setupSiteRecognizedFormat, owner.displayName, l10n.t(owner.inputHint)),
                     color: .orange)
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
        case .resetInferred:       return .findResetInferred
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

        // 陌生网址分不出跑的是哪种中转站软件,依次试;专门认得的站点只试它自己
        let attempts = resolved.adapter.siteMatchIsGuess
            ? ProviderRegistry.guesses(site: input, key: keyInput)
            : [resolved]

        // 整个流程只认这一段输入。和刷新那边同一个道理:
        // 中途用户可能已经把网址改了,那这次的结果就不属于屏幕上这段文字了。
        let probed = probeKey
        guard probe.begin(probed) else { return }
        result = .testing
        let sessions = probeSessions

        Task {
            defer { probe.finish(probed) }
            var failures: [String] = []
            for attempt in attempts {
                do {
                    // 只验连通性,这时还没学到任何重置规则,所以给一个默认 schedule
                    let report = try await attempt.adapter.sessionScoped(to: sessions)
                        .verify(attempt.connection, language: l10n.language)
                    // 提交前校验:输入变了就整份丢掉 ——
                    // 否则界面会显示「连接成功」,而那说的是上一个网址
                    guard probeKey == probed else { return }
                    verifiedConnection = attempt.connection
                    result = .success(report)
                    // 预填昵称。已存过的沿用用户起的名字 —— 重测一次不该把它冲掉
                    let account = ProviderRegistry.resolvedForSaving(attempt.connection, report: report)?.account
                    nickname = account.flatMap { service.archive.nickname(for: $0) } ?? report.accountName
                    return
                } catch {
                    failures.append(attempts.count > 1
                        ? "\(attempt.adapter.displayName):\(error.localizedDescription)"
                        : error.localizedDescription)
                }
            }
            // 都没跑通:每一种各自的原因都列出来 —— 分不清站点是哪种软件时,
            // 只报一条会把人引向错的方向
            guard probeKey == probed else { return }
            result = .failure(failures.joined(separator: "\n"))
        }
    }

    /// 切换账户的全部收尾都在 applyAccount 里 —— 落盘、清旧状态、重启定时器、立刻刷一次。
    /// 这里不再逐个字段写 Config:分开写会留下半个账户的中间态。
    private func save() {
        guard let saveable else { return }
        do {
            try UsageService.shared.applyAccount(saveable)
            // 测试时换来的会话到这里才算数:移交给正式存储,刷新就不必再登录一次(OPT-017)。
            // 放在 apply 成功之后 —— 钥匙串写密钥失败时,不该留下一份会话
            if let token = probeSessions.token(for: saveable.account) {
                SessionTokens.store.setToken(token, for: saveable.account)
            }
            // 存档在 apply 成功之后:钥匙串写失败时不该留下一条取不到密钥的存档
            if offersArchive && archiveOnSave {
                service.archiveCurrentAccount(nickname: nickname)
            }
            // 窗口只是藏起来,视图的状态会留到下次打开 —— 保存完就清回初始样子
            input = ""
            keyInput = ""
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
