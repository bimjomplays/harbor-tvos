import SwiftUI
import UIKit
import CoreImage

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
    /// Which part to draw. bp-home stacks the hero copy (`data-bp-home-hero`, z-20) above the rail
    /// while the art stays behind it, so RoomView draws `.backdrop` under the rail and `.copy`
    /// over it; the other pages draw both in one place (`.all`).
    var layer: Layer = .all

    enum Layer { case all, backdrop, copy }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if layer != .copy { backdrop }
            if layer != .backdrop { copy }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }

    @ViewBuilder private var copy: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Spacer(minLength: 0)
            // bp-spotlight data-bp-hero-mark: the provider badge's mark above the title
            // (clamp(19px,3.2vh,29px) tall at 85 %, 18 px above the logo or name).
            if let mark = meta?.providerBadge?.logo, !mark.isEmpty {
                BandMark(url: mark, height: BP.px(20.5), maxWidth: BP.px(200))
                    .opacity(0.85)
                    .padding(.bottom, BP.px(8))
                    // bp-spotlight data-bp-hero-mark: the provider badge mark has alt="" upstream.
                    .accessibilityHidden(true)
            }
            if let logo = meta?.logo, !logo.isEmpty {
                RemoteImage(url: logo, contentMode: .fit, alignment: .leading)
                    // (device build 316) 90 px canvas let a tall logo (Toy Story 5) climb under the
                    // top bar and the focused tab's name pill.
                    // (device build 406) 72 still reached the focused tab's name pill when the logo
                    // sat over a two-line synopsis (Re:ZERO, Verity).
                    .frame(maxWidth: BP.px(300), maxHeight: BP.px(60), alignment: .leading)
                    // The title logo reads as the name it draws.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: meta?.name ?? ""))
            } else {
                // (device build 360) A long anime name ("Rich Girl Caretaker: I'm Secretly the
                // Caregiver of…") ran two full-width lines up under the top bar: long names set
                // smaller and shrink to fit.
                let name: String = meta?.name ?? " "
                Text(name)
                    .font(BP.display(name.count > 40 ? 28 : 36)).foregroundStyle(BP.ink)
                    .lineLimit(2).minimumScaleFactor(0.7)
                    .frame(maxWidth: BP.px(760), alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
            }
            HStack(spacing: 0) {
                // bp-spotlight: provider chips from use-bp-card-badges, then TMDB's own score, then facts.
                ScoreChipsView(meta: meta, surface: "card", limit: 3, trailingGap: BP.px(10))
                if let s = meta?.tmdbScore, s > 0 { scoreChip("TMDB", String(format: "%.1f", s)).padding(.trailing, BP.px(10)) }
                if let f = meta?.facts, !f.isEmpty {
                    Text(f).font(BP.sans(14, .medium)).foregroundStyle(BP.inkMuted)
                }
            }
            // (device build 316) An empty synopsis still took a line, leaving a gap between the
            // title's facts and the hero pips.
            if let d = meta?.description, !d.isEmpty {
                Text(d)
                    .font(BP.sans(16)).foregroundStyle(BP.inkMuted).lineSpacing(5)
                    // Legible where the scrim thins out over bright key art.
                    .shadow(color: Color.black.opacity(0.7), radius: 6, y: 1)
                    .lineLimit(2).frame(maxWidth: BP.px(520), alignment: .leading)
            }
            if let pips {
                BPHeroPipsView(pips: pips).padding(.top, BP.px(4)).transition(.opacity)
            }
        }
        .padding(.leading, BP.gutter)
        // (device build 349) With the row parked just under the copy, a two-line synopsis touched
        // the row's header (Anime: Holo Graffiti, Chiikawa); the copy sits a little higher.
        .padding(.bottom, BP.px(36))
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
            // (device build 345) The synopsis' line ends ran over bright key art (The Rookie's yellow
            // sun): a deeper side scrim under the copy's column, still clear by 3/4 across.
            LinearGradient(stops: [.init(color: BP.void_.opacity(0.9), location: 0), .init(color: BP.void_.opacity(0.72), location: 0.32),
                                   .init(color: BP.void_.opacity(0.5), location: 0.62), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .init(x: 0.75, y: 0.5))
                // bp-tokens.ts --bp-scrim-side: the side scrim runs from the start edge (260deg under rtl).
                .flipsForRightToLeftLayoutDirection(true)
            LinearGradient(colors: [.clear, BP.void_.opacity(0.3), BP.void_.opacity(0.88), BP.void_], startPoint: .init(x: 0.5, y: 0.35), endPoint: .bottom)
            // (device build 369) White key art (Shin Chan) left the top bar's bell, cog and clock
            // grey on near-white: a top scrim under the bar's own keeps them readable.
            LinearGradient(stops: [.init(color: BP.void_.opacity(0.6), location: 0), .init(color: BP.void_.opacity(0.25), location: 0.12),
                                   .init(color: .clear, location: 0.24)], startPoint: .top, endPoint: .bottom)
        }
        // bp-ambient-layers.tsx: the art stage is aria-hidden.
        .accessibilityHidden(true)
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
    /// bp-backdrop-commit.ts BP_META_SETTLE_MS: how long focus rests before the hero art follows.
    static let settle: Duration = .milliseconds(200)
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
        if let b = m.background, !b.isEmpty { out.append(Candidate(url: Self.heroSized(b), portrait: false)) }
        if let p = m.poster, !p.isEmpty { out.append(Candidate(url: Self.heroSized(p), portrait: true)) }
        return out
    }

    /// (device build 303) The hero art filled ~1460 pt of a 4K screen from whatever file the catalog
    /// named: a TMDB w780 backdrop, or an anime card's small fixed-tier poster (MAL ~225 px wide),
    /// drawn soft and blocky. Ask for TMDB's w1280 tier and the anime CDNs' biggest sibling file,
    /// as the poster tiles already do (PosterSizing).
    static func heroSized(_ url: String) -> String {
        PosterSizing.sizeImageUrl(PosterSizing.upgradeFixedTierArt(url), 1280)
    }

    private var key: String { candidates.map { $0.url }.joined(separator: "|") }

    var body: some View {
        ZStack {
            ForEach(Array(layers.enumerated()), id: \.element.id) { i, layer in
                let top = i == layers.count - 1
                KenBurnsImage(image: layer.image, drift: drift && !reduceMotion, fitWidth: Self.isAnime(meta))
                    .opacity(top ? 1 : 0)
                    .zIndex(top ? 0 : 1)
                    .transition(.identity)
            }
        }
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.48), value: layers.last?.id)
        .task(id: key) { await commit() }
    }

    /// Anime ids whose metas carry no real backdrop: Jikan sets `background` to the poster itself,
    /// Kitsu / AniList / AniDB often set none, so the hero was the poster, upscaled and blurred.
    private static let animeIdPrefixes: [String] = ["mal:", "kitsu:", "anilist:", "anidb:"]

    static func isAnime(_ m: Meta?) -> Bool {
        guard let id = m?.id else { return false }
        return animeIdPrefixes.contains(where: { id.hasPrefix($0) })
    }

    private static func wantsAnimeBackdrop(_ m: Meta) -> Bool {
        guard animeIdPrefixes.contains(where: { m.id.hasPrefix($0) }) else { return false }
        let bg = m.background ?? ""
        return bg.isEmpty || bg == m.poster
    }

    private func commit() async {
        var list = candidates
        guard !list.isEmpty else { return }
        try? await Task.sleep(for: Self.settle)
        guard !Task.isCancelled else { return }
        // engine/animeArt.ts: metahub's 16:9 background (what Movies / Shows show), else the AniList
        // banner, else the Kitsu cover; null when none, and then the poster path below runs as before.
        if let m = meta, Self.wantsAnimeBackdrop(m) {
            let found: String? = try? await HarborEngine.shared.call("animeArt.backdrop", [m.id, m.name, String?.none])
            guard !Task.isCancelled else { return }
            if let found, !found.isEmpty {
                list.insert(Candidate(url: Self.heroSized(found), portrait: false), at: 0)
            }
        }
        for wide in [true, false] {
            for c in list where !(wide && c.portrait) {
                guard let u = URL(string: c.url) else { continue }
                let img = await ImageLoader.shared.image(for: u)
                guard !Task.isCancelled else { return }
                guard let img else { continue }
                if wide, img.size.height > 0, img.size.width / img.size.height < 1.2 { continue }
                let shown: UIImage = await HeroBlur.shared.softenIfSmall(img, key: c.url)
                guard !Task.isCancelled else { return }
                push(shown, url: c.url)
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

/// The Manga and eBook heroes' backdrop (views/manga.tsx, views/ebook.tsx): the focused title's
/// cover, blurred and faded, behind the hero copy. (perf pass 2) It used to follow every focus
/// move at once, and `.blur(radius: 36)` on a full-width image is a live Gaussian redone every
/// frame of each cross-fade (two of them mid-swap). The art now follows focus only once it
/// settles (BPTitleArt.settle, as Home's hero does), an unchanged cover is never swapped, and
/// each cover is blurred once, off the main thread, from a small decode into a bitmap that is
/// only stretched on screen (HeroBlur, cached per URL).
struct BPBlurredHeroBackdrop: View {
    let url: String?
    @State private var shown: Shown?
    private struct Shown { var url: String; var image: UIImage }

    var body: some View {
        ZStack {
            if let s = shown {
                Image(uiImage: s.image).resizable().scaledToFill()
                    .scaleEffect(1.2).opacity(0.4)
                    .frame(maxWidth: .infinity).frame(height: BP.px(520)).clipped()
                    .frame(maxHeight: .infinity, alignment: .top)
                    .id(s.url)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(BP.easeSlow, value: shown?.url)
        .accessibilityHidden(true)
        .task(id: url ?? "") { await commit() }
    }

    private func commit() async {
        if url == shown?.url { return }
        try? await Task.sleep(for: BPTitleArt.settle)
        guard !Task.isCancelled else { return }
        guard let url, let u = URL(string: url) else {
            shown = nil
            return
        }
        let small = await ImageLoader.shared.image(for: u, target: HeroBlur.target)
        guard !Task.isCancelled, let small else { return }
        let blurred = await HeroBlur.shared.blurred(small, key: url)
        guard !Task.isCancelled, let blurred else { return }
        shown = Shown(url: url, image: blurred)
    }
}

/// One pre-blurred bitmap per cover URL for BPBlurredHeroBackdrop.
final class HeroBlur: @unchecked Sendable {
    static let shared = HeroBlur()
    /// 240 px wide, an eighth of the 1920 pt the backdrop spans: a blur this heavy leaves nothing
    /// a bigger decode would add, and stretching it back up costs a plain texture draw.
    static let target = ImageLoader.Target(width: 240, height: 1)
    private let cache = NSCache<NSString, UIImage>()
    private let context = CIContext(options: [.cacheIntermediates: false])

    init() {
        cache.countLimit = 48
    }

    /// (perf/memory pass) A memory warning drops the blurred bitmaps (the one on screen stays drawn).
    func purge() {
        cache.removeAllObjects()
    }

    func blurred(_ image: UIImage, key: String) async -> UIImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let out = await Task.detached(priority: .userInitiated) { [self] in
            self.render(image)
        }.value
        if let out { cache.setObject(out, forKey: key as NSString) }
        return out
    }

    /// (overnight polish, device build 311) A hero art file under ~1100 px wide (an anime episode
    /// still, a small fixed-tier poster) is stretched ~3-6x across the 4K screen and shows its JPEG
    /// blocks. It is drawn through a light Gaussian soften instead: the picture still reads, the
    /// blocks do not. Bigger art is returned as is.
    func softenIfSmall(_ image: UIImage, key: String) async -> UIImage {
        let px: CGFloat = image.size.width * image.scale
        guard px > 0, px < 1100 else { return image }
        let cacheKey: NSString = ("soft:" + key) as NSString
        if let hit = cache.object(forKey: cacheKey) { return hit }
        let out: UIImage? = await Task.detached(priority: .userInitiated) { [self] in
            self.soften(image)
        }.value
        guard let out else { return image }
        cache.setObject(out, forKey: cacheKey)
        return out
    }

    private func soften(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage, cg.width > 0 else { return nil }
        let input = CIImage(cgImage: cg)
        let sigma: Double = max(1.2, Double(cg.width) / 520)
        let softened = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        guard let out = context.createCGImage(softened, from: input.extent) else { return nil }
        return UIImage(cgImage: out)
    }

    private func render(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage, cg.width > 0 else { return nil }
        let input = CIImage(cgImage: cg)
        // The old .blur(radius: 36) was taken across the 1920 pt the image is drawn at.
        let sigma = 36 * Double(cg.width) / 1920
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        guard let out = context.createCGImage(blurred, from: input.extent) else { return nil }
        return UIImage(cgImage: out)
    }
}

/// bp-tokens.ts @keyframes bp-kenburns, 14 s cubic-bezier(0.22,1,0.36,1) after 900 ms, forwards:
/// scale up to 1.075 while easing 1.1 % / 0.7 % toward the top leading corner by 72 %, then
/// settle back to rest.
struct KenBurnsImage: View {
    let image: UIImage
    var drift = true
    /// (owner report 2026-10-01, Death Note) Anime key art puts full-length characters across the
    /// whole frame, and filled to the screen's height their lower halves sat behind the rows. Anime
    /// art is drawn whole at the frame's width instead, from the top, fading out at its foot.
    var fitWidth = false
    @State private var phase = 0

    /// (owner report 2026-10-01) A wide banner (AniList's are ~4.75:1) filled to the full screen
    /// height was scaled ~3x and cropped to its middle third, so the characters sat down behind the
    /// rows (Death Note's Light and Ryuk). A banner is drawn across the top instead, tall enough to
    /// cover the hero copy, and fades out at its foot; 16:9 backdrops keep the full-screen fill.
    private var aspect: CGFloat { image.size.height > 0 ? image.size.width / image.size.height : 16.0 / 9.0 }

    var body: some View {
        GeometryReader { g in
            let banner: Bool = aspect >= 2.0 || fitWidth
            let floor: CGFloat = fitWidth ? 0.5 : 0.62
            let h: CGFloat = banner ? min(g.size.height, max(g.size.width / aspect, g.size.height * floor)) : g.size.height
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: g.size.width, height: h)
                .clipped()
                .mask(
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: banner ? 0.62 : 1),
                                           .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                )
                .offset(x: phase == 1 ? -0.011 * g.size.width : 0, y: phase == 1 ? -0.007 * g.size.height : 0)
                .scaleEffect(phase == 1 ? 1.075 : 1)
                .frame(width: g.size.width, height: g.size.height, alignment: .top)
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
                Image(systemName: "laurel.leading").font(.system(size: BP.px(30), weight: .regular)).accessibilityHidden(true)
                Text(c.mark).font(BP.sans(12, .bold)).lineLimit(1)
                Image(systemName: "laurel.trailing").font(.system(size: BP.px(30), weight: .regular)).accessibilityHidden(true)
            }
            .foregroundStyle(tint)
        } else {
            Text(c.mark).font(BP.sans(14, .bold)).foregroundStyle(tint).lineLimit(1).opacity(0.85)
        }
    }
}
