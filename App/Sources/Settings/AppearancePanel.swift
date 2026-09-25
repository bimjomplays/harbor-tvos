import SwiftUI

/// Settings → Appearance (views/settings/theme-panel.tsx): the Theme tab's preset tiles
/// (color-theme-body.tsx, grouped Built-in / Featured as custom-themes-section.tsx lists them)
/// and the Typography tab's font pairs (font-grid.tsx). Picking applies instantly and syncs as
/// the profile's `theme` section. Custom CSS/JS themes, uploaded fonts and wallpapers are
/// desktop-only.
struct AppearancePanel: View {
    @ObservedObject private var theme = ThemeStore.shared
    /// The tree rebuilds after a pick (ThemeStore.revision); the ring goes back to the tile.
    private static var refocus: String?
    @FocusState private var focus: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: BP.px(10)), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            if let s = theme.state {
                BPNote(text: "Pick a look. Every color and surface updates instantly.")
                ForEach(["Built-in", "Featured"], id: \.self) { group in
                    let presets = s.presets.filter { $0.category == group }
                    if !presets.isEmpty {
                        Text(T(group).uppercased()).font(BP.sans(11, .bold)).tracking(1.5).foregroundStyle(BP.inkSubtle)
                        LazyVGrid(columns: columns, spacing: BP.px(10)) {
                            ForEach(presets) { p in tile(p, active: s.active == p.id) }
                        }
                    }
                }
                Text("Typography").font(BP.sans(16, .bold)).foregroundStyle(BP.ink).padding(.top, BP.px(8))
                // theme-panel.tsx TypographyTab copy, minus the font upload tvOS cannot offer.
                BPNote(text: "Pick a display and body pairing.")
                // applyTheme: a preset with its own pairing (Stremio, Crunchy, Noir, MinUI) wins over this pick.
                if s.presetOwnsFont, let name = s.presets.first(where: { $0.id == s.active })?.name {
                    BPNote(text: "\(name) uses its own pairing while it is the theme.")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BP.px(10)), count: 3), spacing: BP.px(10)) {
                    ForEach(s.fontPairs) { f in fontTile(f, active: f.id == s.pickedFontPair) }
                }
            } else {
                ProgressView().tint(BP.inkMuted)
            }
        }
        .focusSection()
        .task {
            if theme.state == nil { await theme.load() }
            if let id = Self.refocus {
                Self.refocus = nil
                try? await Task.sleep(for: .milliseconds(150))
                focus = id
            }
        }
    }

    /// color-theme-body.tsx tile: the preset's own colours, a swatch dot that carries the check.
    private func tile(_ p: ThemeStore.Preset, active: Bool) -> some View {
        let base = ThemeStore.color(p.swatch.first ?? [0, 0, 0, 1])
        let top = ThemeStore.color(p.swatch.count > 1 ? p.swatch[1] : [0, 0, 0, 1])
        let ink = ThemeStore.color(p.swatch.count > 2 ? p.swatch[2] : [1, 1, 1, 1])
        return Button {
            Self.refocus = "theme:\(p.id)"
            Task { await theme.select(p.id) }
        } label: {
            ZStack(alignment: .bottomLeading) {
                base
                VStack(spacing: 0) {
                    LinearGradient(colors: [top, base], startPoint: .top, endPoint: .bottom).frame(height: BP.px(120) * 0.4)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(BP.sans(15, .semibold)).foregroundStyle(ink)
                    Text(p.blurb).font(BP.sans(12)).foregroundStyle(ink.opacity(0.7)).lineLimit(2)
                }
                .padding(BP.px(12))
                Circle().fill(ink)
                    .frame(width: BP.px(24), height: BP.px(24))
                    .overlay { if active { Image(systemName: "checkmark").font(.system(size: BP.px(12), weight: .heavy)).foregroundStyle(base).accessibilityHidden(true) } }
                    .padding(BP.px(10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .frame(height: BP.px(120))
            .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).strokeBorder(active ? BP.ink : BP.edge, lineWidth: active ? 2 : 1))
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM))
        .focused($focus, equals: "theme:\(p.id)")
        // The ring and tick on the theme in use read as selected (", current" was English only).
        .accessibilityLabel(Text(verbatim: p.name))
        .bpSelected(active)
    }

    /// font-grid.tsx tile: the name, "Harbor" in the display face, the pangram in the body face.
    private func fontTile(_ f: ThemeStore.FontPair, active: Bool) -> some View {
        let display = BPThemeTokens.DisplayFace(rawValue: f.faces.display) ?? .system
        let sans = BPThemeTokens.SansFace(rawValue: f.faces.sans) ?? .system
        return Button {
            Self.refocus = "font:\(f.id)"
            Task { await theme.setFontPair(f.id) }
        } label: {
            VStack(alignment: .leading, spacing: BP.px(8)) {
                HStack {
                    Text(f.name).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                    Spacer()
                    if active { Image(systemName: "checkmark").font(.system(size: BP.px(13), weight: .bold)).foregroundStyle(BP.accent).accessibilityHidden(true) }
                }
                Text("Harbor").font(BP.display(24, .medium, face: display)).foregroundStyle(BP.ink)
                Text("The quick brown fox jumps over the lazy dog").font(BP.sans(12, .regular, face: sans)).foregroundStyle(BP.inkMuted).lineLimit(1)
                Text(f.blurb).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).lineLimit(1)
            }
            .padding(BP.px(14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).strokeBorder(active ? BP.ink : BP.edge, lineWidth: active ? 2 : 1))
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM))
        .focused($focus, equals: "font:\(f.id)")
        // The name and blurb, not the "Harbor" and pangram samples drawn in the faces.
        .accessibilityLabel(Text(verbatim: "\(f.name), \(f.blurb)"))
        .bpSelected(active)
    }
}
