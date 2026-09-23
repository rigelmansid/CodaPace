//
//  Localization.swift — 界面文案
//
//  为什么不用标准的 .lproj / Localizable.strings:
//  那套跟随**系统语言**,要做「app 内即时切换」还得手动替换 bundle(公认的绕法);
//  而且本项目用 swiftc 直接构建,没有 Xcode 的资源打包流程。
//  代码内字符串表更简单:切换即时生效、可单测、构建不用额外步骤。
//
//  表按 key 为主序组织 —— 同一句话的各语言版本排在一起,漏译一眼可见,
//  而且有 LocalizationTests 逐个 key 检查三种语言是否齐全。
//
//  只做简中 / 繁中 / 英文。曾经加过西/法/德,但那三种没有母语者校对,
//  与其提供质量不确定的翻译,不如让它们回落到英文。
//

import Foundation

// MARK: - 语言

public enum Language: String, CaseIterable, Identifiable, Equatable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en

    public var id: String { rawValue }

    /// 各语言用自己的名字显示 —— 用户看不懂当前语言时才更需要找到自己的那一项
    public var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en:     return "English"
        }
    }

    /// 按系统偏好猜一个默认语言,认不出就用英文
    public static func systemDefault(preferred: [String] = Locale.preferredLanguages) -> Language {
        for tag in preferred {
            let lower = tag.lowercased()
            if lower.hasPrefix("zh") {
                // 繁体的常见标记:zh-Hant / zh-TW / zh-HK / zh-MO
                if lower.contains("hant") || lower.contains("tw")
                    || lower.contains("hk") || lower.contains("mo") {
                    return .zhHant
                }
                return .zhHans
            }
            if lower.hasPrefix("en") { return .en }
        }
        return .en
    }
}

// MARK: - 文案键

public enum LangKey: String, CaseIterable {
    // 面板框架
    case appTitle, statusActive, statusInactive, quit, updatedAt, settings

    // 设置分组
    case groupDisplay, groupAccount, groupLanguage

    // 设置项
    case rowMenuBarSource, rowMenuBarStyle, rowRefreshInterval, rowNotifications
    case rowOpenConsole, rowConfigureAccount, rowLanguage

    // 额度名称
    case sourceAuto, quotaTotal, quotaDaily, quotaWeeklyOpus, quotaWindow
    case quotaWeekly, quotaMonthly

    // 菜单栏样式
    case styleRings, styleBar

    // 额度行
    case quotaRemaining, timeRemaining, unlimited, usedAmountFormat
    case paceOnPace, paceOverPace, inferredSuffix, resetsInFormat, resetSoon

    // 时长单位
    case durDaysFormat, durHoursFormat, durMinutesFormat, durMinutesShortFormat, durSecondsFormat

    // 汇总
    case summaryMonthly, summaryTotal, requestsFormat, requestsShortFormat

    // 状态
    case stateLoading, stateOfflineTitle, stateStaleFormat
    case stateNotConfigured, stateNotConfiguredDetail, stateOpenSetup
    case menuBarNotConfigured, menuBarOffline

    // 图表
    case chartQuotaTrend, chartTokenUsage, chartLast24h, chartLast30d
    case chartNoSamples, chartNoPercentage, chartNoTokenDays

    // 历史窗口
    case historyTitle, historyQuota, historyRange, historySampleCountFormat
    case historyLimitFormat, historyNoLimit
    case historyRangeHoursFormat, historyRangeDaysFormat
    case historyNoLimitMessage, historyNoSamplesMessage, historyNoTokensMessage
    case historyNoPercentageCountFormat
    case historyAboutTitle, historyNote1, historyNote2, historyNote3, historyNote4
    case historyTokensTotalFormat, historyTokensByDay

    // 配置窗口
    case setupWindowTitle, setupTitle, setupDesc1
    case setupTest, setupSave, setupSupportedLink
    case setupWaiting, setupTesting
    case setupSuccessFormat, setupFailureFormat
    case setupUnsupported, setupRecognizedFormat

