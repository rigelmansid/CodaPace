import Foundation
import CodaPaceCore

final class LocalizationTests: XCTestCase {

    /// 最重要的一条:**每个 key 在每种语言下都必须有译文**。
    /// 漏译在界面上很难发现(要恰好切到那个语言、恰好走到那个界面),
    /// 交给测试守着才靠谱。
    func testEveryKeyIsTranslatedInEveryLanguage() {
        var missing: [String] = []

        for key in LangKey.allCases {
            guard let entry = L10n.entry(key) else {
                missing.append("\(key.rawValue):整条缺失")
                continue
            }
            for language in Language.allCases where entry[language] == nil {
                missing.append("\(key.rawValue) 缺 \(language.rawValue)")
            }
        }

        XCTAssertTrue(missing.isEmpty, "漏译 \(missing.count) 处:\(missing.prefix(8).joined(separator: ", "))")
    }

    /// 译文不能是空串 —— 界面上会变成一片空白,比漏译更难查
    func testNoTranslationIsEmpty() {
        var empties: [String] = []
        for key in LangKey.allCases {
            for language in Language.allCases {
                if L10n.text(key, language).trimmingCharacters(in: .whitespaces).isEmpty {
                    empties.append("\(key.rawValue)/\(language.rawValue)")
                }
            }
        }
        XCTAssertTrue(empties.isEmpty, "空译文:\(empties.joined(separator: ", "))")
    }

    /// 带占位符的文案,各语言的占位符数量必须一致,
    /// 否则 String(format:) 会少填或读到越界内存
    func testPlaceholderCountsMatchAcrossLanguages() {
        var mismatched: [String] = []

        for key in LangKey.allCases {
            guard let entry = L10n.entry(key), let reference = entry[.en] else { continue }
            let expected = placeholders(in: reference)

            for language in Language.allCases {
                guard let text = entry[language] else { continue }
                if placeholders(in: text) != expected {
                    mismatched.append("\(key.rawValue)/\(language.rawValue)")
                }
            }
        }

        XCTAssertTrue(mismatched.isEmpty, "占位符不匹配:\(mismatched.joined(separator: ", "))")
    }

    /// 数一条文案里的 %@ 和 %d(顺序也要一致)
    private func placeholders(in text: String) -> [String] {
        var result: [String] = []
        var iterator = text.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            guard character == "%" else { continue }
            guard let next = iterator.next() else { break }
            if next == "%" { continue }          // %% 是转义,不算占位符
            result.append("%\(next)")
        }
        return result
    }

    // MARK: 查表行为

    func testLookupReturnsRequestedLanguage() {
        XCTAssertEqual(L10n.text(.quit, .zhHans), "退出")
        XCTAssertEqual(L10n.text(.quit, .zhHant), "結束")
        XCTAssertEqual(L10n.text(.quit, .en), "Quit")
    }

    func testFormatSubstitutesArguments() {
        XCTAssertEqual(L10n.format(.durDaysFormat, .zhHans, 3), "3 天")
        XCTAssertEqual(L10n.format(.errHTTPFormat, .en, 503), "Server returned HTTP 503")
    }

    /// 只支持三种语言,不该悄悄多出别的
    func testOnlyThreeLanguagesAreSupported() {
        XCTAssertEqual(Language.allCases.count, 3)
    }

    // MARK: 系统语言识别

    func testSimplifiedAndTraditionalChineseAreDistinguished() {
        XCTAssertEqual(Language.systemDefault(preferred: ["zh-Hans-CN"]), .zhHans)
        XCTAssertEqual(Language.systemDefault(preferred: ["zh-Hant-TW"]), .zhHant)
        XCTAssertEqual(Language.systemDefault(preferred: ["zh-HK"]), .zhHant)
        XCTAssertEqual(Language.systemDefault(preferred: ["zh-CN"]), .zhHans)
    }

    func testEnglishVariantsAreRecognised() {
        XCTAssertEqual(Language.systemDefault(preferred: ["en-GB"]), .en)
        XCTAssertEqual(Language.systemDefault(preferred: ["en"]), .en)
    }

    /// 认不出就用英文,而不是崩掉或留空。
    /// 曾经支持过西/法/德,现在它们也走这条回落路径。
    func testUnsupportedLanguageFallsBackToEnglish() {
        XCTAssertEqual(Language.systemDefault(preferred: ["ja-JP", "ko-KR"]), .en)
        XCTAssertEqual(Language.systemDefault(preferred: ["fr-FR", "de-DE"]), .en)
        XCTAssertEqual(Language.systemDefault(preferred: []), .en)
    }

    /// 按偏好顺序取第一个认得的,不认得的跳过
    func testFirstRecognisedPreferenceWins() {
        XCTAssertEqual(Language.systemDefault(preferred: ["ja-JP", "zh-TW", "en-US"]), .zhHant)
        XCTAssertEqual(Language.systemDefault(preferred: ["fr-FR", "en-US"]), .en)
    }

    func testEveryLanguageHasADisplayName() {
        for language in Language.allCases {
            XCTAssertFalse(language.displayName.isEmpty)
        }
    }
}
