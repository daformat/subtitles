// The language the app's own words are in: its menus, windows and captions
// about itself. Not the language anything is transcribed or translated into,
// which is Language / Models and Translate To.
//
// The system's by default, and otherwise the one chosen in Settings ▸
// Language, kept the way macOS keeps a per-app language (System Settings ▸
// General ▸ Language & Region ▸ Applications writes the same key): the app's
// own AppleLanguages. Bundle.main reads that at launch. A choice made while
// the app runs takes effect at once: the lookups move to that language's
// .lproj, the menu is rebuilt the next time it opens as it always is, and
// every window that is open is rebuilt in place. What macOS draws for the app
// (a text field's context menu, Sparkle's own messages, date formats) went
// by the launch language and follows at the next launch.

import AppKit
import CaptionCore
// [main-edition]
import LicenseCore
// [/main-edition]

enum AppLanguage {
    /// The app's translations, as their .lproj folders name them, each under
    /// its own name for itself. The sixteen of the site, in the order the
    /// Translate To menu lists them.
    static let all: [(code: String, name: String)] = [
        ("en", "English"),
        ("es", "Español"),
        ("fr", "Français"),
        ("it", "Italiano"),
        ("pt-BR", "Português (Brasil)"),
        ("de", "Deutsch"),
        ("nl", "Nederlands"),
        ("tr", "Türkçe"),
        ("ru", "Русский"),
        ("ar", "العربية"),
        ("hi", "हिन्दी"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("vi", "Tiếng Việt"),
        ("uk", "Українська"),
        ("zh-Hans", "简体中文"),
    ]

    private static let key = "AppleLanguages"

    /// The language chosen in Settings, or nil for the system's. Read from
    /// this app's own domain only: `UserDefaults.standard` would answer with
    /// the system-wide list when the app has none of its own.
    static var chosen: String? {
        guard let id = Bundle.main.bundleIdentifier,
              let list = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String],
              let first = list.first
        else { return nil }
        return Bundle.preferredLocalizations(from: all.map(\.code), forPreferences: [first]).first
    }

    /// Choose a language for the next launch, or nil to follow the system.
    static func choose(_ code: String?) {
        if let code {
            UserDefaults.standard.set([code], forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The language the app's words are in now: the launch's, until one is
    /// chosen.
    private(set) static var current = Bundle.main.preferredLocalizations.first ?? "en"

    /// The language a choice comes to: itself, or for the system's, what
    /// the system's list comes to among the app's translations.
    private static var resolved: String {
        if let chosen { return chosen }
        let system = CFPreferencesCopyValue(
            key as CFString, kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? ["en"]
        return Bundle.preferredLocalizations(from: all.map(\.code), forPreferences: system).first ?? "en"
    }

    /// The app's language as a locale, for sizes, dates and times: the
    /// system's formatters go by the language the process started in, which
    /// a choice in Settings may have moved away from.
    static var locale: Locale { Locale(identifier: current) }

    /// A size in bytes, as the app's language writes one ("1,25 Go").
    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file).locale(locale))
    }

    /// A page on the site, in the language the app is in when the site has
    /// it (the site has all sixteen): `path` is relative to the site's root,
    /// "changelog/" or "" for the home page.
    static func siteURL(_ path: String) -> URL {
        let prefix: String
        switch current {
        case "en": prefix = ""
        case "pt-BR": prefix = "pt/"
        case "zh-Hans": prefix = "zh/"
        case let code: prefix = code + "/"
        }
        return URL(string: "https://subtitles-live.com/" + prefix + path)!
    }

    /// Right to left for a right-to-left language (Arabic), whatever the
    /// system's direction. AppKit takes the layout direction from the
    /// system rather than from the app's own language, so Arabic chosen here
    /// on an English Mac drew its menu and windows left to right, and a
    /// sentence of Arabic with a period in it came out in the wrong order.
    /// Read once, as the application starts: a language chosen while the app
    /// runs gets its direction at the next launch.
    static func applyLayoutDirection() {
        let rtl = Locale.Language(identifier: current).characterDirection == .rightToLeft
        UserDefaults.standard.register(defaults: [
            "AppleTextDirection": rtl,
            "NSForceRightToLeftWritingDirection": rtl,
        ])
    }

    /// Choose a language, or nil to follow the system's, and switch to it
    /// now. `rebuild` redraws the open windows in it.
    static func switchTo(_ code: String?, rebuild: () -> Void) {
        choose(code)
        let language = resolved
        guard language != current else { return }
        current = language
        let lproj = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
        Localization.bundle = lproj ?? .main
        Localization.language = language
        // [main-edition]
        LicenseLocalization.bundle = lproj ?? .main
        LicenseLocalization.language = language
        // [/main-edition]
        rebuild()
    }
}
