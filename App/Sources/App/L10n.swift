import SwiftUI

/// lib/i18n for the Swift UI: upstream's catalogs (tools/build_locales.mjs → App/Locales), keyed by
/// the English source string, looked up for settings.uiLanguage rather than the system language.
///
/// - `Text("literal")`, `Button("…")`, `Label("…", systemImage:)` are LocalizedStringKeys: SwiftUI
///   resolves them against `\.locale`, which RootView sets from `L10n.locale`.
/// - String-typed copy (BPNote, hint labels, section titles) goes through `T(_:)`, which reads the
///   chosen language's .lproj directly (Bundle.main alone would follow the system language), and
///   is shown with `Text(String)`, which never looks anything up again.
/// - Engine-built strings arrive translated: SettingsBridge installs the same catalog into the
///   engine's lib/i18n (settingsRoom.installUiCatalog), so T() on them is a harmless miss.
enum L10n {
    /// lib/i18n/languages.ts LANGUAGES codes; anything else normalises to English (normalizeLanguage).
    static let languages: Set<String> = ["en", "ar", "de", "es", "fr", "hi", "id", "it", "ja", "ko", "pl", "pt", "ru", "tr", "vi", "zh"]
    /// languages.ts `rtl: true`.
    static let rtlLanguages: Set<String> = ["ar"]

    private(set) static var language = "en"
    private static var table: Bundle?

    static var locale: Locale { Locale(identifier: language) }
    static var isRTL: Bool { rtlLanguages.contains(language) }
    static var layoutDirection: LayoutDirection { isRTL ? .rightToLeft : .leftToRight }

    /// languages.ts normalizeLanguage: "pt-BR" → "pt", unknown → "en".
    static func normalize(_ code: String) -> String {
        let base = code.trimmingCharacters(in: .whitespaces).lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return languages.contains(base) ? base : "en"
    }

    /// Called whenever SettingsBridge's slice changes; cheap when the language did not.
    static func setLanguage(_ code: String) {
        let lang = normalize(code)
        guard lang != language || (lang != "en" && table == nil) else { return }
        language = lang
        table = lang == "en" ? nil : Bundle.main.path(forResource: lang, ofType: "lproj").flatMap { Bundle(path: $0) }
    }

    /// The chosen language's translation of an English source string, or the string itself.
    static func lookup(_ key: String) -> String {
        guard let table, !key.isEmpty else { return key }
        return table.localizedString(forKey: key, value: key, table: nil)
    }

    // MARK: engine catalog

    private static var engineInstalled: Set<String> = ["en"]

    /// load-locale.ts ensureUiLocale for the engine: hands App/Locales/<lang>.json (upstream's
    /// catalog, plural variants included) to lib/i18n once per language.
    @MainActor static func installEngineCatalog(_ code: String) async {
        let lang = normalize(code)
        guard !engineInstalled.contains(lang) else { return }
        if let already: Bool = try? await HarborEngine.shared.call("settingsRoom.uiCatalogInstalled", [lang]), already {
            engineInstalled.insert(lang)
            return
        }
        guard let url = Bundle.main.url(forResource: lang, withExtension: "json"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return }
        if let ok: Bool = try? await HarborEngine.shared.call("settingsRoom.installUiCatalog", [lang, raw]), ok {
            engineInstalled.insert(lang)
        }
    }
}

/// translate.ts t(key) for String-typed Swift copy: the English source string in, the chosen
/// language's text out. Show the result with `Text(_: String)` (verbatim), never as a key again.
func T(_ key: String) -> String { L10n.lookup(key) }

/// t(key, vars) for a Swift-format key ("%lld results", "%@ of %@"): the generated catalogs carry
/// every upstream "{n}" key in this spelling, with positional specifiers in the translation.
func T(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.lookup(key), locale: L10n.locale, arguments: args)
}

/// A count key whose plural forms live in the catalogs' .stringsdict ("%lld wins" → "1 Sieg"):
/// English has no catalog, so its singular ("%lld win") is spelled here instead of "1 wins".
func TCount(_ n: Int, one: String, _ key: String) -> String {
    n == 1 && L10n.language == "en" ? String(format: one, n) : T(key, n)
}
