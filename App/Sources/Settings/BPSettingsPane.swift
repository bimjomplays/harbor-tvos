import SwiftUI

/// bp-settings-pane.tsx BpSettingsPane: the right-hand live preview. It never takes focus
/// (aria-hidden, pointer-events-none upstream); it redraws as the column moves and as values commit.
struct BPSettingsPane: View {
    let cat: String
    let title: String
    let pane: BPSettingsModel.Pane?

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            Text(title).font(BP.display(21)).foregroundStyle(BP.ink).lineLimit(1)
            if let pane {
                switch cat {
                case "picture": picture(pane)
                case "subtitles": subtitles(pane)
                case "home": home(pane.homeMode)
                case "services": services(pane)
                case "language":
                    if let l = pane.language { language(l) }
                case "playback": BPPaneLines(rows: pane.playback)
                case "setup": BPPaneLines(rows: pane.setup)
                case "interface": BPPaneLines(rows: pane.interface + version)
                default: EmptyView()
                }
            }
        }
        .frame(maxWidth: BP.px(478), alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(BP.easeFast, value: cat)
    }

    /// `useAppVersion`: the build this TV runs.
    private var version: [[String]] {
        guard let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return [] }
        // bp-settings-pane.tsx: t("Version"); the line read English in every language.
        return [[T("Version"), v]]
    }

    /// Screen(): a 16:9 box on the void, edge ring, md radius.
    private func screen<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ZStack { content() }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(BP.void_)
            .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).strokeBorder(BP.edge, lineWidth: 1))
    }

    /// PicturePreview: the still at 45%, a dashed frame inset by the edge margin, the label pill.
    private func picture(_ p: BPSettingsModel.Pane) -> some View {
        screen {
            GeometryReader { g in
                ZStack {
                    RemoteImage(url: p.still).frame(width: g.size.width, height: g.size.height).clipped().opacity(0.45)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(BP.focusStroke, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                        .padding(.horizontal, g.size.width * CGFloat(p.overscan))
                        .padding(.vertical, g.size.height * CGFloat(p.overscan))
                    VStack {
                        Spacer()
                        Text(p.overscanLabel).font(BP.sans(12, .bold)).foregroundStyle(BP.ink)
                            .padding(.horizontal, BP.px(12)).padding(.vertical, BP.px(4))
                            .background(Capsule().fill(BP.void_.opacity(0.8)))
                            .padding(.bottom, g.size.height * 0.06)
                    }
                }
            }
        }
    }

    /// SubtitlePreview: the sample line at the viewer's size (×0.55), then the language flags,
    /// the first marked "1".
    private func subtitles(_ p: BPSettingsModel.Pane) -> some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            screen {
                GeometryReader { g in
                    ZStack(alignment: .bottom) {
                        RemoteImage(url: p.still).frame(width: g.size.width, height: g.size.height).clipped().opacity(0.7)
                        LinearGradient(stops: [.init(color: BP.void_, location: 0.04), .init(color: BP.void_.opacity(0), location: 0.46)],
                                       startPoint: .bottom, endPoint: .top)
                        Text(p.subtitle.text)
                            .font(BP.sans(CGFloat(p.subtitle.px), .semibold))
                            .foregroundStyle(BP.ink)
                            .multilineTextAlignment(.center)
                            .shadow(color: .black.opacity(0.9), radius: 3, y: 2)
                            .padding(.horizontal, g.size.width * 0.08)
                            .padding(.bottom, g.size.height * 0.09)
                    }
                }
            }
            BPFlagRow(flags: p.subtitle.flags, size: BP.px(27))
        }
    }

    /// HomePreview: the Harbor-vs-Classic wireframe.
    private func home(_ mode: String) -> some View {
        screen {
            GeometryReader { g in
                VStack(alignment: .leading, spacing: 6) {
                    if mode == "harbor" {
                        RoundedRectangle(cornerRadius: 4).fill(BP.on).frame(maxHeight: .infinity)
                        BPPaneBars(count: 7, height: BP.px(22))
                    } else {
                        Capsule().fill(BP.panel2).frame(width: g.size.width * 0.9 * 0.30, height: 6)
                        BPPaneBars(count: 5, height: BP.px(34))
                        Capsule().fill(BP.panel2).frame(width: g.size.width * 0.9 * 0.22, height: 6)
                        BPPaneBars(count: 7, height: BP.px(22))
                        Spacer(minLength: 0)
                    }
                }
                .padding(g.size.width * 0.05)
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            }
        }
    }

    /// ServicesPreview: the services left on (up to 18), or the hint when none are.
    @ViewBuilder private func services(_ p: BPSettingsModel.Pane) -> some View {
        if p.services.isEmpty {
            Text(p.servicesEmpty).font(BP.sans(13, .medium)).foregroundStyle(BP.inkSubtle)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: BP.px(96)), spacing: BP.px(8))], alignment: .leading, spacing: BP.px(8)) {
                ForEach(p.services) { s in
                    // ServiceLogo's fallback: the name in the brand tint.
                    Text(s.label).font(BP.sans(12, .bold)).foregroundStyle(Color(css: s.tint) ?? BP.ink).lineLimit(1)
                        .padding(.horizontal, BP.px(10))
                        .frame(maxWidth: .infinity, minHeight: BP.px(38))
                        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel))
                }
            }
        }
    }

    /// The greeting in the chosen language, large, and its native name under it.
    private func language(_ l: BPSettingsModel.Pane.Language) -> some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            // RTL languages set the direction; font-arabic is not bundled, so they use the system face.
            Text(l.greeting)
                .font(l.rtl ? Font.system(size: BP.px(40), weight: .semibold) : BP.display(40))
                .foregroundStyle(BP.ink)
                .environment(\.layoutDirection, l.rtl ? .rightToLeft : .leftToRight)
            Text(l.nativeLabel).font(BP.sans(13, .medium)).foregroundStyle(BP.inkSubtle)
        }
    }
}

/// bp-settings-pane.tsx Lines: key on the left in subtle, value on the right in bold ink.
struct BPPaneLines: View {
    let rows: [[String]]
    var body: some View {
        VStack(spacing: BP.px(9)) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: BP.px(14)) {
                    Text(row.first ?? "").font(BP.sans(12, .medium)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                    Spacer(minLength: BP.px(10))
                    Text(row.count > 1 ? row[1] : "").font(BP.sans(13, .bold)).foregroundStyle(BP.ink).lineLimit(1)
                }
            }
        }
    }
}

/// Bars(): the row of poster placeholders in the home wireframe.
struct BPPaneBars: View {
    let count: Int
    let height: CGFloat
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 2).fill(BP.panel2).frame(maxWidth: .infinity).frame(height: height)
            }
        }
    }
}

/// The subtitle-language flags (components/flag.tsx) as round emoji marks; the first carries "1".
struct BPFlagRow: View {
    let flags: [String]
    let size: CGFloat
    var limit = 8
    var body: some View {
        if !flags.isEmpty {
            HStack(spacing: BP.px(7)) {
                ForEach(Array(flags.prefix(limit).enumerated()), id: \.offset) { i, flag in
                    ZStack {
                        Circle().fill(BP.panel2)
                        Text(flag).font(.system(size: size * 0.95))
                        if i == 0 {
                            Circle().fill(BP.void_.opacity(0.62))
                            Text("1").font(BP.sans(10, .bold)).foregroundStyle(BP.ink)
                        }
                    }
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(BP.edge, lineWidth: 1))
                }
            }
        }
    }
}
