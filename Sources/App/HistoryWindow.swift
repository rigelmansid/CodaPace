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

    /// 当前所选额度对应的桶。
    ///
    /// ⚠︎ EXT-001 阶段 1 的**临时桥接**:展示侧已经是任意多个额度桶,而历史层
    /// 还按固定四项分列,所以这里拿 `kind.rawValue` 当桶 ID 回头去取。
    /// 能对上全靠中转站的桶 ID 取值等于旧枚举的 rawValue —— 阶段 2 把历史改成
    /// 按桶存之后,`kind` 本身就换成桶 ID,这个函数连同 `QuotaKind` 一起消失。
    private var selectedBucket: QuotaBucket? {
        service.snapshot?.bucket(id: kind.rawValue)
    }

    /// 当前所选额度的上限。**只用于标题那行的「上限 $x」**,是此刻的配置,
    /// 不参与绘图 —— 曲线上每个点用的是它自己那条采样当时的上限。
    private var limit: Double {
        selectedBucket?.limit ?? 0
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
        // 窗口开着的时候新采样要自己出现,不该等用户关掉重开。
        // fetchedAt 是每次成功刷新都会变的那个值。
        .onChange(of: service.snapshot?.fetchedAt) { _ in reload() }
        // 换账户 = 换一整个历史库。这一条不能省略成上面那条:
        // 两个账户都离线时快照前后都是 nil,只看快照什么也观察不到。
        .onChange(of: service.accountGeneration) { _ in reload() }
    }

    private func reload() {
        model.reload(kind: kind,
                     rule: selectedBucket?.rule,
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

            // 画不画曲线,由**点本身**决定,不看当前上限。
            //
            // 原先这里是 `if limit <= 0`,拿此刻的配置决定历史画不画 ——
            // 用户今天把额度改成不限额,昨天那段本来完全画得出的曲线会整段消失,
            // 被一句「没设上限」盖掉。历史点各用各当时的上限,和现在设成多少无关。
            if !model.quotaPoints.isEmpty {
                QuotaChart(points: model.quotaPoints,
                           connectors: model.quotaConnectors,
                           gaps: model.gaps,
                           showsAxes: true)
                    .frame(height: 200)

                // 曲线画得出来,不代表它画全了(OPT-012)。
                // 被跳过的采样在图上没有任何痕迹 —— 既不是空档(那段确实采到了),
                // 也不是断线,就是单纯地不存在。不说一句,用户看到一张几乎空白的图
                // 只会去查 app 是不是没在跑,而真正的原因是那些采样不带上限。
                if model.quotaSamplesWithoutPercentage > 0 {
                    Text(l10n.f(.historyNoPercentageCountFormat,
                                Fmt.int(model.quotaSamplesWithoutPercentage)))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if model.quotaSamplesInRange > 0 {
                // 有采样,但没有一条算得出百分比 —— 和「根本没采样」是两回事,
                // 说错了用户会去找一段并不存在的空档
                ChartPlaceholder(message: l10n.t(.historyNoLimitMessage))
                    .frame(height: 200)
            } else {
                ChartPlaceholder(message: l10n.t(.historyNoSamplesMessage))
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
