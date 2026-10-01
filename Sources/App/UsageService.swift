//
//  UsageService.swift — 抓取、定时刷新与状态
//

import Foundation
import AppKit

@MainActor
final class UsageService: ObservableObject {

    /// 单例:AppDelegate 在启动时就要拿到它,而 MenuBarExtra 的面板是点开才创建的,
    /// 两边必须是同一个实例。
    static let shared = UsageService()

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var errorText: String?

    /// 刷新准入。用「在飞的是哪个账户」而不是一个布尔量 —— 理由见 Core/Account.swift。
    /// @Published 是为了 isLoading 变化时面板上的刷新按钮能跟着变灰。
    @Published private var gate = RefreshGate()

    var isLoading: Bool { gate.isLoading }

    /// 本地时钟。每 30 秒推进一次,让倒计时和 pace 在两次网络刷新之间也保持新鲜 ——
    /// 旧版本的「还有 x 分钟重置」是跟着 60 秒一次的网络刷新走的,中间一直是过期的。
    @Published private(set) var now = Date()

    /// 账户换过几次。**只是一个变更信号**,不是账户本身的副本 ——
    /// 账户的唯一事实仍在 `Config.account`,在这里再存一份迟早会漂移。
    ///
    /// 图表需要它:换账户就是换一整个历史库,而这件事**不一定伴随快照变化**。
    /// 两个账户都离线时 `snapshot` 前后都是 nil,单看它观察不到任何变化,
    /// 开着的窗口会一直画着上一个账户的曲线。
    @Published private(set) var accountGeneration = 0

    // 下面三个设置项都写回 UserDefaults,重启后保持。
    // 用 @Published 而不是每次读 Config,是为了改动后界面能立刻重绘。

    @Published var menuBarStyle: MenuBarStyle = Config.menuBarStyle {
        didSet { Config.menuBarStyle = menuBarStyle }
    }

    @Published var menuBarSource: MenuBarSource = Config.menuBarSource {
        didSet { Config.menuBarSource = menuBarSource }
    }

    @Published var refreshInterval: TimeInterval = Config.interval {
        didSet {
            Config.interval = refreshInterval
            restartRefreshTimer()
        }
    }

    @Published var notificationsEnabled: Bool = Config.notificationsEnabled {
        didSet {
            Config.notificationsEnabled = notificationsEnabled
            // 重新打开时清掉已发记录,好让当前周期能再提醒一次;
            // 否则关掉再打开会发现"怎么一直不提醒"
            if notificationsEnabled { Notifier.shared.resetHistory() }
        }
    }

    private var refreshTimer: Timer?
    private var tickTimer: Timer?

    // MARK: 生命周期

    func start() {
        // 旧版把日重置小时和通知去重账本都存成全局值,不区分账户。
        // 一并丢掉,各账户自己重建。
        Config.discardLegacyGlobalResetHour()
        Notifier.discardLegacyGlobalLedger()

        restartRefreshTimer()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        tickTimer?.tolerance = 5

        Task { await refresh() }
    }