    // 连接报告里的提示
    case findNoLimitedQuota, findIncompleteUsage, findDailyResetInferred
    case findNoResetWindow, findHistoryIsLocalOnly

    // 通知
    case notifyLowTitleFormat, notifyLowBodyFormat
    case notifyPaceTitleFormat, notifyPaceBodyFormat

    // 错误
    case errInvalidURLFormat, errHTTPFormat, errNoData, errUnparsable, errApiFailed
    case errMissingCredential
    case setupRevealSecret, setupHideSecret, setupMustTestFirst
    case setupDescKey, setupSafetyIdentifier, setupSafetySecret
    case setupPickYourProvider
    case errInvalidFieldFormat
    case errHistoryStore
}

// MARK: - 查表

public enum L10n {

    /// 取一条文案。缺失时回落到英文,再缺就把 key 原样返回 ——
    /// 界面上出现一个 key 名总好过空白,而且一眼就知道是漏译。
    public static func text(_ key: LangKey, _ language: Language) -> String {
        guard let entry = table[key] else { return key.rawValue }
        return entry[language] ?? entry[.en] ?? key.rawValue
    }

    /// 带参数的文案
    public static func format(_ key: LangKey, _ language: Language,
                              _ arguments: CVarArg...) -> String {
        String(format: text(key, language), arguments: arguments)
    }

    /// 供测试检查完整性
    public static func entry(_ key: LangKey) -> [Language: String]? { table[key] }

    // MARK: 文案表

