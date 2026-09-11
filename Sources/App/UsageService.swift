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
    @Published private(set) var isLoading = false

    /// 本地时钟。每 30 秒推进一次,让倒计时和 pace 在两次网络刷新之间也保持新鲜 ——
    /// 旧版本的「还有 x 分钟重置」是跟着 60 秒一次的网络刷新走的,中间一直是过期的。
    @Published private(set) var now = Date()

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

    // MARK: 刷新

    func refresh() async {
        guard Config.isConfigured, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let stats = try await API.userStats()
            // 本月消费是锦上添花,取不到不影响主结果
            let monthly = try? await API.monthlyUsage()

            now = Date()
            let built = SnapshotBuilder.build(stats: stats,
                                              monthly: monthly,
                                              schedule: Config.schedule,
                                              now: now)
            snapshot = built
            errorText = nil

            // 落一条历史采样。存储出问题不影响主功能,内部自己吞掉错误。
            HistoryRecorder.shared.record(built)

            // 该不该发通知由 Core 的 AlertPolicy 判断,这里只是触发点
            Notifier.shared.process(built, now: now)
        } catch {
            // 刷新失败时**保留**上一次的快照,只把错误记下来。
            // 菜单栏留着旧数字,总好过突然空白。
            errorText = error.localizedDescription
        }
    }

    // MARK: 派生显示

    /// 菜单栏该显示的那条额度
    var menuBarGauge: Gauge? {
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
        // 一条有上限的额度都没有 —— 百分比无从谈起,退回显示今日已用金额
        return Fmt.money(snapshot.gauge(.daily)?.used ?? 0)
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
            return Fmt.money(gauge.remaining)
        }
        return pace.label(Localization.shared.language)
    }

    /// 菜单栏最终呈现的那张图(图形 + 两行文字一起画)
    var menuBarImage: NSImage {
        MenuBarIcon.image(gauge: menuBarGauge,
                          now: now,
                          style: menuBarStyle,
                          value: menuBarValue,
                          caption: menuBarCaption)
    }
}

// MARK: - 接口调用

enum API {

    /// 显式传凭据的版本 —— 设置界面在**保存之前**用它验证网址是否可用
    static func userStats(base: String, apiId: String) async throws -> UserStats {
        try await post(base: base,
                       path: "/apiStats/api/user-stats",
                       body: ["apiId": apiId],
                       as: UserStats.self)
    }

    static func userStats() async throws -> UserStats {
        try await userStats(base: Config.baseURL, apiId: Config.apiId)
    }

    private struct BatchAggregated: Decodable { let monthlyUsage: UsageBlock? }
    private struct BatchData: Decodable { let aggregated: BatchAggregated? }

    static func monthlyUsage() async throws -> UsageBlock? {
        let batch = try await post(base: Config.baseURL,
                                   path: "/apiStats/api/batch-stats",
                                   body: ["apiIds": [Config.apiId]],
                                   as: BatchData.self)
        return batch.aggregated?.monthlyUsage
    }

    // MARK: 底层

    private static func post<T: Decodable>(base: String,
                                           path: String,
                                           body: Any,
                                           as type: T.Type) async throws -> T {
        // Config 不受 actor 隔离,后台任务里读它是安全的
        let language = Config.language

        guard let url = URL(string: base + path) else {
            throw APIError(L10n.format(.errInvalidURLFormat, language, base))
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: req)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError(L10n.format(.errHTTPFormat, language, http.statusCode))
        }
        return try ResponseDecoder.unwrap(type, from: data, language: language)
    }
}
