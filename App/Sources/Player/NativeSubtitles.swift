import SwiftUI

/// One parsed cue (lib/subtitles/parser.ts SubCue), as `subtitles.cues` returns it.
struct SubtitleCue: Decodable, Equatable {
    var start: Double
    var end: Double
    var text: String

    /// parser.ts findActiveCue: a binary search over cues sorted by start.
    static func active(in cues: [SubtitleCue], at time: Double) -> SubtitleCue? {
        guard !cues.isEmpty else { return nil }
        var lo = 0
        var hi = cues.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let c = cues[mid]
            if time < c.start { hi = mid - 1 }
            else if time >= c.end { lo = mid + 1 }
            else { return c }
        }
        return nil
    }
}

/// What the AVPlayer engine's overlay draws (html5 bridge snap.subText / subStartSec /
/// secondarySubText), published by NativePlayerController's cue ticker.
@MainActor
final class NativeSubtitleState: ObservableObject {
    @Published var text = ""
    @Published var startSec: Double = 0
    @Published var secondaryText = ""
}

/// components/player/subtitle-overlay.tsx SubtitleOverlay: the html5 engine's own subtitle
/// renderer, drawn over the AVPlayer picture with the viewer's Look settings. Sizes follow
/// upstream's 1080-high reference box (`responsive = boxH / 1080`); a kid profile gets the
/// bigger, bold, shadowed type upstream forces for kids.
struct NativeSubtitleOverlay: View {
    @ObservedObject var state: NativeSubtitleState
    @ObservedObject private var settings = SettingsBridge.shared

    var body: some View {
        GeometryReader { g in
            let look = Self.look(settings.slice, kid: ProfilesStore.shared.active?.kid != nil, box: g.size)
            let marginY: CGFloat = look.marginY
            let opacity: Double = look.opacity
            // settings subSecondaryScale (0.85) / subSecondaryPlacement ("top") defaults.
            let secondLook = look.scaled(Self.clamp(0.85, 0.4, 1.4))
            ZStack {
                if !state.secondaryText.isEmpty {
                    VStack(spacing: 0) {
                        block(state.secondaryText, secondLook)
                            .frame(maxWidth: .infinity, alignment: look.frameAlignment)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, g.size.height * marginY / 100)
                    .padding(.horizontal, g.size.width * 0.06)
                    .opacity(opacity)
                }
                if !state.text.isEmpty {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        block(state.text, look)
                            .frame(maxWidth: .infinity, alignment: look.frameAlignment)
                            .id(state.startSec)
                    }
                    .padding(.bottom, g.size.height * marginY / 100)
                    .padding(.horizontal, g.size.width * 0.06)
                    .opacity(opacity)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    struct Look {
        var fontSize: CGFloat
        var color: Color
        var align: String
        var bold: Bool
        var style: String
        var border: Color
        var borderSize: CGFloat
        var tracking: CGFloat
        var box: Color
        var maxWidth: CGFloat
        /// Distance from the bottom (the second line: from the top), in percent of the box.
        var marginY: CGFloat
        var opacity: Double

        var textAlignment: TextAlignment { align == "left" ? .leading : align == "right" ? .trailing : .center }
        var frameAlignment: Alignment { align == "left" ? .leading : align == "right" ? .trailing : .center }

        func scaled(_ k: CGFloat) -> Look {
            var l = self
            l.fontSize = (fontSize * k).rounded()
            return l
        }

        /// buildOutline(): every whole-pixel offset inside the border radius, drawn unblurred.
        var outlineOffsets: [CGSize] {
            var out: [CGSize] = []
            for dx in stride(from: -borderSize, through: borderSize, by: 1) {
                for dy in stride(from: -borderSize, through: borderSize, by: 1) {
                    let r = (dx * dx + dy * dy).squareRoot()
                    if r > borderSize + 0.1 || r < 0.1 { continue }
                    out.append(CGSize(width: dx, height: dy))
                }
            }
            return out
        }
    }

    private func text(_ s: String, _ look: Look, color: Color) -> some View {
        Text(verbatim: s)
            .font(.custom(look.bold ? "Switzer-Bold" : "Switzer-Regular", fixedSize: look.fontSize))
            .tracking(look.tracking)
            .lineSpacing(look.fontSize * 0.08)
            .multilineTextAlignment(look.textAlignment)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One subtitle box: text-shadow for "shadow", a drawn outline for "outline", a rounded
    /// backing for "box" (padding 0.18em × 0.5em, radius 0.25em).
    @ViewBuilder private func block(_ s: String, _ look: Look) -> some View {
        let isBox = look.style == "box"
        ZStack {
            if look.style == "outline" {
                ForEach(Array(look.outlineOffsets.enumerated()), id: \.offset) { _, o in
                    text(s, look, color: look.border).offset(o)
                }
            }
            if look.style == "shadow" {
                // "0 1px 2px rgba(0,0,0,.95), 0 2px 6px rgba(0,0,0,.85), 0 0 18px rgba(0,0,0,.55)"
                text(s, look, color: look.color)
                    .shadow(color: .black.opacity(0.95), radius: 1, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 2)
                    .shadow(color: .black.opacity(0.55), radius: 9, x: 0, y: 0)
            } else {
                text(s, look, color: look.color)
            }
        }
        .padding(.vertical, isBox ? (look.fontSize * 0.18).rounded() : 0)
        .padding(.horizontal, isBox ? (look.fontSize * 0.5).rounded() : 0)
        .background {
            if isBox {
                RoundedRectangle(cornerRadius: (look.fontSize * 0.25).rounded(), style: .continuous).fill(look.box)
            }
        }
        .frame(maxWidth: look.maxWidth, alignment: look.frameAlignment)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// SubtitleOverlay's derived values for a `box` the size of the picture.
    private static func look(_ s: SettingsBridge.Slice, kid: Bool, box: CGSize) -> Look {
        let responsive: CGFloat = box.height > 0 ? max(0.3, min(2.5, box.height / 1080)) : 1
        let size: CGFloat = clamp(s.subFontSize ?? 32, 16, 120)
        let baseFont: CGFloat = kid ? max(54, size) : size
        let fontSize: CGFloat = (baseFont * responsive).rounded()
        // Math.max(0.5, Math.round((clamp(subBorderSize, 1, 6) || 2) * responsive * 2) / 2)
        let border: CGFloat = max(0.5, (clamp(s.subBorderSize ?? 0, 1, 6) * responsive * 2).rounded() / 2)
        let spacing: CGFloat = CGFloat(-0.005 + (s.subLineSpacing ?? 0) * 0.06)
        let boxOpacity: Double = Double(clamp(s.subBoxOpacity ?? 0.6, 0, 1))
        return Look(fontSize: fontSize,
                    color: color(s.subFontColor, .white),
                    align: s.subAlignX ?? "center",
                    bold: kid || (s.subBold ?? false),
                    style: kid ? "shadow" : (s.subStyle ?? "shadow"),
                    border: color(s.subBorderColor, .black),
                    borderSize: border,
                    tracking: fontSize * spacing,
                    box: color(s.subBoxColor, .black).opacity(boxOpacity),
                    maxWidth: box.width * 0.8,
                    marginY: clamp(s.subMarginY ?? 12, 0, 100),
                    opacity: Double(clamp(s.subOpacity ?? 1, 0.1, 1)))
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> CGFloat {
        guard v.isFinite else { return CGFloat(lo) }
        return CGFloat(min(hi, max(lo, v)))
    }

    private static func color(_ hex: String?, _ fallback: Color) -> Color {
        var h = (hex ?? "").trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return fallback }
        return Color(hex: v)
    }
}
