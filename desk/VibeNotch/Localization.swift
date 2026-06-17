import Foundation

/// Hand-rolled string table — VibeNotch only has a handful of user-facing
/// strings (status menu + settings window), so a Localizable.strings setup
/// would be more ceremony than payoff. Adding a new locale = add a `case` in
/// `Locale` + a column in each entry of `table`.
enum L10n {
    enum Locale: String { case en, zh }

    /// Resolved locale = explicit user choice, or follow system if `.system`.
    static func resolved(from setting: AppSettings.Language) -> Locale {
        switch setting {
        case .english: return .en
        case .chinese: return .zh
        case .system:
            let pref = Foundation.Locale.preferredLanguages.first ?? "en"
            return pref.hasPrefix("zh") ? .zh : .en
        }
    }

    static func t(_ key: Key, locale: Locale) -> String {
        table[key]?[locale] ?? key.rawValue
    }

    enum Key: String {
        case menuSettings, menuDisplayOn, menuDisplayAuto, menuDisplayNotchSuffix, menuQuit
        case settingsTitle, settingsSectionGeneral
        case settingsLanguage, settingsLangSystem, settingsLangEnglish, settingsLangChinese
        case settingsLaunchAtLogin, settingsMuteSounds
        case settingsConfigPath
    }

    /// Note: `…` (U+2026) is intentional; macOS HIG uses it on menu items
    /// that open a window (vs. items that perform an action immediately).
    private static let table: [Key: [Locale: String]] = [
        .menuSettings:            [.en: "Settings…",          .zh: "设置…"],
        .menuDisplayOn:           [.en: "Display on",         .zh: "显示位置"],
        .menuDisplayAuto:         [.en: "Auto (notch screen)", .zh: "自动（凹口屏）"],
        .menuDisplayNotchSuffix:  [.en: "(notch)",            .zh: "（凹口）"],
        .menuQuit:                [.en: "Quit VibeNotch",     .zh: "退出 VibeNotch"],

        .settingsTitle:           [.en: "VibeNotch Settings", .zh: "VibeNotch 设置"],
        .settingsSectionGeneral:  [.en: "General",            .zh: "通用"],

        .settingsLanguage:        [.en: "Language",           .zh: "语言"],
        .settingsLangSystem:      [.en: "Follow system",      .zh: "跟随系统"],
        .settingsLangEnglish:     [.en: "English",            .zh: "English"],
        .settingsLangChinese:     [.en: "中文（简体）",        .zh: "中文（简体）"],

        .settingsLaunchAtLogin:   [.en: "Launch at login",    .zh: "开机自动启动"],
        .settingsMuteSounds:      [.en: "Mute notification sounds", .zh: "静音提示音"],

        .settingsConfigPath:      [.en: "Config: ~/.vibenotch/settings.json",
                                   .zh: "配置文件：~/.vibenotch/settings.json"],
    ]
}
