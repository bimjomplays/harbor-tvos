import SwiftUI
import UIKit

/// bp-spotlight.tsx: a pure display surface mirroring the focused (or hero-cycled) title.
struct SpotlightView: View {
    let meta: Meta?
    /// Height of the hero box the copy is bottom-anchored in (RoomView passes the Home value).
    var boxHeight: CGFloat = BP.px(260 - 56) + BP.barHeight
    /// bp-hero-pips: the hero cycle's position, shown while it runs.
    var pips: HeroPips? = nil
    /// bp-ambient `drift`: the slow Ken Burns on the title art (off on the anime page, `still`).
    var drift = true
    /// MetaAwardsCorner: BpSpotlight mounts it on Home, Movies, Shows and service pages only.
    var awardsCorner = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            VStack(alignment: .leading, spacing: BP.px(10)) {
                Spacer(minLength: 0)
                // bp-spotlight data-bp-hero-mark: the provider badge's mark above the title
                // (clamp(19px,3.2vh,29px) tall at 85 %, 18 px above the logo or name).
                if let mark = meta?.providerBadge?.logo, !mark.isEmpty {
                    BandMark(url: mark, height: BP.px(20.5), maxWidth: BP.px(200))
                        .opacity(0.85)
                        .padding(.bottom, BP.px(8))
                }
                if let logo = meta?.logo, !logo.isEmpty {
                    RemoteImage(url: logo, contentMode: .fit)
                        .frame(maxWidth: BP.px(300), maxHeight: BP.px(90), alignment: .leading)
                } else {
                    Text(meta?.name ?? " ")
                        .font(BP.display(36)).foregroundStyle(BP.ink)
                        .lineLimit(2).shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                }
                HStack(spacing: BP.px(10)) {
                    // bp-spotlight: provider chips from use-bp-card-badges, then TMDB's own score, then facts.
                    ScoreChipsView(meta: meta, surface: "card", limit: 3)
                    if let s = meta?.tmdbScore, s > 0 { scoreChip("TMDB", String(format: "%.1f", s)) }
                    if let f = meta?.facts, !f.isEmpty {
                        Text(f).font(BP.sans(14, .medium)).foregroundStyle(BP.inkMuted)
                    }
                }
                Text(meta?.description ?? "")
                    .font(BP.sans(16)).foregroundStyle(BP.inkMuted).lineSpacing(5)
                    .lineLimit(2).frame(maxWidth: BP.px(520), alignment: .leading)
                if let pips {
                    BPHeroPipsView(pips: pips).padding(.top, BP.px(4)).transition(.opacity)
                }
            }
            .padding(.leading, BP.gutter)
            .padding(.bottom, BP.px(27))
            .frame(height: boxHeight, alignment: .bottomLeading)
            .animation(.easeOut(duration: 0.26), value: meta?.id)
            // bp-spotlight MetaAwardsCorner: bottom-end of the hero box (bottom-10 end-10),
            // pushed down by translate-y clamp(26px,4vh,58px).
            if awardsCorner, let meta {
                HeroAwardsCornerView(meta: meta)
                    .padding(.trailing, BP.px(40))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .frame(height: boxHeight - BP.px(40) + BP.px(26), alignment: .bottomTrailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }

    private var backdrop: some View {
        ZStack {
            BP.void_
            GeometryReader { g in
                BPTitleArt(meta: meta, drift: drift)
                    .frame(width: g.size.width * 0.76, height: g.size.height)
                    .clipped()
                    // bp-ambient-layers ENVELOPE: one feather for every art layer.
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                                 .init(color: .black.opacity(0.5), location: 0.17),
                                                 .init(color: .black, location: 0.38)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            LinearGradient(colors: [BP.void_.opacity(0.82), BP.void_.opacity(0.52), BP.void_.opacity(0.16), .clear],
                           startPoint: .leading, endPoint: .init(x: 0.7, y: 0.5))
            LinearGradient(colors: [.clear, BP.void_.opacity(0.3), BP.void_.opacity(0.88), BP.void_], startPoint: .init(x: 0.5, y: 0.35), endPoint: .bottom)
        }
    }

    private func scoreChip(_ label: String, _ value: String) -> some View {
        HStack(spacing: BP.px(4)) {
            Text(label).font(BP.sans(9.8, .bold)).foregroundStyle(BP.canvas)
                .padding(.horizontal, BP.px(5)).padding(.vertical, BP.px(2))
                .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.ink))
            Text(value).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
        }
    }
}

/// bp-ambient.tsx title art. The focused title's art commits only once the focus has settled
/// (BP_META_SETTLE_MS, 200 ms) and its bitmap is decoded, so a fast scroll never thrashes and a
/// swap never fades through an empty plate. Candidates: backdrop, then poster; pass one takes
/// landscape art only (a portrait or anything under 1.2:1 is skipped), pass two any aspect.
/// Layers cross-fade by the outgoing one fading out above the incoming (480 ms), the stack is
/// pruned to one after 1.2 s, and each layer drifts (bp-kenburns) unless Reduce Motion is on.
/// A focused title with no art at all leaves the last art up, as upstream does.
struct BPTitleArt: View {
    let meta: Meta?
    var drift = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var layers: [Layer] = []
    @State private var seq = 0

