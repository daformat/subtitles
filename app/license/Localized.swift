// The app's copy in the reader's language.
//
// Every string a person reads goes through one of these three, and the English
// is the key: the code says what it says, in English, where it is used, and a
// language with no translation for it shows that. The translations are
// app/Localization/<language>.json, compiled into each .lproj by build.sh
// (tools/strings.py). Bundle.main picks the language at launch: the system's,
// or the one chosen in Settings ▸ Language, which is the app's own
// AppleLanguages. A language chosen while the app runs points `bundle` at its
// .lproj instead, so the app's words switch at once (AppLanguage.swift).
//
// A key may carry its context ahead of a bar, "glow strength|Medium", when the
// same English means two things another language says differently; the part
// after the bar is the English shown.
//
// A copy of CaptionCore's Localized.swift: this module cannot see that one,
// and tools/strings.py reads both. Internal here, so the two never clash.

import Foundation

/// Where the strings are looked up: the app's bundle, or one language's
/// .lproj in it once a language has been chosen while the app runs.
public enum LicenseLocalization {
    public static var bundle: Bundle = .main
    /// The language `bundle` is in, which decides a count's plural form:
    /// Russian's 5 is not its 3, whatever the system's region.
    public static var language = Bundle.main.preferredLocalizations.first ?? "en"
}

/// The string for `key`, in the app's language. `comment` is for the
/// translators, read out of the source by tools/strings.py; it changes nothing
/// at run time.
func L(_ key: String, _ comment: String = "") -> String {
    LicenseLocalization.bundle.localizedString(forKey: key, value: english(key), table: nil)
}

/// `L`, with `args` put into its %@ and %lld.
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

/// A string that changes with a count: `other` is the English for most
/// counts and the key, `one` the English for exactly one, and a language's own
/// forms (Russian's few and many, Arabic's six) come from its stringsdict.
/// The count is the format's only argument, as %lld.
func LP(_ other: String, one: String, _ count: Int) -> String {
    let missing = "\u{0}"
    let found = LicenseLocalization.bundle.localizedString(forKey: other, value: missing, table: nil)
    guard found != missing else {
        return String(format: count == 1 ? one : other, locale: Locale.current, count)
    }
    // Straight from the bundle, so the string still carries its plural rules.
    return String(format: found, locale: Locale(identifier: LicenseLocalization.language), count)
}

private func english(_ key: String) -> String {
    guard let bar = key.firstIndex(of: "|") else { return key }
    return String(key[key.index(after: bar)...])
}
