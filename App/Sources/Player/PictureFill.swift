import Foundation

/// (player parity pass 2) The picture settings the desktop player syncs, applied to the TV's
/// players the way views/player.tsx applies them to every stream it opens:
/// - use-video-fill.ts: settings.cropMode (Fit, Fill, Stretch, Zoom, 16:9, 4:3, 21:9, 1.85:1,
///   2.39:1) as mpv's panscan / video-aspect-override / video-zoom / keepaspect, and on the html5
///   bridge as object-fit (cover for Fill, fill for Stretch; aspect and zoom do nothing there).
/// - use-live-picture-eq.ts: settings.mpvTweaks' PICTURE_KEYS (brightness, contrast, saturation,
///   gamma, sharpen) as mpv properties; html5's setVideoEq is a no-op.
/// Big Picture has no control for either, so the TV only reads them (no settings rows).
enum PictureFill {
    struct Mode: Equatable {
        let id: String
        let panscan: Double
        let aspect: String
        let stretch: Bool
    }

    /// use-video-fill.ts MODES, in upstream's order ("original" is labelled 2.39:1 there).
    static let modes: [Mode] = [
        Mode(id: "fit", panscan: 0, aspect: "-1", stretch: false),
        Mode(id: "fill", panscan: 1, aspect: "-1", stretch: false),
        Mode(id: "stretch", panscan: 0, aspect: "-1", stretch: true),
        Mode(id: "zoom", panscan: 0, aspect: "-1", stretch: false),
        Mode(id: "16:9", panscan: 0, aspect: "16:9", stretch: false),
        Mode(id: "4:3", panscan: 0, aspect: "4:3", stretch: false),
        Mode(id: "21:9", panscan: 0, aspect: "21:9", stretch: false),
        Mode(id: "1.85:1", panscan: 0, aspect: "1.85:1", stretch: false),
        Mode(id: "original", panscan: 0, aspect: "2.39:1", stretch: false),
    ]

    /// modeIndex: an unknown or missing id is Fit.
    static func mode(_ id: String?) -> Mode {
        let found: Mode? = modes.first { $0.id == id }
        return found ?? modes[0]
    }

    /// dials.tsx PICTURE_KEYS.
    static let pictureKeys: [String] = ["brightness", "contrast", "saturation", "gamma", "sharpen"]

    /// use-live-picture-eq.ts: parseFloat of each key's text, 0 when it is unset, empty or not a
    /// number. Only the keys that are not 0 come back: 0 is mpv's own starting value, so a player
    /// that sets nothing matches a desktop with no look chosen.
    static func pictureEq(_ tweaks: [String: String]?) -> [(key: String, value: String)] {
        guard let tweaks else { return [] }
        var out: [(key: String, value: String)] = []
        for key in pictureKeys {
            guard let raw = tweaks[key], let value = parseFloat(raw), value != 0 else { continue }
            // A whole number goes as one ("5", not "5.0"): older mpv reads these dials as integers.
            let whole: Bool = value == value.rounded() && abs(value) < 1_000_000
            let text: String = whole ? String(Int(value)) : String(value)
            out.append((key: key, value: text))
        }
        return out
    }

    /// JavaScript parseFloat: the number at the start of the text ("12", " -3.5", "7abc" → 7).
    static func parseFloat(_ raw: String) -> Double? {
        let scanner = Scanner(string: raw)
        scanner.charactersToBeSkipped = .whitespacesAndNewlines
        guard let value = scanner.scanDouble(), value.isFinite else { return nil }
        return value
    }
}