    struct Layer: Identifiable { var id: Int; var url: String; var image: UIImage }
    private struct Candidate { var url: String; var portrait: Bool }

    private var candidates: [Candidate] {
        guard let m = meta else { return [] }
        var out: [Candidate] = []
        if let b = m.background, !b.isEmpty { out.append(Candidate(url: b, portrait: false)) }
        if let p = m.poster, !p.isEmpty { out.append(Candidate(url: p, portrait: true)) }
        return out
    }

    private var key: String { candidates.map { $0.url }.joined(separator: "|") }

    var body: some View {
        ZStack {
            ForEach(Array(layers.enumerated()), id: \.element.id) { i, layer in
                let top = i == layers.count - 1
                KenBurnsImage(image: layer.image, drift: drift && !reduceMotion)
                    .opacity(top ? 1 : 0)
                    .zIndex(top ? 0 : 1)
                    .transition(.identity)
            }
        }
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.48), value: layers.last?.id)
        .task(id: key) { await commit() }
    }

    private func commit() async {
        let list = candidates
        guard !list.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        for wide in [true, false] {
            for c in list where !(wide && c.portrait) {
                guard let u = URL(string: c.url) else { continue }
                let img = await ImageLoader.shared.image(for: u)
                guard !Task.isCancelled else { return }
                guard let img else { continue }
                if wide, img.size.height > 0, img.size.width / img.size.height < 1.2 { continue }
                push(img, url: c.url)
                return
            }
        }
    }

    private func push(_ image: UIImage, url: String) {
        if layers.last?.url == url { return }
        seq += 1
        let id = seq
        layers = Array(layers.suffix(1)) + [Layer(id: id, url: url, image: image)]
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            if layers.last?.id == id, layers.count > 1 { layers = Array(layers.suffix(1)) }
        }
    }
}

/// bp-tokens.ts @keyframes bp-kenburns, 14 s cubic-bezier(0.22,1,0.36,1) after 900 ms, forwards:
/// scale up to 1.075 while easing 1.1 % / 0.7 % toward the top leading corner by 72 %, then
/// settle back to rest.
struct KenBurnsImage: View {
    let image: UIImage
    var drift = true
    @State private var phase = 0

    var body: some View {
        GeometryReader { g in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: g.size.width, height: g.size.height)
                .offset(x: phase == 1 ? -0.011 * g.size.width : 0, y: phase == 1 ? -0.007 * g.size.height : 0)
                .scaleEffect(phase == 1 ? 1.075 : 1)
        }
        .task {
            guard drift else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 10.08)) { phase = 1 }
            try? await Task.sleep(for: .milliseconds(10080))
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 3.92)) { phase = 2 }
        }
    }
}

/// components/meta-awards-corner.tsx (the "full" tier) under the hero: an anime title's top
/// bundled win ("{award} Winner", "{year} Anime of the Year", "+N more awards") or a classic
/// title's live + bundled awards ("{Headline} Winner|Nominee" over two "{n} Oscars" lines); a
/// laurel wraps the mark only for a win. Computed in the engine (`cards.heroAwards`).
struct HeroAwardsCornerView: View {
    let meta: Meta
    @State private var corner: Corner?
    struct Corner: Decodable { var kind: String; var headline: String; var lines: [String]; var won: Bool; var mark: String; var tint: String }

    var body: some View {
        HStack(spacing: BP.px(12)) {
            if let c = corner {
                VStack(alignment: .trailing, spacing: BP.px(2)) {
                    Text(c.headline).font(BP.sans(10.5, .bold)).textCase(.uppercase).tracking(BP.px(1.9))
                        .foregroundStyle(BP.ink.opacity(0.55)).lineLimit(1)
                    ForEach(Array(c.lines.enumerated()), id: \.offset) { i, line in
                        if c.kind == "anime" && i > 0 {
                            Text(line).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                        } else {
                            Text(line).font(BP.sans(13, c.kind == "anime" ? .semibold : .medium)).foregroundStyle(BP.ink.opacity(0.85)).lineLimit(1)
                        }
                    }
                }
                mark(c)
            }
        }
        .frame(maxWidth: BP.px(500), alignment: .trailing)
        .animation(.easeOut(duration: 0.26), value: corner?.headline)
        .allowsHitTesting(false)
        .task(id: meta.id) {
            corner = nil
            // Focus glides across a rail; the Wikidata read waits for it to settle.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await AwardsCatalog.installIfNeeded()
            let found: Corner? = try? await HarborEngine.shared.call("cards.heroAwards", [meta])
            guard !Task.isCancelled else { return }
            corner = found
        }
    }

    @ViewBuilder private func mark(_ c: Corner) -> some View {
        let tint = c.kind == "anime" ? BP.accent : (Color(css: c.tint) ?? BP.accent)
        if c.won {
            HStack(spacing: BP.px(2)) {
                Image(systemName: "laurel.leading").font(.system(size: BP.px(30), weight: .regular))
                Text(c.mark).font(BP.sans(12, .bold)).lineLimit(1)
                Image(systemName: "laurel.trailing").font(.system(size: BP.px(30), weight: .regular))
            }
            .foregroundStyle(tint)
        } else {
            Text(c.mark).font(BP.sans(14, .bold)).foregroundStyle(tint).lineLimit(1).opacity(0.85)
        }
    }
}
