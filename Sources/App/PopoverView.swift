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
    let gauge: Gauge
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

                if let window = gauge.window {
                    labelledBar(l10n.t(.timeRemaining),
                                value: Fmt.percent(window.remainingRatio(now: now)),
                                ratio: window.remainingRatio(now: now),
                                color: .blue)
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

    @State private var showSettings = false
    @State private var contentHeight: CGFloat = 0

    /// 滚动区的高度上限。
    /// visibleFrame 已排除菜单栏和程序坞;再减去固定的头部(约 52)、底部(约 34)、
    /// 两条分隔线,并给窗口圆角与投影留些余量。
    private var maxContentHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        return max(180, visible - 120)
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

            Divider()
            footer
        }
        .frame(width: Metrics.width)
        // 面板是点开才创建的,每次打开都重读一次历史;
        // 之后每次刷新拿到新快照也跟着更新
        .onAppear { reloadHistory() }
        .onChange(of: service.snapshot?.fetchedAt) { _ in reloadHistory() }
    }

    // MARK: 头部

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(l10n.t(.appTitle)).font(.system(size: 13, weight: .semibold))
                if let snapshot = service.snapshot {
                    Text("\(snapshot.name) · \(l10n.t(snapshot.isActive ? .statusActive : .statusInactive))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await service.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(service.isLoading)
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 11)
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
            message(l10n.t(.stateOfflineTitle), detail: error)
        } else {
            message(l10n.t(.stateLoading), detail: nil)
        }
    }

    private func gauges(_ snapshot: Snapshot) -> some View {
        ForEach(Array(snapshot.gauges.enumerated()), id: \.offset) { index, gauge in
            if index > 0 { Divider().padding(.leading, Metrics.hPad) }
            GaugeRow(gauge: gauge, now: service.now)
                .padding(.horizontal, Metrics.hPad)
                .padding(.vertical, 10)
        }
    }

    private func summarySection(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let cost = snapshot.monthlyCost {
                summary(l10n.t(.summaryMonthly), Fmt.money2(cost)
                        + (snapshot.monthlyRequests.map { " · " + l10n.f(.requestsFormat, Fmt.int($0)) } ?? ""))
            }
            summary(l10n.t(.summaryTotal),
                    l10n.f(.requestsShortFormat, Fmt.int(snapshot.totalRequests))
                    + " · \(Fmt.count(snapshot.totalTokens)) tokens")

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
            Button(l10n.t(.stateOpenSetup)) { SettingsWindow.shared.show() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 18)
    }

    private func message(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
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
                if history.quotaPoints.isEmpty {
                    ChartPlaceholder(message: l10n.t(.chartNoSamples))
                } else {
                    QuotaChart(points: history.quotaPoints,
                               connectors: history.quotaConnectors,
                               gaps: history.gaps)
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
            HistoryWindow.shared.show()
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
        let gauge = service.menuBarGauge
        history.reload(kind: gauge?.kind ?? .daily,
                       limit: gauge?.limit ?? 0,
                       window: gauge?.window,
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
                        Picker("", selection: $service.menuBarSource) {
                            Text(l10n.t(.sourceAuto)).tag(MenuBarSource.auto)
                            ForEach(QuotaKind.allCases, id: \.self) { kind in
                                Text(kind.label(l10n.language)).tag(MenuBarSource.fixed(kind))
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
                    actionRow(l10n.t(.rowConfigureAccount)) { SettingsWindow.shared.show() }

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
