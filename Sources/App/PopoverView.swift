//
//  PopoverView.swift — 菜单栏下拉面板
//
//  布局原则(参考 CodexMeter 的判断):
//  · 用分隔线分区,不用嵌套卡片背景 —— 菜单栏窗口本身已经提供了容器表面
//  · 头部和底部固定,其余全部可滚,面板总高不超过屏幕可视高度
//  · 状态不能只靠颜色 —— pace 用「图标 + 文字」,配色盲也读得出来
//

import SwiftUI

// MARK: - 版式常量

private enum Metrics {
    static let width: CGFloat = 320
    static let hPad: CGFloat = 14
    /// 设置项右侧控件的统一宽度。约束由 settingRow 统一施加,
    /// 不在每个控件上各写一遍,免得以后加设置项时又跑偏。
    static let controlWidth: CGFloat = 132
}

// MARK: - 状态配色

extension QuotaStatus {
    var color: Color {
        switch self {
        case .normal:   return .primary
        case .warning:  return .orange
        case .critical: return .red
        }
    }
}

// MARK: - 进度条

/// 自己画而不用 ProgressView。
/// 原因:AppKit 的 NSProgressIndicator 在明暗外观切换后会把 tint 卡回默认蓝,
/// 自绘完全绕开这个坑,顺便也能精确控制圆角和高度。
struct Bar: View {
    let ratio: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, ratio)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - 一条额度

struct GaugeRow: View {
    let gauge: QuotaBucket
    let now: Date
    @ObservedObject private var l10n = Localization.shared

