import Foundation

// MARK: - Languages

struct Lang: Equatable {
    let name: String
    let locale: String
    let code: String
}

let sourceLanguages: [Lang] = [
    .init(name: "English", locale: "en-US", code: "en"),
    .init(name: "日本語", locale: "ja-JP", code: "ja"),
    .init(name: "中文", locale: "zh-CN", code: "zh-CN"),
    .init(name: "한국어", locale: "ko-KR", code: "ko"),
    .init(name: "Español", locale: "es-ES", code: "es"),
    .init(name: "Français", locale: "fr-FR", code: "fr"),
    .init(name: "Deutsch", locale: "de-DE", code: "de"),
    .init(name: "Português", locale: "pt-BR", code: "pt"),
]

let targetLanguages: [Lang] = [
    .init(name: "简体中文", locale: "zh-Hans", code: "zh-CN"),
    .init(name: "繁體中文", locale: "zh-Hant", code: "zh-TW"),
    .init(name: "English", locale: "en", code: "en"),
    .init(name: "日本語", locale: "ja", code: "ja"),
    .init(name: "한국어", locale: "ko", code: "ko"),
    .init(name: "Español", locale: "es", code: "es"),
    .init(name: "Français", locale: "fr", code: "fr"),
    .init(name: "Deutsch", locale: "de", code: "de"),
    .init(name: "Português", locale: "pt", code: "pt"),
]

func translationCode(forSystemLanguage id: String) -> String {
    let locale = Locale(identifier: id)
    let lang = locale.language.languageCode?.identifier ?? "en"
    guard lang == "zh" else { return lang }
    let script = locale.language.script?.identifier
    let region = locale.region?.identifier
    if script == "Hant" { return "zh-TW" }
    if script == nil, let region, ["TW", "HK", "MO"].contains(region) { return "zh-TW" }
    return "zh-CN"
}

func myLanguage(systemLanguages prefs: [String]) -> String {
    translationCode(forSystemLanguage: prefs.first { $0.hasPrefix("zh") } ?? prefs.first ?? "zh-Hans")
}

func followSystemTarget(source: String?, systemLanguages prefs: [String]) -> String {
    let mine = myLanguage(systemLanguages: prefs)
    guard let source, source == mine else { return mine }
    return prefs.map(translationCode(forSystemLanguage:)).first { $0 != mine }
        ?? (mine.hasPrefix("zh") ? "en" : "zh-CN")
}

func likelySourceLanguages(last: String?, systemLanguages prefs: [String]) -> [Lang] {
    var out: [Lang] = []
    func add(_ lang: Lang?) { if let lang, !out.contains(lang) { out.append(lang) } }
    add(sourceLanguages.first { $0.locale == last })
    for id in prefs {
        let code = translationCode(forSystemLanguage: id)
        add(sourceLanguages.first { $0.code == (code.hasPrefix("zh") ? "zh-CN" : code) })
    }
    add(sourceLanguages.first { $0.code == "en" })
    return out
}

func initialSourceLanguage(candidates: [Lang], last: String?, systemLanguages prefs: [String],
                           mine: Lang? = nil) -> Lang {
    if let mine { return mine }
    if let last, let lang = candidates.first(where: { $0.locale == last }) { return lang }
    let likely = likelySourceLanguages(last: last, systemLanguages: prefs)
    return likely.first(where: { candidates.contains($0) })
        ?? likely.first
        ?? candidates.first
        ?? sourceLanguages[0]
}

func speakLocale(forLanguage code: String) -> String {
    if code.hasPrefix("zh") { return "zh-CN" }
    return sourceLanguages.first { $0.code == code }?.locale ?? "en-US"
}

func targetName(_ code: String) -> String {
    targetLanguages.first(where: { $0.code == code })?.name
        ?? Locale.current.localizedString(forIdentifier: code) ?? code
}

func joiner(for code: String) -> String {
    (code.hasPrefix("zh") || code == "ja") ? "" : " "
}

