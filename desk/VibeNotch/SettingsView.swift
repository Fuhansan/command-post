import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    /// Re-resolved on each render so language changes apply live without
    /// needing to close and reopen the window.
    private var locale: L10n.Locale { L10n.resolved(from: settings.language) }

    var body: some View {
        Form {
            Section(L10n.t(.settingsSectionGeneral, locale: locale)) {
                Picker(L10n.t(.settingsLanguage, locale: locale), selection: $settings.language) {
                    Text(L10n.t(.settingsLangSystem,  locale: locale)).tag(AppSettings.Language.system)
                    Text(L10n.t(.settingsLangEnglish, locale: locale)).tag(AppSettings.Language.english)
                    Text(L10n.t(.settingsLangChinese, locale: locale)).tag(AppSettings.Language.chinese)
                }
                .pickerStyle(.menu)

                Toggle(L10n.t(.settingsLaunchAtLogin, locale: locale), isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))

                Toggle(L10n.t(.settingsMuteSounds, locale: locale), isOn: $settings.muted)
            }

            Section {
                Text(L10n.t(.settingsConfigPath, locale: locale))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 280)
    }
}
