//
//  LanguageStore.swift — 当前语言(界面侧)
//
//  文案表在 Core/Localization.swift 里,这里只持有「当前选了哪种语言」
//  并让 SwiftUI 能观察到它,所以切换语言立刻生效,不用重启。
//
//  文件名和类名不一致是刻意的:build.sh 把 Core 和 App 编成同一个模块,
//  文件名必须全局唯一,而 Core 那边已经占用了 Localization.swift。
//

import Foundation

@MainActor
final class Localization: ObservableObject {

    static let shared = Localization()

    @Published var language: Language = Config.language {
        didSet { Config.language = language }
    }

    func t(_ key: LangKey) -> String {
        L10n.text(key, language)
    }

    func f(_ key: LangKey, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }
}
