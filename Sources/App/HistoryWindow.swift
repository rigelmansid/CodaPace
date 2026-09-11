//
//  HistoryWindow.swift — 独立的历史窗口
//
//  和设置窗口同样的理由:独立 NSWindow 而不是 sheet ——
//  挂在 MenuBarExtra(.window) 上的 sheet 一失焦就会被关掉。
//  这里还需要能缩放、能全屏,图表才有地方铺开。
//

import SwiftUI
import AppKit

// MARK: - 窗口宿主

@MainActor
final class HistoryWindow {
    static let shared = HistoryWindow()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: HistoryView())
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 720, height: 560))
            w.center()
            window = w
        }
        // 窗口只创建一次,语言换了标题得跟上
        window?.title = L10n.text(.historyTitle, Localization.shared.language)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 内容

struct HistoryView: View {

    @StateObject private var model = HistoryModel()
    @ObservedObject private var service = UsageService.shared
    @ObservedObject private var l10n = Localization.shared

    @State private var kind: QuotaKind = .daily
    @State private var days: Int = 7

    /// 当前所选额度的上限。取不到(或不限)就画不出百分比曲线。
    private var limit: Double {
        service.snapshot?.gauge(kind)?.limit ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    quotaSection
                    tokenSection
                    notes
                }
                .padding(20)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { reload() }
        .onChange(of: kind) { _ in reload() }
        .onChange(of: days) { _ in reload() }
    }

    private func reload() {
        model.reload(kind: kind,
                     limit: limit,
                     window: service.snapshot?.gauge(kind)?.window,
                     quotaDays: days,
                     tokenDays: days)
    }

    // MARK: 控件

    private var controls: some View {
        HStack(spacing: 14) {
            Picker(l10n.t(.historyQuota), selection: $kind) {
                ForEach(QuotaKind.allCases, id: \.self) {
                    Text($0.label(l10n.language)).tag($0)
                }
            }
            .frame(width: 200)

            Picker(l10n.t(.historyRange), selection: $days) {
                Text(l10n.f(.historyRangeHoursFormat, 24)).tag(1)
                Text(l10n.f(.historyRangeDaysFormat, 7)).tag(7)
                Text(l10n.f(.historyRangeDaysFormat, 14)).tag(14)
                Text(l10n.f(.historyRangeDaysFormat, 30)).tag(30)
            }
            .frame(width: 210)

            Spacer()

            Text(l10n.f(.historySampleCountFormat, Fmt.int(model.sampleCount)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: 额度曲线

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(l10n.t(.chartQuotaTrend),
                         detail: "\(kind.label(l10n.language)) · "
                         + (limit > 0
                            ? l10n.f(.historyLimitFormat, Fmt.money2(limit))
                            : l10n.t(.historyNoLimit)))

            if limit <= 0 {
                ChartPlaceholder(message: l10n.t(.historyNoLimitMessage))
                    .frame(height: 200)
            } else if model.quotaPoints.isEmpty {
                ChartPlaceholder(message: l10n.t(.historyNoSamplesMessage))
                    .frame(height: 200)
            } else {
                QuotaChart(points: model.quotaPoints,
                           connectors: model.quotaConnectors,
                           gaps: model.gaps,
                           showsAxes: true)
                    .frame(height: 200)
            }
        }
    }

    // MARK: token 柱状图

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            let total = model.tokenBars.reduce(0) { $0 + $1.tokens }
            sectionTitle(l10n.t(.chartTokenUsage),
                         detail: model.tokenBars.isEmpty
                         ? l10n.t(.historyTokensByDay)
                         : l10n.f(.historyTokensTotalFormat, Fmt.count(total)))

            if model.tokenBars.isEmpty {
                ChartPlaceholder(message: l10n.t(.historyNoTokensMessage))
                    .frame(height: 160)
            } else {
                TokenChart(bars: model.tokenBars, showsAxes: true)
                    .frame(height: 160)
            }
        }
    }

    // MARK: 说明

    /// 把数据的局限性写在界面上,而不是让用户自己猜为什么图上有洞
    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l10n.t(.historyAboutTitle))
                .font(.system(size: 11, weight: .semibold))
            note(l10n.t(.historyNote1))
            note(l10n.t(.historyNote2))
            note(l10n.t(.historyNote3))
            note(l10n.t(.historyNote4))
        }
        .padding(.top, 4)
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text("·")
            Text(text)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