    func restartRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = Config.interval
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        refreshTimer?.tolerance = interval * 0.2
    }

    // MARK: 账户切换

    /// 换账户:写入配置,清掉属于旧账户的展示状态,然后立刻为新账户拉一次。
    ///
    /// 在飞的旧刷新**不需要**在这里取消 —— 它回来时过不了提交前的身份校验,会自己作废。
    /// 而它也挡不住下面这次刷新:`RefreshGate` 按账户判断重入,账户不同就放行。
    /// - Throws: 钥匙串写入失败。**必须往上抛** —— 吞掉的话设置窗口会关掉、
    ///   界面显示已配置,而每次刷新都取不到密钥。
    func applyAccount(_ connection: Connection) throws {
        let previous = Config.account
        try Config.apply(connection)
        accountDidSwitch(from: previous)
    }

    /// 切到一个已存档的账户(EXT-010)。和 `applyAccount` 的区别只在写配置那一步 ——
    /// 这里手里没有密钥,也不该有,理由见 `Config.select`。之后的清场是同一段。
    func selectAccount(_ account: AccountIdentity) {
        let previous = Config.account
        Config.select(account)
        accountDidSwitch(from: previous)
    }

    /// 配置已写入之后的清场与重拉。`applyAccount` 和 `selectAccount` 共用这一段 ——
    /// 各写一份的话,哪天这里多一件「换账户必须做的事」,漏改的那条就会串账户(不变量 5)。
    private func accountDidSwitch(from previous: AccountIdentity) {
        let changed = previous != Config.account
        if changed {
            // 没存档的账户一被切走,它的密钥和会话就再也够不着了 —— 删除入口只在存档列表里。
            // 不存档就是一次性配置(OPT-019,用户 2026-09-30 选定):切走即清,不留孤儿。
            // 删失败不拦切换:最坏也就是回到修之前的样子
            if previous.isConfigured, !archive.contains(previous) {
                try? Config.removeCredential(for: previous)
            }

            // 旧账户的数字不能挂在新账户的名字底下,哪怕只是新数据到达前的几百毫秒
            snapshot = nil
            errorText = nil
            now = Date()

            // 去重账本现在按账户分命名空间,不必清空 ——
            // 切回旧账户时,它已经发过的告警仍该保持去重
            Notifier.shared.accountDidChange()

            // 丢掉旧账户的 token 基线,换库
            HistoryRecorder.shared.accountDidChange()

            // 放在最后:换库之后再通知界面,读到的才是新账户的历史。
            // 图表靠它重读 —— 两个账户都离线时,上面那些 nil 赋值不产生任何变化。
            accountGeneration += 1
        }

        restartRefreshTimer()
        Task { await refresh() }
    }

    // MARK: 账户存档(EXT-010)

    /// 存档列表。和上面几个设置项同一个做法:@Published 让面板的下拉和设置窗口的
    /// 管理列表改一处另一处立刻重绘,写回 Config 保证重启后还在。
    /// **只经下面几个函数改**,不开放 set —— 删除要连带钥匙串,不能绕过去。
    @Published private(set) var archive = Config.archive {
        didSet { Config.archive = archive }
    }

    /// 存档当前的账户。时机是「测试连接通过并保存之后」,昵称由界面预填
    /// `ConnectionReport.accountName`、用户可改。
    @discardableResult
    func archiveCurrentAccount(nickname: String) -> Bool {
        archive.save(Config.account, nickname: nickname)
    }

    @discardableResult
    func renameArchived(_ account: AccountIdentity, to nickname: String) -> Bool {
        archive.rename(account, to: nickname)
    }

    /// 删除一个存档:**删列表项 + 删钥匙串那条,历史库留着。**
    ///
    /// 历史是最有价值也最难重建的东西,它按身份分区,同一账户哪天重新加回来
    /// 会自动接上。密钥和历史各自的去向,界面上的确认框都得说清楚。
    ///
    /// 先删密钥、后删列表项:反过来的话,钥匙串删失败时列表项已经没了,
    /// 那把密钥就成了界面上再也够不着的孤儿。
    ///
    /// **当前账户不许删**(EXT-010 定的):删了密钥而身份还停在它上面,面板会立刻
    /// 报「缺少密钥」;删完自动切到别的又是替用户选账户。界面上那一行的删除按钮
    /// 该灰着并说明「先切到别的账户」,这里是兜底。
    ///
    /// - Throws: 钥匙串删除失败。调用方必须显示出来,此时列表原样不动。
    func forgetArchived(_ account: AccountIdentity) throws {
        guard account != Config.account else {
            assertionFailure("不能删除当前正在用的账户")
            return
        }
        try Config.removeCredential(for: account)
        archive.remove(account)
    }

    // MARK: 刷新

    func refresh() async {
        // 全流程只认这一份身份:两个请求、落库、通知都用它。
        // 中途再去读 Config 就会出现一次刷新横跨两个账户 —— 那正是这里要防的事。
        let account = Config.account
        guard let ticket = gate.begin(account) else { return }
        defer { gate.finish(ticket) }

        do {
            // 协议细节全在适配器里:通用层只说「给这个账户拉一次用量」。
            // 新增供应商不该让这段流程长出任何分支 —— 那正是适配器边界存在的理由。
            // 身份和密钥一次取齐,一路传到适配器 —— 中途不再回头读配置。
            // 密钥也是身份的一部分:只定住身份而让适配器自己去取密钥,
            // 换账户时同样会串(见 Connection)。
            let adapter = ProviderRegistry.adapter(for: account)
            let built = try await adapter.fetchUsage(try Config.connection(for: account),
                                                     schedule: Config.schedule(for: account),
                                                     language: Config.language)

            // 提交前校验身份:上面的 await 期间用户可能已经换了账户。
            // 那这份结果属于上一个账户 —— 既不能显示,也不能写进新账户的历史,
            // 更不能拿它去触发新账户的通知。整份丢掉,新账户自己那次刷新会补上。
            //
            // 光比账户不够(OPT-021):A → B → A 之后同一账户有两次在飞,先发的那次
            // 账户也对得上。所以还要问这张票是不是最新的那张
            guard gate.isCurrent(ticket), Config.account == account else { return }

            // fetchedAt 是适配器在拿到数据之后打的点,倒计时和 pace 都按它算
            now = built.fetchedAt
            snapshot = built
            errorText = nil

            // 落一条历史采样。分区键由**传进去的**身份决定,不是当时的全局配置。
            // 存储出问题不影响主功能,内部自己吞掉错误。
            HistoryRecorder.shared.record(built, account: account)

            // 该不该发通知由 Core 的 AlertPolicy 判断,这里只是触发点
            Notifier.shared.process(built, now: now, account: account)
        } catch {
            // 同样要校验:旧账户(或同账户更早那次)的失败不该盖在新结果头上显示成 Offline
            guard gate.isCurrent(ticket), Config.account == account else { return }

            // 刷新失败时**保留**上一次的快照,只把错误记下来。
            // 菜单栏留着旧数字,总好过突然空白。
            errorText = error.localizedDescription
        }
    }

    // MARK: 派生显示

    /// 菜单栏该显示的那条额度
    var menuBarGauge: QuotaBucket? {
        snapshot?.menuBarGauge(source: menuBarSource)
    }

    /// 主行:剩余额度百分比。
    /// 用百分比而不是金额,是为了四条额度切换时口径一致、宽度也稳定;
    /// 具体金额在面板里给足($27.04 / $70.00)。
    var menuBarValue: String {
        let language = Localization.shared.language
        guard Config.isConfigured else { return L10n.text(.menuBarNotConfigured, language) }
        guard let snapshot else {
            return errorText == nil ? "…" : L10n.text(.menuBarOffline, language)
        }

        if let gauge = menuBarGauge {
            return Fmt.percent(gauge.remainingRatio)
        }
        // 一条有上限的额度都没有 —— 百分比无从谈起,退回显示用量本身。
        //
        // 取**第一条**(顺序由适配器定),不点名「今日」:那是中转站的概念,
        // 通用层不该认识任何一条具体额度的名字(不变量 6)。
        guard let first = snapshot.gauges.first else { return "…" }
        return first.unit.compactAmount(first.used)
    }

    /// 副行:补上主行没有的那个维度。
    ///
    /// 主行是**数量**(还剩百分之多少),副行是**速率**(掉得快不快)——
    /// 两个正交的事实,副行不复述主行。
    /// 没有时间窗口就算不出速率,那就退回显示剩余金额,同样是对百分比的补充。
    var menuBarCaption: String {
        guard let gauge = menuBarGauge else { return "" }

        let pace = gauge.pace(now: now)
        if case .unavailable = pace {
            return gauge.unit.compactAmount(gauge.remaining)
        }
        return pace.label(Localization.shared.language)
    }

    /// 菜单栏最终呈现的那张图(图形 + 两行文字一起画)。
    ///
    /// 外观**必须由调用方给**:要的是状态栏那一处的明暗,而 service 站在 app 这一侧,
    /// 自己去取只能取到 app 的主题设置 —— 那正是 EXT-008 修掉的那个错位。
    func menuBarImage(in appearance: NSAppearance) -> NSImage {
        MenuBarIcon.image(gauge: menuBarGauge,
                          now: now,
                          style: menuBarStyle,
                          value: menuBarValue,
                          caption: menuBarCaption,
                          appearance: appearance)
    }
}