    private static let table: [LangKey: [Language: String]] = [

        // ── 面板框架 ──────────────────────────────────────
        // 产品名不翻译
        .appTitle: [
            .zhHans: "CodaPace", .zhHant: "CodaPace", .en: "CodaPace"],
        .statusActive: [
            .zhHans: "可用", .zhHant: "可用", .en: "Active"],
        .statusInactive: [
            .zhHans: "已停用", .zhHant: "已停用", .en: "Disabled"],
        .quit: [
            .zhHans: "退出", .zhHant: "結束", .en: "Quit"],
        .updatedAt: [
            .zhHans: "更新于 %@", .zhHant: "更新於 %@", .en: "Updated %@"],
        .settings: [
            .zhHans: "设置", .zhHant: "設定", .en: "Settings"],

        // ── 设置分组 ──────────────────────────────────────
        .groupDisplay: [
            .zhHans: "显示", .zhHant: "顯示", .en: "Display"],
        .groupAccount: [
            .zhHans: "账号", .zhHant: "帳號", .en: "Account"],
        .groupLanguage: [
            .zhHans: "语言", .zhHant: "語言", .en: "Language"],

        // ── 设置项 ────────────────────────────────────────
        .rowMenuBarSource: [
            .zhHans: "菜单栏显示", .zhHant: "選單列顯示", .en: "Menu bar shows"],
        .rowMenuBarStyle: [
            .zhHans: "图形样式", .zhHant: "圖形樣式", .en: "Indicator style"],
        .rowRefreshInterval: [
            .zhHans: "刷新间隔", .zhHant: "更新間隔", .en: "Refresh interval"],
        .rowNotifications: [
            .zhHans: "额度提醒", .zhHant: "額度提醒", .en: "Quota alerts"],
        .rowOpenConsole: [
            .zhHans: "打开网页控制台", .zhHant: "開啟網頁主控台", .en: "Open web console"],
        .rowConfigureAccount: [
            .zhHans: "配置账号", .zhHant: "設定帳號", .en: "Configure account"],
        .rowLanguage: [
            .zhHans: "界面语言", .zhHant: "介面語言", .en: "Interface language"],

        // ── 额度名称 ──────────────────────────────────────
        .sourceAuto: [
            .zhHans: "自动", .zhHant: "自動", .en: "Automatic"],
        .quotaTotal: [
            .zhHans: "总额度", .zhHant: "總額度", .en: "Total quota"],
        .quotaDaily: [
            .zhHans: "今日", .zhHant: "今日", .en: "Today"],
        .quotaWeeklyOpus: [
            .zhHans: "本周 Opus", .zhHant: "本週 Opus", .en: "Weekly Opus"],
        .quotaWindow: [
            .zhHans: "限流窗口", .zhHant: "限流視窗", .en: "Rate limit window"],

        // 通用的周期名。刻意**不带任何模型或产品名** —— 和「本周 Opus」不同,
        // 这两条是给「就是一条周/月额度」的供应商用的,加限定词会说出对方没说过的事。
        .quotaWeekly: [
            .zhHans: "本周", .zhHant: "本週", .en: "This week"],
        .quotaMonthly: [
            .zhHans: "本月", .zhHant: "本月", .en: "This month"],

        // ── 菜单栏样式 ────────────────────────────────────
        .styleRings: [
            .zhHans: "双环", .zhHant: "雙環", .en: "Rings"],
        .styleBar: [
            .zhHans: "横条", .zhHant: "橫條", .en: "Bars"],

        // ── 额度行 ────────────────────────────────────────
        .quotaRemaining: [
            .zhHans: "剩余额度", .zhHant: "剩餘額度", .en: "Quota left"],
        .timeRemaining: [
            .zhHans: "剩余时间", .zhHant: "剩餘時間", .en: "Time left"],
        .unlimited: [
            .zhHans: "不限", .zhHant: "不限", .en: "Unlimited"],
        .usedAmountFormat: [
            .zhHans: "已用 %@", .zhHant: "已用 %@", .en: "%@ used"],
        .paceOnPace: [
            .zhHans: "正常速度", .zhHant: "正常速度", .en: "On pace"],
        .paceOverPace: [
            .zhHans: "超速", .zhHant: "超速", .en: "Over pace"],
        .inferredSuffix: [
            .zhHans: "(推算)", .zhHant: "(推算)", .en: "(estimated)"],
        .resetsInFormat: [
            .zhHans: "%@后重置", .zhHant: "%@後重設", .en: "Resets in %@"],
        .resetSoon: [
            .zhHans: "即将重置", .zhHant: "即將重設", .en: "Resetting soon"],

        // ── 时长单位 ──────────────────────────────────────
        .durDaysFormat: [
            .zhHans: "%d 天", .zhHant: "%d 天", .en: "%d d"],
        .durHoursFormat: [
            .zhHans: "%d 小时", .zhHant: "%d 小時", .en: "%d h"],
        .durMinutesFormat: [
            .zhHans: "%d 分钟", .zhHant: "%d 分鐘", .en: "%d min"],
        .durMinutesShortFormat: [
            .zhHans: "%d 分", .zhHant: "%d 分", .en: "%d min"],
        .durSecondsFormat: [
            .zhHans: "%d 秒", .zhHant: "%d 秒", .en: "%d s"],

        // ── 汇总 ──────────────────────────────────────────
        .summaryMonthly: [
            .zhHans: "本月消费", .zhHant: "本月消費", .en: "This month"],
        .summaryTotal: [
            .zhHans: "累计使用", .zhHant: "累計使用", .en: "All time"],
        .requestsFormat: [
            .zhHans: "%@ 次请求", .zhHant: "%@ 次請求", .en: "%@ requests"],
        .requestsShortFormat: [
            .zhHans: "%@ 次", .zhHant: "%@ 次", .en: "%@ req"],

        // ── 状态 ──────────────────────────────────────────
        .stateLoading: [
            .zhHans: "正在读取…", .zhHant: "正在讀取…", .en: "Loading…"],
        .stateOfflineTitle: [
            .zhHans: "暂时取不到数据", .zhHant: "暫時取不到資料",
            .en: "Can’t reach the server"],
        .stateStaleFormat: [
            .zhHans: "⚠︎ 最近一次刷新失败:%@", .zhHant: "⚠︎ 最近一次更新失敗:%@",
            .en: "⚠︎ Last refresh failed: %@"],
        .stateNotConfigured: [
            .zhHans: "尚未配置", .zhHant: "尚未設定", .en: "Not configured"],
        .stateNotConfiguredDetail: [
            .zhHans: "填入中转站的用量统计页面网址后才能读取数据。",
            .zhHant: "填入中轉站的用量統計頁面網址後才能讀取資料。",
            .en: "Paste your relay’s usage-stats page URL to start reading data."],
        .stateOpenSetup: [
            .zhHans: "打开配置…", .zhHant: "開啟設定…", .en: "Open setup…"],
        .menuBarNotConfigured: [
            .zhHans: "未配置", .zhHant: "未設定", .en: "Setup"],
        .menuBarOffline: [
            .zhHans: "离线", .zhHant: "離線", .en: "Offline"],

        // ── 图表 ──────────────────────────────────────────
        .chartQuotaTrend: [
            .zhHans: "额度趋势", .zhHant: "額度趨勢", .en: "Quota trend"],
        .chartTokenUsage: [
            .zhHans: "Token 用量", .zhHant: "Token 用量", .en: "Token usage"],
        .chartLast24h: [
            .zhHans: "最近 24 小时", .zhHant: "最近 24 小時", .en: "Last 24 hours"],
        .chartLast30d: [
            .zhHans: "最近 30 天", .zhHant: "最近 30 天", .en: "Last 30 days"],
        .chartNoSamples: [
            .zhHans: "还没有采样数据", .zhHant: "還沒有取樣資料", .en: "No samples yet"],
        // 缩略图版本。「有采样但画不出」和「没有采样」在缩略图里也得分开说 ——
        // 说成「还没有采样数据」会让用户去排查一个并不存在的问题。
        .chartNoPercentage: [
            .zhHans: "这段采样没有可用上限", .zhHant: "這段取樣沒有可用上限",
            .en: "No usable limit in this range"],
        .chartNoTokenDays: [
            .zhHans: "还没有按天数据", .zhHant: "還沒有按日資料", .en: "No daily data yet"],

        // ── 历史窗口 ──────────────────────────────────────
        .historyTitle: [
            .zhHans: "用量历史", .zhHant: "用量歷史", .en: "Usage history"],
        .historyQuota: [
            .zhHans: "额度", .zhHant: "額度", .en: "Quota"],
        .historyRange: [
            .zhHans: "范围", .zhHant: "範圍", .en: "Range"],
        .historySampleCountFormat: [
            .zhHans: "%@ 条采样", .zhHant: "%@ 筆取樣", .en: "%@ samples"],
        .historyLimitFormat: [
            .zhHans: "上限 %@", .zhHant: "上限 %@", .en: "Limit %@"],
        .historyNoLimit: [
            .zhHans: "未设上限", .zhHant: "未設上限", .en: "No limit set"],
        .historyRangeHoursFormat: [
            .zhHans: "最近 %d 小时", .zhHant: "最近 %d 小時", .en: "Last %d hours"],
        .historyRangeDaysFormat: [
            .zhHans: "最近 %d 天", .zhHant: "最近 %d 天", .en: "Last %d days"],
        // 说的是**这段时间的采样**,不是当前配置 —— 判据已经从「现在的上限」
        // 换成「这些点算不算得出百分比」,文案必须跟着换,否则会把两件事说反:
        // 现在设了上限,不代表当时也设了。
        .historyNoLimitMessage: [
            .zhHans: "这段时间的采样都算不出剩余百分比 —— 当时没有设上限,或是升级前的老记录没有记下当时的上限。",
            .zhHant: "這段時間的取樣都算不出剩餘百分比 —— 當時沒有設上限,或是升級前的舊紀錄沒有記下當時的上限。",
            .en: "None of the samples in this range can be turned into a percentage — either there was no limit at the time, or the sample predates the upgrade that started recording limits."],
        .historyNoSamplesMessage: [
            .zhHans: "这段时间还没有采样。历史是从 app 装上那天开始攒的。",
            .zhHant: "這段時間還沒有取樣。歷史是從 app 安裝當天開始累積的。",
            .en: "No samples in this range. History starts accumulating the day you install the app."],
        // 曲线**画得出来、但只画出了一部分**时说这一句(OPT-012)。
        // 成因和上面那条一样有两种,同样不挑一个说 —— 多数情况是老记录,
        // 但「多数」不是「全部」,按多数写死就是在断言我们并不知道的事。
        .historyNoPercentageCountFormat: [
            .zhHans: "另有 %@ 条采样画不出剩余百分比,没有出现在曲线上 —— 当时没有设上限,或是升级前的老记录没有记下当时的上限。",
            .zhHant: "另有 %@ 筆取樣畫不出剩餘百分比,沒有出現在曲線上 —— 當時沒有設上限,或是升級前的舊紀錄沒有記下當時的上限。",
            .en: "Another %@ samples can’t be turned into a percentage and are absent from the curve — either there was no limit at the time, or they predate the upgrade that started recording limits."],
        .historyNoTokensMessage: [
            .zhHans: "还没有按天数据。至少要连续运行两次刷新才会产生第一条增量。",
            .zhHant: "還沒有按日資料。至少要連續執行兩次更新才會產生第一筆增量。",
            .en: "No daily data yet. Two consecutive refreshes are needed to record the first delta."],
        .historyAboutTitle: [
            .zhHans: "关于这些数据", .zhHant: "關於這些資料", .en: "About this data"],
        .historyNote1: [
            .zhHans: "历史由 app 自己定时采样攒出来,接口只提供当前值,拿不到过去的逐日数据。",
            .zhHant: "歷史由 app 自行定時取樣累積,介面只提供目前數值,無法取得過去的逐日資料。",
            .en: "History is built from the app’s own periodic samples. The API only exposes current values, not past days."],
        .historyNote2: [
            .zhHans: "app 没运行的时段没有采样。曲线上的阴影就是这些空档 —— 不做插值,因为中间发生了什么无从得知。",
            .zhHant: "app 沒執行的時段沒有取樣。曲線上的陰影就是這些空檔 —— 不做內插,因為中間發生了什麼無從得知。",
            .en: "No samples while the app isn’t running. Shaded bands mark those gaps — no interpolation, since what happened is unknown."],
        .historyNote3: [
            .zhHans: "断档超过 30 分钟的 token 增量不计入任何一天:那段用量横跨的时间太长,归给哪天都是编的。",
            .zhHant: "斷檔超過 30 分鐘的 token 增量不計入任何一天:那段用量橫跨的時間太長,歸給哪天都是編的。",
            .en: "Token deltas across gaps longer than 30 minutes are dropped — attributing them to any single day would be a guess."],
        .historyNote4: [
            .zhHans: "计数器归零处另起一段曲线,对应一次额度重置。",
            .zhHant: "計數器歸零處另起一段曲線,對應一次額度重設。",
            .en: "A new curve starts wherever the counter resets to zero."],
        .historyTokensTotalFormat: [
            .zhHans: "按天统计 · 合计 %@", .zhHant: "按日統計 · 合計 %@",
            .en: "By day · %@ total"],
        .historyTokensByDay: [
            .zhHans: "按天统计", .zhHant: "按日統計", .en: "By day"],

        // ── 配置窗口 ──────────────────────────────────────
        .setupWindowTitle: [
            .zhHans: "设置 — CodaPace", .zhHant: "設定 — CodaPace",
            .en: "Settings — CodaPace"],
        .setupTitle: [
            .zhHans: "粘贴用量统计页面网址,或 API Key",
            .zhHant: "貼上用量統計頁面網址,或 API Key",
            .en: "Paste a usage-stats URL, or an API key"],
        // 还认不出是哪家时说的话。**关键在于不要求用户先给自己归类** ——
        // 「中转站」「订阅制供应商」是我们的词,不是用户的词;他知道的是
        // 「我用的是 tu-zi」。所以这里只说「在下面找到你那家」,
        // 具体要什么由那份列表逐行给出。
        .setupPickYourProvider: [
            .zhHans: "在下面找到你用的那家,粘贴它那一行要的东西:",
            .zhHant: "在下面找到你用的那家,貼上它那一行要的東西:",
            .en: "Find your provider below and paste what its line asks for:"],
        // 认出来之后才说这句,所以不必再提「中转站」那个分类词 ——
        // 用户此刻已经在状态行里看见那家的名字了
        .setupDesc1: [
            .zhHans: "在浏览器里打开它的用量统计页面,把地址栏的完整网址复制过来。",
            .zhHant: "在瀏覽器裡開啟它的用量統計頁面,把網址列的完整網址複製過來。",
            .en: "Open its usage-stats page in a browser and copy the full URL from the address bar."],
        .setupDescKey: [
            .zhHans: "粘贴这家供应商给你的 API Key。",
            .zhHant: "貼上這家供應商給你的 API Key。",
            .en: "Paste the API key this provider gave you."],

        // ── 安全说明:**必须跟着凭据性质走** ──────────────────
        //
        // 从前这里只有一句「只能查看用量,不能发起请求」,那是中转站 apiId 的性质,
        // 被当成了通用前提。接入带密钥的供应商之后,原样说下去就是在对着一把
        // 能花钱的 key 做一个假的安全承诺 —— 比不说更糟。
        .setupSafetyIdentifier: [
            .zhHans: "网址里的 apiId 只能查看用量,不能发起请求,也拿不到你的 API Key。",
            .zhHant: "網址裡的 apiId 只能檢視用量,不能發出請求,也拿不到你的 API Key。",
            .en: "The apiId in that URL can only read usage — it can’t make requests or reveal your API key."],
        .setupSafetySecret: [
            .zhHans: "这是一把能发起真实调用的密钥。它只存在本机钥匙串里,不会上传,也只用于查询你的额度。",
            .zhHant: "這是一把能發出真實呼叫的金鑰。它只存在本機鑰匙圈裡,不會上傳,也只用於查詢你的額度。",
            .en: "This key can make real API calls. It is stored only in your Mac’s Keychain, never uploaded, and is used only to read your quota."],
        .setupTest: [
            .zhHans: "测试连接", .zhHant: "測試連線", .en: "Test connection"],
        .setupSave: [
            .zhHans: "保存", .zhHant: "儲存", .en: "Save"],
        .setupSupportedLink: [
            .zhHans: "这个 app 支持哪些服务?", .zhHant: "這個 app 支援哪些服務?",
            .en: "Which services does this app support?"],
        .setupWaiting: [
            .zhHans: "等待输入", .zhHant: "等待輸入", .en: "Waiting for input"],
        .setupTesting: [
            .zhHans: "正在连接…", .zhHant: "正在連線…", .en: "Connecting…"],
        .setupSuccessFormat: [
            .zhHans: "✓ 连接成功 — %@ · %@", .zhHant: "✓ 連線成功 — %@ · %@",
            .en: "✓ Connected — %@ · %@"],
        .setupFailureFormat: [
            .zhHans: "✗ %@", .zhHant: "✗ %@", .en: "✗ %@"],

        // ── 通知 ──────────────────────────────────────────
        .notifyLowTitleFormat: [
            .zhHans: "「%@」额度不足", .zhHant: "「%@」額度不足",
            .en: "%@ is running low"],
        .notifyLowBodyFormat: [
            .zhHans: "剩余 %@ · %@", .zhHant: "剩餘 %@ · %@",
            .en: "%@ left · %@"],
        .notifyPaceTitleFormat: [
            .zhHans: "「%@」消费偏快", .zhHant: "「%@」消耗偏快",
            .en: "%@ is being used quickly"],
        .notifyPaceBodyFormat: [
            .zhHans: "剩余 %@ · %@,按当前速度会在重置前用完",
            .zhHant: "剩餘 %@ · %@,依目前速度會在重設前用完",
            .en: "%@ left · %@ — at this rate it runs out before the reset"],

        // ── 错误 ──────────────────────────────────────────
        .errInvalidURLFormat: [
            .zhHans: "网址无效:%@", .zhHant: "網址無效:%@", .en: "Invalid URL: %@"],
        .errHTTPFormat: [
            .zhHans: "服务器返回 HTTP %d", .zhHant: "伺服器回傳 HTTP %d",
            .en: "Server returned HTTP %d"],
        .errNoData: [
            .zhHans: "服务器没有返回数据", .zhHant: "伺服器沒有回傳資料",
            .en: "The server returned no data"],
        .errUnparsable: [
            .zhHans: "响应格式无法解析,请确认网址指向的是中转站统计接口",
            .zhHant: "回應格式無法解析,請確認網址指向的是中轉站統計介面",
            .en: "Couldn’t parse the response — check that the URL points to the relay’s stats API"],
        .errApiFailed: [
            .zhHans: "接口返回失败,apiId 可能不正确", .zhHant: "介面回傳失敗,apiId 可能不正確",
            .en: "The API reported a failure — the apiId may be wrong"],
        // 该带密钥的供应商没拿到密钥。多半是钥匙串里那条被删了(换过机器、
        // 重装过系统),得让用户重新填一次,而不是对着一句「请求失败」猜。
        .setupRevealSecret: [
            .zhHans: "显示密钥", .zhHant: "顯示金鑰", .en: "Show the key"],
        .setupHideSecret: [
            .zhHans: "隐藏密钥", .zhHant: "隱藏金鑰", .en: "Hide the key"],
        // 保存按钮灰着总得有个理由 —— 不说的话用户会以为是自己填错了
        .setupMustTestFirst: [
            .zhHans: "这家的账户标识在响应里,先「测试连接」才能保存",
            .zhHant: "這家的帳戶識別在回應裡,先「測試連線」才能儲存",
            .en: "This provider reports its account ID in the response — test the connection before saving"],
        .errMissingCredential: [
            .zhHans: "缺少密钥,请重新填写并测试连接",
            .zhHant: "缺少金鑰,請重新填寫並測試連線",
            .en: "The API key is missing — enter it again and test the connection"],
        .setupUnsupported: [
            .zhHans: "认不出这个网址对应的服务,请确认它是中转站的用量统计页面",
            .zhHant: "認不出這個網址對應的服務,請確認它是中轉站的用量統計頁面",
            .en: "Couldn’t tell which service this URL belongs to — check that it’s a relay usage-stats page"],
        .setupRecognizedFormat: [
            .zhHans: "已识别:%@", .zhHant: "已識別:%@", .en: "Recognized: %@"],

        // ── 连接报告里的提示 ──────────────────────────────
        .findNoLimitedQuota: [
            .zhHans: "没有任何带上限的额度,无法显示百分比和消费速度",
            .zhHant: "沒有任何帶上限的額度,無法顯示百分比與消費速度",
            .en: "No quota has a limit — percentages and pace can’t be shown"],
        .findIncompleteUsage: [
            .zhHans: "响应缺少部分用量字段,这次的数字不会计入历史",
            .zhHant: "回應缺少部分用量欄位,這次的數字不會計入歷史",
            .en: "Some usage fields are missing — this reading won’t enter history"],
        .findDailyResetInferred: [
            .zhHans: "接口不提供日重置时刻,将由观测推算,在此之前标注为推算",
            .zhHant: "介面不提供日重置時刻,將由觀測推算,在此之前標註為推算",
            .en: "The API doesn’t publish the daily reset hour — it will be inferred and labelled as such"],
        .findNoResetWindow: [
            .zhHans: "没有可信的重置周期,速度判断不可用",
            .zhHant: "沒有可信的重置週期,速度判斷不可用",
            .en: "No trustworthy reset period — the pace verdict is unavailable"],
        .findHistoryIsLocalOnly: [
            .zhHans: "接口没有历史查询,历史将从今天起本地积累",
            .zhHant: "介面沒有歷史查詢,歷史將從今天起本地累積",
            .en: "The API has no history endpoint — history accumulates locally from today"],

        .errInvalidFieldFormat: [
            .zhHans: "响应里的字段「%@」类型不对,本次数据已丢弃",
            .zhHant: "回應裡的欄位「%@」型別不對,本次資料已捨棄",
            .en: "Field “%@” in the response has the wrong type — this reading was discarded"],
        .errHistoryStore: [
            .zhHans: "历史数据库出错", .zhHant: "歷史資料庫發生錯誤",
            .en: "History database error"],
    ]
}
