import SwiftUI
import UIKit

/// components/flag.tsx's language → flag tables. Stream audio languages are upstream's parser
/// names ("English", "Portuguese (Brazil)", "Multi"), so the tables are keyed by name, as upstream.
/// engine/smoke.mjs compares both tables with flag.tsx, so keep one entry per line.
@MainActor
enum FlagArt {
    /// flag.tsx FLAG: the languages drawn with upstream's own art (src/assets/flags/*.svg), which
    /// tools/sync_upstream_assets.sh turns into vector imagesets in App/Upstream/Flags.xcassets.
    static let file: [String: String] = [
        "English": "flag-eng",
        "Italian": "flag-ita",
        "Russian": "flag-rus",
        "Hindi": "flag-hin",
        "Spanish": "flag-spa",
        "Spanish (Latin America)": "flag-spa",
        "Korean": "flag-kor",
        "Japanese": "flag-jpn",
        "Chinese": "flag-zho",
        "Chinese (Simplified)": "flag-zho",
        "Portuguese": "flag-prt",
        "Portuguese (Brazil)": "flag-bra",
        "German": "flag-deu",
        "French": "flag-fra",
        "Turkish": "flag-tur",
        "Arabic": "flag-ara",
        "Czech": "flag-ces",
        "Danish": "flag-dan",
        "Finnish": "flag-fin",
        "Hebrew": "flag-heb",
        "Hungarian": "flag-hun",
        "Dutch": "flag-nld",
        "Norwegian": "flag-nor",
        "Polish": "flag-pol",
        "Romanian": "flag-ron",
        "Swedish": "flag-swe",
        "Thai": "flag-tha",
        "Ukrainian": "flag-ukr",
        "Vietnamese": "flag-vie",
    ]

    /// flag.tsx LANG_COUNTRY: the languages upstream draws from the flag-icons set (`fi fi-{cc}`).
    /// That set is an npm package the TV build does not install, so these are drawn as the
    /// country's emoji flag (Apple Color Emoji); a region with no emoji flag gets the text chip.
    static let country: [String: String] = [
        "Indonesian": "id",
        "Greek": "gr",
        "Tamil": "in",
        "Telugu": "in",
        "Malayalam": "in",
        "Kannada": "in",
        "Bengali": "bd",
        "Marathi": "in",
        "Gujarati": "in",
        "Punjabi": "in",
        "Urdu": "pk",
        "Odia": "in",
        "Assamese": "in",
        "Nepali": "np",
        "Sinhala": "lk",
        "Malay": "my",
        "Filipino": "ph",
        "Burmese": "mm",
        "Khmer": "kh",
        "Lao": "la",
        "Persian": "ir",
        "Pashto": "af",
        "Azerbaijani": "az",
        "Georgian": "ge",
        "Armenian": "am",
        "Kazakh": "kz",
        "Uzbek": "uz",
        "Bulgarian": "bg",
        "Serbian": "rs",
        "Croatian": "hr",
        "Bosnian": "ba",
        "Slovak": "sk",
        "Slovenian": "si",
        "Lithuanian": "lt",
        "Latvian": "lv",
        "Estonian": "ee",
        "Icelandic": "is",
        "Irish": "ie",
        "Catalan": "es-ct",
        "Basque": "es-pv",
        "Galician": "es-ga",
        "Welsh": "gb-wls",
        "Maltese": "mt",
        "Albanian": "al",
        "Macedonian": "mk",
        "Belarusian": "by",
        "Swahili": "tz",
        "Amharic": "et",
        "Afrikaans": "za",
        "Hausa": "ng",
        "Yoruba": "ng",
        "Igbo": "ng",
        "Zulu": "za",
    ]

    /// The country each upstream flag file draws, for its emoji twin when the imageset is missing
    /// (a build that skipped the sync step). flag-eng is the US flag, flag-ara Saudi Arabia's.
    private static let fileCountry: [String: String] = [
        "flag-eng": "us", "flag-ita": "it", "flag-rus": "ru", "flag-hin": "in", "flag-spa": "es",
        "flag-kor": "kr", "flag-jpn": "jp", "flag-zho": "cn", "flag-prt": "pt", "flag-bra": "br",
        "flag-deu": "de", "flag-fra": "fr", "flag-tur": "tr", "flag-ara": "sa", "flag-ces": "cz",
        "flag-dan": "dk", "flag-fin": "fi", "flag-heb": "il", "flag-hun": "hu", "flag-nld": "nl",
        "flag-nor": "no", "flag-pol": "pl", "flag-ron": "ro", "flag-swe": "se", "flag-tha": "th",
        "flag-ukr": "ua", "flag-vie": "vn",
    ]

    private static var cache: [String: UIImage] = [:]
    private static var missing: Set<String> = []