    private var status: QuotaStatus { gauge.status(now: now) }
    private var pace: PaceVerdict { gauge.pace(now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(gauge.label(l10n.language))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                paceBadge
            }

            if gauge.unlimited {
                Text("\(l10n.t(.unlimited)) · \(l10n.f(.usedAmountFormat, Fmt.money2(gauge.used)))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                labelledBar(l10n.t(.quotaRemaining),
                            value: Fmt.percent(gauge.remainingRatio),
                            ratio: gauge.remainingRatio,
                            color: status.color)

                // 和菜单栏时间环同一规则:平时和额度条正常态一样,快到重置才变蓝
                if let window = gauge.window {
                    labelledBar(l10n.t(.timeRemaining),
                                value: Fmt.percent(window.remainingRatio(now: now)),
                                ratio: window.remainingRatio(now: now),
                                color: window.isNearingReset(now: now) ? .blue : .primary)
                }

                footer
            }
        }
    }

    @ViewBuilder
    private var paceBadge: some View {
        if let symbol = pace.symbolName {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                Text(pace.label(l10n.language))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(pace.isOverPace ? Color.orange : Color.secondary)
        }
    }

    private func labelledBar(_ title: String, value: String,
                             ratio: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(value).monospacedDigit()
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            Bar(ratio: ratio, color: color)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let window = gauge.window {
                Text(Fmt.resetsIn(window.remainingSeconds(now: now), l10n.language))
                // 重置时刻是推断出来的就如实标注,不能让它看起来像精确值
                if window.isInferred {
                    Text(l10n.t(.inferredSuffix)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text("\(Fmt.money2(gauge.used)) / \(Fmt.money2(gauge.limit))")
                .monospacedDigit()
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
}

// MARK: - 内容高度测量

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 面板

struct PopoverView: View {
    @ObservedObject var service: UsageService
    @ObservedObject private var l10n = Localization.shared
    @StateObject private var history = HistoryModel()
    @ObservedObject private var updates = UpdateChecker.shared

    @State private var showSettings = false

    /// 「其他」额度默认收起 —— 面板第一眼只该看到菜单栏上那一条
    @State private var showOtherGauges = false
    @State private var contentHeight: CGFloat = 0

    /// 面板自己所在的那个窗口。打开设置、历史窗口前先把它关掉 ——
    /// 面板在状态栏层级,不关的话会一直盖在新窗口上面(用户 2026-09-29 实机指出)。
    /// 只关**自己**,不关「当前最前面的窗口」:从设置窗口里再开历史,不该把设置关掉
    @State private var panel: NSWindow?

    /// 滚动区的高度上限。
    /// visibleFrame 已排除菜单栏和程序坞;再减去固定的头部(约 52)、底部(约 34)、
    /// 两条分隔线,并给窗口圆角与投影留些余量。有更新提醒时底部再多一行(约 30)。
    private var maxContentHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        let updateRow: CGFloat = updates.available == nil ? 0 : 30
        return max(180, visible - 120 - updateRow)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            // 只有头部和底部固定,其余**全部**放进滚动区 —— 设置区也在内。
            // 设置展开后会多出一大截高度,若把它当固定部分,面板整体就会超出屏幕,
            // 底部的「退出」反而点不到了。
            ScrollView {
                VStack(spacing: 0) {
                    scrollingContent
                    Divider()
                    settingsSection
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self,
                                               value: geo.size.height)
                    }
                )
            }
            .frame(height: max(120, min(contentHeight, maxContentHeight)))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }

            // 和底部一样固定、不随滚动区走 —— 设置区展开时也一眼能看到
            if let version = updates.available {
                Divider()
                updateRow(version)
            }

            Divider()
            footer
        }
        .frame(width: Metrics.width)
        .background(WindowReader(window: $panel))
        // 面板是点开才创建的,每次打开都重读一次历史;
        // 之后每次刷新拿到新快照也跟着更新
        .onAppear { reloadHistory() }
        .onChange(of: service.snapshot?.fetchedAt) { _ in reloadHistory() }
        // 换「菜单栏显示哪条额度」画的就是另一条额度了。
        // 少了这条,标题会立刻变而曲线要等下一次网络刷新 —— 那段时间里
        // 标题说的是一条额度,曲线画的是另一条。
        .onChange(of: service.menuBarSource) { _ in reloadHistory() }
        // 换账户 = 换一整个历史库,且不一定伴随快照变化(两边都离线时都是 nil)
        .onChange(of: service.accountGeneration) { _ in reloadHistory() }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(l10n.t(.appTitle)).font(.system(size: 13, weight: .semibold))
            HStack(alignment: .firstTextBaseline) {
                if let line = accountLine {
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                refreshButton
            }
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 11)
    }

    /// 头部第二行:正在用的是哪个账户,以及它的状态。
    ///
    /// 名字优先用**用户存档时起的**(EXT-010)—— 存了多个账户之后,对方报的账户名
    /// 未必分得开(两个中转站账户都可能叫 default)。没存档就用对方报的名字。
    /// 状态只有快照在时才说:没拿到数据时说 Active 是编的(不变量 3)。
    private var accountLine: String? {
        let nickname = service.archive.nickname(for: Config.account)
        guard let snapshot = service.snapshot else { return nickname }
        let status = l10n.t(snapshot.isActive ? .statusActive : .statusInactive)
        return "\(nickname ?? snapshot.name) · \(status)"
    }

    /// 刷新按钮。刷新在飞时图标一直转,直到结束。
    ///
    /// 用 TimelineView 按时间算角度,而不是 `repeatForever` 动画 ——
    /// 后者在 isLoading 变回 false 时停不干净(会跳回原位或继续转完一圈)。
    /// 暂停后角度直接归零,停在哪都一样。
    ///
    /// 转轴必须是**圆弧的圆心**,不是图标边框的中心。`arrow.clockwise` 的箭头头部
    /// 从圆顶上伸出去,边框因此比圆高出一截,绕边框中心转会一上一下地晃。
    /// 锚点是把符号放大渲染、量出圆弧外沿(左、右、下三个极值)算的:
    /// 横向正好居中,纵向在边框高度的 57.9% 处。换了符号得重新量。
    private static let refreshArcCenter = UnitPoint(x: 0.4988, y: 0.579)

    private var refreshButton: some View {
        Button {
            Task { await service.refresh() }
        } label: {
            TimelineView(.animation(paused: !service.isLoading)) { context in
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(service.isLoading
                        ? context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1) * 360
                        : 0),
                        anchor: Self.refreshArcCenter)
            }
        }
        .buttonStyle(.borderless)
        .disabled(service.isLoading)
    }

    // MARK: 滚动区

    @ViewBuilder
    private var scrollingContent: some View {
        if !Config.isConfigured {
            unconfigured
        } else if let snapshot = service.snapshot {
            gauges(snapshot)
            Divider()
            chartSection
            Divider()
            summarySection(snapshot)
        } else if let error = service.errorText {
            message(l10n.t(.stateOfflineTitle), detail: error, offersSetup: true)
        } else {
            message(l10n.t(.stateLoading), detail: nil)
        }
    }

    /// 额度区:顶上是**菜单栏正在显示的那一条**,其余收进「其他」。
    ///
    /// 顶上那条直接取 `service.menuBarGauge` —— 菜单栏画的就是它,固定选择失效时
    /// 退回自动、自动模式下挑最紧的那条,这些规则都在它里面。面板自己再判一遍
    /// 的话,两边迟早对不上(不变量 5)。
    ///
    /// 一条有上限的额度都没有时,菜单栏没有主角(显示的是用量本身),
    /// 这里也就没有可置顶的,全部平铺,不折叠。
    @ViewBuilder
    private func gauges(_ snapshot: Snapshot) -> some View {
        if let featured = service.menuBarGauge {
            gaugeRow(featured)
            let others = snapshot.gauges.filter { $0.id != featured.id }
            if !others.isEmpty {
                Divider()
                otherGauges(others)
            }
        } else {
            gaugeList(snapshot.gauges)
        }
    }

    private func gaugeList(_ gauges: [QuotaBucket]) -> some View {
        ForEach(Array(gauges.enumerated()), id: \.offset) { index, gauge in
            if index > 0 { Divider().padding(.leading, Metrics.hPad) }
            gaugeRow(gauge)
        }
    }

    private func gaugeRow(_ gauge: QuotaBucket) -> some View {
        GaugeRow(gauge: gauge, now: service.now)
            .padding(.horizontal, Metrics.hPad)
            .padding(.vertical, 10)
    }

    /// 可折叠的「其他」,外观和下面的设置区同一个样式
    private func otherGauges(_ gauges: [QuotaBucket]) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showOtherGauges.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showOtherGauges ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(l10n.t(.otherGauges)).font(.system(size: 12))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Metrics.hPad)
            .padding(.vertical, 9)

            if showOtherGauges {
                gaugeList(gauges)
            }
        }
    }

    /// 「累计」那一行的文字。两项都没有就返回 nil —— 整行不显示。
    private func totalsLine(_ snapshot: Snapshot) -> String? {
        let parts = [
            snapshot.totalRequests.map { l10n.f(.requestsShortFormat, Fmt.int($0)) },
            snapshot.totalTokens.map { "\(Fmt.count($0)) tokens" },
        ].compactMap { $0 }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func summarySection(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let cost = snapshot.monthlyCost {
                summary(l10n.t(.summaryMonthly), Fmt.money2(cost)
                        + (snapshot.monthlyRequests.map { " · " + l10n.f(.requestsFormat, Fmt.int($0)) } ?? ""))
            }
            // 这一行**只在供应商真的报了累计值时才出现**。
            //
            // 从前它是无条件的,于是不报累计值的供应商(tu-zi 就一个都不报)
            // 会在这里显示「0 次请求 · 0 tokens」—— 把一个我们并不知道的数字
            // 说成了事实。两项各自可选:报了请求数没报 token 也照样显示得出来。
            if let line = totalsLine(snapshot) {
                summary(l10n.t(.summaryTotal), line)
            }

            // 有旧数据但最近一次刷新失败 —— 数字还留着,但要说清楚它可能过期了
            if let error = service.errorText {
                Text(l10n.f(.stateStaleFormat, error))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 10)
    }

    private func summary(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11))
    }

    private var unconfigured: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.t(.stateNotConfigured)).font(.system(size: 12, weight: .medium))
            Text(l10n.t(.stateNotConfiguredDetail))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button(l10n.t(.stateOpenSetup)) { present(SettingsWindow.shared.show) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 18)
    }

    /// - Parameter offersSetup: 给一个去设置窗口的按钮。取不到数据时要用:
    ///   切到一个钥匙串里已没有密钥的存档账户,落到的就是这一支,报错让人
    ///   「重新填写」—— 不给按钮的话得去折叠区里找「配置账号」(EXT-010)。
    ///   认证失效等其他错误同样用得上。
    private func message(_ title: String, detail: String?, offersSetup: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if offersSetup {
                Button(l10n.t(.stateOpenSetup)) { present(SettingsWindow.shared.show) }
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 18)
    }

    // MARK: 图表缩略

    private var chartSection: some View {
        VStack(spacing: 0) {
            miniChart(title: l10n.t(.chartQuotaTrend),
                      detail: "\(service.menuBarGauge?.label(l10n.language) ?? l10n.t(.quotaDaily)) · \(l10n.t(.chartLast24h))") {
                // 同历史窗口:空曲线有两种原因,别把「有采样但算不出百分比」
                // 说成「还没有采样」
                if !history.quotaPoints.isEmpty {
                    QuotaChart(points: history.quotaPoints,
                               connectors: history.quotaConnectors,
                               gaps: history.gaps)
                } else if history.quotaSamplesInRange > 0 {
                    ChartPlaceholder(message: l10n.t(.chartNoPercentage))
                } else {
                    ChartPlaceholder(message: l10n.t(.chartNoSamples))
                }
            }

            Divider().padding(.leading, Metrics.hPad)

            miniChart(title: l10n.t(.chartTokenUsage), detail: l10n.t(.chartLast30d)) {
                if history.tokenBars.isEmpty {
                    ChartPlaceholder(message: l10n.t(.chartNoTokenDays))
                } else {
                    TokenChart(bars: history.tokenBars)
                }
            }
        }
    }

    private func miniChart<Content: View>(title: String, detail: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        Button {
            present(HistoryWindow.shared.show)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                content().frame(height: 46)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 10)
    }

    private func reloadHistory() {
        // 缩略图画的就是菜单栏此刻显示的那条额度,两处必须一致 ——
        // 否则用户点开面板,看到的曲线和菜单栏上的数字对不上。
        // 没有快照时 gauge 为 nil,曲线留空,token 柱状图照常。
        let gauge = service.menuBarGauge
        history.reload(bucketID: gauge?.id,
                       rule: gauge?.rule,
                       quotaDays: 1,
                       tokenDays: 30)
    }

    // MARK: 设置

    private var settingsSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showSettings.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showSettings ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                    Text(l10n.t(.settings)).font(.system(size: 12))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Metrics.hPad)
            .padding(.vertical, 9)

            if showSettings {
                VStack(spacing: 2) {
                    groupHeader(l10n.t(.groupDisplay))

                    settingRow(l10n.t(.rowMenuBarSource)) {
                        // 候选来自**当前快照实际有哪些额度**,不再是固定四项(EXT-001)——
                        // 供应商各报各的,枚举装不下。离线或还没拉到时列表为空,
                        // 此时只剩「自动」可选,而那本来就是拿不到额度时唯一说得通的选项。
                        Picker("", selection: $service.menuBarSource) {
                            Text(l10n.t(.sourceAuto)).tag(MenuBarSource.auto)
                            ForEach(service.snapshot?.gauges ?? [], id: \.id) { bucket in
                                Text(bucket.label(l10n.language))
                                    .tag(MenuBarSource.fixed(bucketID: bucket.id))
                            }
                        }
                        .labelsHidden()
                    }

                    settingRow(l10n.t(.rowMenuBarStyle)) {
                        Picker("", selection: $service.menuBarStyle) {
                            ForEach(MenuBarStyle.allCases) { style in
                                Text(style.label(l10n.language)).tag(style)
                            }
                        }
                        .labelsHidden()
                    }

                    settingRow(l10n.t(.rowRefreshInterval)) {
                        Picker("", selection: $service.refreshInterval) {
                            Text(l10n.f(.durSecondsFormat, 15)).tag(15.0)
                            Text(l10n.f(.durSecondsFormat, 30)).tag(30.0)
                            Text(l10n.f(.durMinutesFormat, 1)).tag(60.0)
                            Text(l10n.f(.durMinutesFormat, 2)).tag(120.0)
                            Text(l10n.f(.durMinutesFormat, 5)).tag(300.0)
                        }
                        .labelsHidden()
                    }

                    settingRow(l10n.t(.rowNotifications)) {
                        Toggle("", isOn: $service.notificationsEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                    }

                    groupHeader(l10n.t(.groupAccount))

                    if let url = Config.consoleURL {
                        actionRow(l10n.t(.rowOpenConsole)) { NSWorkspace.shared.open(url) }
                    }
                    actionRow(l10n.t(.rowConfigureAccount)) { present(SettingsWindow.shared.show) }

                    groupHeader(l10n.t(.groupLanguage))

                    settingRow(l10n.t(.rowLanguage)) {
                        Picker("", selection: $l10n.language) {
                            ForEach(Language.allCases) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .labelsHidden()
                    }
                }
                .padding(.bottom, 9)
            }
        }
    }

    /// 分组标题。缩进和上方留白把三组分开,不用再加分隔线 ——
    /// 面板里已经有不少横线了,再加会更碎。
    private func groupHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    /// 会打开另一个窗口的动作,做成 macOS 系统设置那样整行可点、右侧带 › 的导航行。
    /// 标题用主色而非次色,和上面那些「字段标签」区分开 —— 这行本身是可点的。
    private func actionRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 11))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Metrics.hPad)
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private func settingRow<Content: View>(_ title: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            content()
                .frame(width: Metrics.controlWidth, alignment: .trailing)
        }
        .padding(.horizontal, Metrics.hPad)
    }

    // MARK: 底部

    /// 只提醒不安装:打开 Release 页面,由用户自己下载或跑命令行重装(见 UpdateChecker 文件头)
    private func updateRow(_ version: ReleaseVersion) -> some View {
        Button { NSWorkspace.shared.open(UpdateChecker.releasePage) } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12))
                Text(l10n.f(.updateAvailableFormat, version.text))
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
            .padding(.horizontal, Metrics.hPad)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            if let snapshot = service.snapshot {
                Text(l10n.f(.updatedAt, Fmt.time(snapshot.fetchedAt)))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(l10n.t(.quit)) { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 9)
    }
}

// MARK: - 打开独立窗口

extension PopoverView {
    /// 先收起面板,再开新窗口
    fileprivate func present(_ show: () -> Void) {
        panel?.close()
        show()
    }
}

/// 读出 SwiftUI 视图所在的 NSWindow。MenuBarExtra 没有「收起面板」的 API,只能拿到窗口自己关
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // 视图刚建好时还没挂进窗口,下一轮再读
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window !== nsView.window {
            DispatchQueue.main.async { window = nsView.window }
        }
    }
}
