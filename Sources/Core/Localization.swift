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
    case chartNoSamples, chartNoTokenDays

    // 历史窗口
    case historyTitle, historyQuota, historyRange, historySampleCountFormat
    case historyLimitFormat, historyNoLimit
    case historyRangeHoursFormat, historyRangeDaysFormat
    case historyNoLimitMessage, historyNoSamplesMessage, historyNoTokensMessage
    case historyAboutTitle, historyNote1, historyNote2, historyNote3, historyNote4
    case historyTokensTotalFormat, historyTokensByDay

    // 配置窗口
    case setupWindowTitle, setupTitle, setupDesc1, setupDesc2, setupPlaceholder
    case setupTest, setupSave, setupSupportedLink
    case setupWaiting, setupNoApiId, setupParsable, setupTesting
    case setupSuccessFormat, setupFailureFormat

    // 通知
    case notifyLowTitleFormat, notifyLowBodyFormat
    case notifyPaceTitleFormat, notifyPaceBodyFormat

    // 错误
    case errInvalidURLFormat, errHTTPFormat, errNoData, errUnparsable, errApiFailed
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
        .historyNoLimitMessage: [
            .zhHans: "这条额度没有设上限,无法换算成剩余百分比",
            .zhHant: "這條額度沒有設上限,無法換算成剩餘百分比",
            .en: "This quota has no limit, so there’s no percentage to show"],
        .historyNoSamplesMessage: [
            .zhHans: "这段时间还没有采样。历史是从 app 装上那天开始攒的。",
            .zhHant: "這段時間還沒有取樣。歷史是從 app 安裝當天開始累積的。",
            .en: "No samples in this range. History starts accumulating the day you install the app."],
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
            .zhHans: "粘贴你的用量统计页面网址", .zhHant: "貼上你的用量統計頁面網址",
            .en: "Paste your usage-stats page URL"],
        .setupDesc1: [
            .zhHans: "在浏览器里打开中转站的用量统计页面,把地址栏的完整网址复制过来。",
            .zhHant: "在瀏覽器裡開啟中轉站的用量統計頁面,把網址列的完整網址複製過來。",
            .en: "Open your relay’s usage-stats page in a browser and copy the full URL from the address bar."],
        .setupDesc2: [
            .zhHans: "网址里的 apiId 只能查看用量,不能发起请求,也拿不到你的 API Key。",
            .zhHant: "網址裡的 apiId 只能檢視用量,不能發出請求,也拿不到你的 API Key。",
            .en: "The apiId in that URL can only read usage — it can’t make requests or reveal your API key."],
        .setupPlaceholder: [
            .zhHans: "https://你的域名/admin-next/api-stats?apiId=…",
            .zhHant: "https://你的網域/admin-next/api-stats?apiId=…",
            .en: "https://your-domain/admin-next/api-stats?apiId=…"],
        .setupTest: [
            .zhHans: "测试连接", .zhHant: "測試連線", .en: "Test connection"],
        .setupSave: [
            .zhHans: "保存", .zhHant: "儲存", .en: "Save"],
        .setupSupportedLink: [
            .zhHans: "这个 app 支持哪些中转站?", .zhHant: "這個 app 支援哪些中轉站?",
            .en: "Which relays does this app support?"],
        .setupWaiting: [
            .zhHans: "等待输入", .zhHant: "等待輸入", .en: "Waiting for input"],
        .setupNoApiId: [
            .zhHans: "⚠︎ 网址里没找到 apiId,请复制完整地址(含 ?apiId=… 部分)",
            .zhHant: "⚠︎ 網址裡沒找到 apiId,請複製完整位址(含 ?apiId=… 部分)",
            .en: "⚠︎ No apiId found in that URL — copy the full address, including ?apiId=…"],
        .setupParsable: [
            .zhHans: "网址可解析。建议先「测试连接」确认能取到数据。",
            .zhHant: "網址可解析。建議先「測試連線」確認能取得資料。",
            .en: "URL looks valid. Try “Test connection” before saving."],
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
        .errHistoryStore: [
            .zhHans: "历史数据库出错", .zhHant: "歷史資料庫發生錯誤",
            .en: "History database error"],
    ]
}
