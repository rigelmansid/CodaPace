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

    /// 选中的桶 ID。空串表示「当前没有任何可画的额度」—— 没有快照,历史里也没有桶。
    @State private var bucketID: String = ""
    @State private var days: Int = 7

    /// 额度选择器里的一项
    private struct BucketOption: Identifiable, Equatable {
        let id: String
        let title: String
    }

    /// 选择器的内容:**当前快照的桶 ∪ 历史里出现过的桶**。
    ///
    /// 并集而不是只取快照,是因为离线时快照是 nil —— 那时候选择器会整个空掉,
    /// 用户连已经攒下的历史都翻不了。
    private var bucketOptions: [BucketOption] {
        // 快照里的排在前面,并保持**适配器声明的顺序** —— 那是供应商自己的重要性排序,
        // 不该在这里按字母或别的什么重排。
        var options = (service.snapshot?.gauges ?? []).map {
            BucketOption(id: $0.id, title: $0.label(l10n.language))
        }

        // 历史里有、这次快照没报的补在后面。这时只有 ID 可用,就**显示 ID 本身** ——
        // 替它编一个像样的中文名等于凭空发明供应商没说过的事(不变量 3)。
        let listed = Set(options.map(\.id))
        options += model.knownBucketIDs
            .filter { !listed.contains($0) }
            .map { BucketOption(id: $0, title: $0) }

        return options
    }

    /// 当前所选额度对应的桶。离线时为 nil —— 那时只有历史点能画,当前配置无从得知。
    private var selectedBucket: QuotaBucket? {
        service.snapshot?.bucket(id: bucketID)
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
        .onAppear {
            // 先把历史里有哪些桶问出来,选择器才有内容可选、reload 才知道该默认选谁
            model.refreshBuckets()
            reload()
        }
        .onChange(of: bucketID) { _ in reload() }
        .onChange(of: days) { _ in reload() }
        // 窗口开着的时候新采样要自己出现,不该等用户关掉重开。
        // fetchedAt 是每次成功刷新都会变的那个值。
        .onChange(of: service.snapshot?.fetchedAt) { _ in reload() }
        // 换账户 = 换一整个历史库。这一条不能省略成上面那条:
        // 两个账户都离线时快照前后都是 nil,只看快照什么也观察不到。
        .onChange(of: service.accountGeneration) { _ in
            model.refreshBuckets()
            reload()
        }
        // 历史里冒出新桶(换了供应商、对方新增了一条额度)时重挑一次选中项。
        // 值没变就不会触发,不会自己跟自己循环。
        .onChange(of: model.knownBucketIDs) { _ in reload() }
    }

    private func reload() {
        // 选中的桶可能已经不在列表里了(刚打开、换了账户、换了供应商)。
        // 这时重挑一个 —— 赋值会触发上面的 onChange(of: bucketID),
        // 由那一次真正去取数,所以这里直接返回,不做重复的查询。
        let options = bucketOptions
        if !options.contains(where: { $0.id == bucketID }) {
            let resolved = defaultBucketID(among: options) ?? ""
            if resolved != bucketID {
                bucketID = resolved
                return
            }
        }

        model.reload(bucketID: bucketID.isEmpty ? nil : bucketID,
                     rule: selectedBucket?.rule,
                     quotaDays: days,
                     tokenDays: days)
    }

    /// 默认选哪条额度。
    ///
    /// 从前这里写死 `.daily` —— 那是中转站的额度名长进了通用层(不变量 6),
    /// 换一家供应商就没有叫这个名字的额度。现在改成一条**按性质**的规则:
    /// 优先第一条有重置周期、且周期不算高频的额度。
    ///
    /// 理由是这个窗口要回答的问题是「一个周期内消耗得多快」:没有周期的额度
    /// (账户总配额)画出来是一条几个月看不出变化的长线;高频窗口(限流)则
    /// 一小时抖完一个来回,打开窗口时看到的多半是一段无意义的锯齿。两者都不是
    /// 用户点进来想看的东西。
    ///
    /// 对中转站,这条规则选出的仍然是「今日」,和从前那个写死值完全一致;
    /// 对 tu-zi 会选出它的日额度。一条都不满足(比如离线,只有历史桶 ID)
    /// 就退回列表第一条。
    private func defaultBucketID(among options: [BucketOption]) -> String? {
        if let preferred = service.snapshot?.gauges.first(where: {
            $0.window != nil && !$0.hasVolatileWindow
        }) {
            return preferred.id
        }
        return options.first?.id
    }

    // MARK: 控件

    private var controls: some View {
        HStack(spacing: 14) {
            Picker(l10n.t(.historyQuota), selection: $bucketID) {
                ForEach(bucketOptions) {
                    Text($0.title).tag($0.id)
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

    /// 标题右边那行小字:额度名,以及**此刻**的上限。
    ///
    /// 上限只是说明文字,不参与绘图 —— 曲线上每个点用的是它自己那条采样当时的上限。
    ///
    /// 离线时(`selectedBucket` 为 nil)只报名字,不说上限。从前那版这里会显示
    /// 「没设上限」,可离线时我们并不知道上限是多少,那是把「不知道」说成了「不限」。
    private var quotaDetail: String {
        let title = bucketOptions.first { $0.id == bucketID }?.title ?? bucketID
        guard let bucket = selectedBucket else { return title }

        // 按桶自己的单位排版,而不是一律 Fmt.money2 —— 供应商没声明单位的额度
        // 不该被打上 `$`(EXT-001)。
        return title + " · " + (bucket.limit > 0
            ? l10n.f(.historyLimitFormat, bucket.amount(bucket.limit))
            : l10n.t(.historyNoLimit))
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(l10n.t(.chartQuotaTrend), detail: quotaDetail)

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