    /// The upstream flag art for a language, read once from the asset catalog; nil when flag.tsx
    /// has no file for it or the imageset is not in the bundle.
    static func image(for language: String) -> UIImage? {
        guard let name = file[language] else { return nil }
        if let hit = cache[name] { return hit }
        if missing.contains(name) { return nil }
        guard let img = UIImage(named: name) else {
            missing.insert(name)
            return nil
        }
        cache[name] = img
        return img
    }

    /// The emoji flag for a language: its flag-icons country, else the country of its upstream
    /// file (only reached when that file's imageset is missing). nil when neither has one.
    static func emoji(for language: String) -> String? {
        if let cc = country[language] { return emoji(country: cc) }
        if let name = file[language], let cc = fileCountry[name] { return emoji(country: cc) }
        return nil
    }

    /// Regional-indicator pair for an ISO 3166 code; Wales has its tag sequence; the Spanish
    /// regions (es-ct, es-pv, es-ga) have no emoji flag.
    static func emoji(country cc: String) -> String? {
        if cc == "gb-wls" { return "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}" }
        let letters: [Unicode.Scalar] = Array(cc.lowercased().unicodeScalars)
        guard letters.count == 2 else { return nil }
        var out: String = ""
        for letter in letters {
            guard letter.value >= 97, letter.value <= 122,
                  let indicator = Unicode.Scalar(0x1F1E6 + letter.value - 97) else { return nil }
            out.unicodeScalars.append(indicator)
        }
        return out
    }
}

/// components/flag.tsx FlagStack: the first `maxCount` languages as flags (h tall, 1.5 h wide,
/// radius 2, the faint ring and drop shadow), "Multi" as an accent "M" chip, a language with no
/// flag as its first two letters in a quiet chip, then "+{n}" for the rest. bp-stream-row passes
/// the stream's audio languages without "unknown", max 4, size md.
struct FlagStack: View {
    enum Size { case sm, md, lg }

    let languages: [String]
    var maxCount: Int = 4
    var size: Size = .md

    /// bp-stream-row.tsx: `stream.audioLanguages.filter((l) => l.toLowerCase() !== "unknown")`.
    static func streamLanguages(_ audioLanguages: [String]?) -> [String] {
        let all: [String] = audioLanguages ?? []
        return all.filter { $0.lowercased() != "unknown" }
    }

    /// flag.tsx FLAG_HEIGHT.
    private var h: CGFloat {
        switch size {
        case .sm: return BP.px(12)
        case .md: return BP.px(16)
        case .lg: return BP.px(22)
        }
    }

    var body: some View {
        let limit: Int = maxCount > 0 ? maxCount : 0
        let shown: [String] = Array(languages.prefix(limit))
        let extra: Int = languages.count - shown.count
        return HStack(spacing: BP.px(4)) {
            ForEach(Array(shown.enumerated()), id: \.offset) { pair in
                cell(pair.element)
            }
            if extra > 0 {
                Text(verbatim: "+\(extra)")
                    .font(BP.sans(10, .semibold)).tracking(0.4).foregroundStyle(BP.inkSubtle).lineLimit(1)
            }
        }
        .fixedSize()
    }

    @ViewBuilder private func cell(_ lang: String) -> some View {
        if lang == "Multi" {
            Text(verbatim: "M")
                .font(BP.sans(9, .heavy)).tracking(1.4).foregroundStyle(BP.accent).lineLimit(1)
                .padding(.horizontal, BP.px(6))
                .frame(height: h + BP.px(2))
                .background(RoundedRectangle(cornerRadius: BP.px(3)).fill(BP.accent.opacity(0.15)))
                .overlay(RoundedRectangle(cornerRadius: BP.px(3)).stroke(BP.accent.opacity(0.35), lineWidth: 1))
        } else if let art = FlagArt.image(for: lang) {
            Image(uiImage: art).resizable().scaledToFill()
                .frame(width: h * 1.5, height: h)
                .clipShape(RoundedRectangle(cornerRadius: BP.px(2)))
                .overlay(RoundedRectangle(cornerRadius: BP.px(2)).stroke(Color.white.opacity(0.06), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.4), radius: 1, y: 1)
                .accessibilityLabel(Text(verbatim: lang))
        } else if let flag = FlagArt.emoji(for: lang) {
            Text(verbatim: flag)
                .font(.system(size: h * 1.3)).lineLimit(1).fixedSize()
                .frame(width: h * 1.5, height: h)
                .accessibilityLabel(Text(verbatim: lang))
        } else {
            Text(verbatim: String(lang.prefix(2)).uppercased())
                .font(BP.sans(9, .bold)).tracking(1.2).foregroundStyle(BP.inkSubtle).lineLimit(1)
                .padding(.horizontal, BP.px(4))
                .frame(height: h + BP.px(2))
                .background(RoundedRectangle(cornerRadius: BP.px(3)).fill(BP.canvas.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: BP.px(3)).stroke(BP.edge, lineWidth: 1))
        }
    }
}
