import SwiftUI

/// Upstream's genre palette is authored in OKLCH; SwiftUI needs sRGB.
extension Color {
    /// Parses "oklch(L C H)" or "oklch(L C H / A)" (L 0…1, C 0…0.4, H degrees).
    init?(oklch text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("oklch("), t.hasSuffix(")") else { return nil }
        let inner = t.dropFirst(6).dropLast()
        let parts = inner.replacingOccurrences(of: "/", with: " ").split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        let (l, c, hDeg) = (parts[0], parts[1], parts[2])
        let alpha = parts.count > 3 ? parts[3] : 1
        let h = hDeg * .pi / 180
        let a = c * cos(h), b = c * sin(h)
        // OKLab → LMS (cube roots) → linear sRGB (Björn Ottosson's matrices).
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        var r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        var g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        var bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
        func gamma(_ v: Double) -> Double {
            let x = min(max(v, 0), 1)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        r = gamma(r); g = gamma(g); bl = gamma(bl)
        self.init(.sRGB, red: r, green: g, blue: bl, opacity: alpha)
    }
}
