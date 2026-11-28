import Foundation

func L(_ value: String.LocalizationValue) -> String { String(localized: value) }

var uiLocale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "zh-Hans") }

var uiIsChinese: Bool { (Bundle.main.preferredLocalizations.first ?? "zh").hasPrefix("zh") }

func dateText(_ date: Date, _ template: String) -> String {
    let f = DateFormatter()
    f.locale = uiLocale
    f.setLocalizedDateFormatFromTemplate(template)
    return f.string(from: date)
}

let appDisplayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? L("知了")
