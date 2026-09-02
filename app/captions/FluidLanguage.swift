import Foundation

/// A language the multilingual model can be pinned to, plus `auto`.
///
/// The repo ships two vocabularies and the download follows the language, not the
/// user: the six Latin-script languages share a pruned 2828-token pack (583 MB),
/// while every other language needs the full 13087-token pack (633 MB), `auto`
/// included, since it must be able to decode anything. Switching within a pack is free;
/// crossing between them is another download, which is why the two groups are kept
/// visibly apart in the menu.
///
/// Script is not the split, despite the name upstream gives it: Dutch, Turkish and
/// Vietnamese are Latin-script and still take the full pack, because the pruned one
/// was built for the six languages upstream lists and its 2828 tokens cover nothing
/// beyond them.
///
/// The set is NVIDIA's transcription-ready tier: the 19 locales the model card
/// calls accurate out of the box, which collapse to 15 languages once the regional
/// pairs (en-US/en-GB, pt-BR/pt-PT, …) are folded together. Mandarin joins them from
/// a tier down. The checkpoint reaches ~40 locales in all; the rest are
/// broad-coverage or need fine-tuning first, and each is one `code` away.
public enum FluidLanguage: String, CaseIterable, Sendable {
    case auto
    case en, es, fr, it, pt, de
    case nl, tr, ru, ar, hi, ja, ko, vi, uk
    /// Broad-coverage rather than transcription-ready, unlike the rest of these.
    /// Kept because it shipped first and the pack it needs is downloaded anyway.
    case zh

    /// FLEURS-style code the model's prompt dictionary is keyed on.
    public var code: String {
        switch self {
        case .auto: return "auto"
        case .en: return "en-US"
        case .es: return "es-ES"
        case .fr: return "fr-FR"
        case .it: return "it-IT"
        case .pt: return "pt-BR"
        case .de: return "de-DE"
        case .nl: return "nl-NL"
        case .tr: return "tr-TR"
        case .ru: return "ru-RU"
        case .ar: return "ar-AR"
        case .hi: return "hi-IN"
        case .ja: return "ja-JP"
        case .ko: return "ko-KR"
        case .vi: return "vi-VN"
        case .uk: return "uk-UA"
        case .zh: return "zh-CN"
        }
    }

    public var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .en: return "English"
        case .es: return "Español"
        case .fr: return "Français"
        case .it: return "Italiano"
        case .pt: return "Português"
        case .de: return "Deutsch"
        case .nl: return "Nederlands"
        case .tr: return "Türkçe"
        case .ru: return "Русский"
        case .ar: return "العربية"
        case .hi: return "हिन्दी"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .vi: return "Tiếng Việt"
        case .uk: return "Українська"
        case .zh: return "中文"
        }
    }

    /// True when this language is served by the smaller Latin-script pack.
    /// Mirrors `StreamingNemotronMultilingualAsrManager.languageDirectory`.
    public var usesLatinPack: Bool {
        switch self {
        case .en, .es, .fr, .it, .pt, .de: return true
        case .auto, .nl, .tr, .ru, .ar, .hi, .ja, .ko, .vi, .uk, .zh: return false
        }
    }
}

extension FluidLanguage {
    /// The framework keys on ISO 639-1, which is exactly this enum's raw value —
    /// not the FLEURS-style `code` the recogniser's prompt dictionary wants.
    public var locale: Locale.Language { Locale.Language(identifier: rawValue) }

    /// Match what the multilingual checkpoint reports it is hearing — a
    /// FLEURS-style `fr-FR`, which is this enum's `code`, not its raw value.
    /// Falls back to the bare language subtag so a locale we do not list
    /// (`en-GB` against our `en-US`) still resolves.
    public static func matching(code: String) -> FluidLanguage? {
        if let exact = allCases.first(where: { $0.code == code }) { return exact }
        let base = code.split(separator: "-").first.map(String.init) ?? code
        return allCases.first { $0 != .auto && $0.rawValue == base }
    }
}
