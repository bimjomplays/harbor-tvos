import SwiftUI
import UIKit

/// views/kids-detail.tsx without React: Cinemeta + TMDB merged in the engine (engine/kids.ts
/// detail), then one TMDB season at a time (kids-detail/kids-episodes.tsx).
@MainActor
final class KidsDetailModel: ObservableObject {
    struct Season: Decodable, Hashable { var seasonNumber: Int; var name: String }
    struct Collection: Decodable { var id: Int; var name: String; @LossyArray var metas: [Meta] }   // (bug pass 2) lossy
    struct Detail: Decodable {
        var name: String
        var backdrop: String?
        var logo: String?
        var overview: String
        var genres: [String]
        var runtime: String?
        var year: String?
        var tvId: Int?
        var seasons: [Season]
        var collection: Collection?
        @LossyArray var recs: [Meta]
    }
    struct Episode: Decodable, Identifiable, Equatable {
        var id: Int
        var season: Int
        var episode: Int
        var name: String
        var still: String?
        var rating: String?
    }

    let meta: Meta
    @Published private(set) var detail: Detail?
    @Published private(set) var episodes: [Episode] = []
    @Published private(set) var episodesLoading = true
    @Published private(set) var season = 1

    init(meta: Meta) { self.meta = meta }

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    /// (bug pass) The page's `.task` runs again whenever a cover over it closes (the picker, the
    /// player, a related title). Reloading reset the season to the first one, so after an episode
    /// of Season 3 the grid jumped back to Season 1. Once loaded, keep what is there.
    func load() async {
        guard detail == nil else { return }
        let p = profile
        let d: Detail? = try? await HarborEngine.shared.call("kidsRoom.detail", [meta, p.id, p.linked])
        guard detail == nil else { return }
        detail = d
        if let d {
            await CardMarksStore.shared.refresh(d.recs + (d.collection?.metas ?? []))
            // kids-episodes.tsx: useState(seasons[0]?.seasonNumber ?? 1).
            if d.tvId != nil {
                season = d.seasons.first?.seasonNumber ?? 1
                await loadEpisodes()
            }
        }
    }

    func choose(_ s: Int) {
        guard s != season else { return }
        season = s
        Task { await loadEpisodes() }
    }

    private func loadEpisodes() async {
        guard let tvId = detail?.tvId else { return }
        let p = profile
        let asked = season
        episodesLoading = true
        let list: [Episode] = (try? await HarborEngine.shared.call("kidsRoom.episodes", [tvId, asked, p.id, p.linked])) ?? []
        guard asked == season else { return }
        episodes = list
        episodesLoading = false
    }
}

/// The simplified detail page a kid profile gets (views/kids-detail.tsx): backdrop hero with the
/// logo, a few chips and one big Play, the overview, episodes by season for a series, the
/// franchise collection and "More to explore". Play goes straight to the best source.
struct KidsDetailView: View {
    @StateObject private var model: KidsDetailModel
    /// kids-detail.tsx episodeHint: the episode Play starts from (S1 E1 for a series otherwise).
    var episodeHint: (season: Int, episode: Int)? = nil
    @State private var picker: KidsPickerTarget?
    @State private var pickerAuto = true
    @State private var playing: KidsPlayTarget?
    @State private var related: Meta?
    @State private var seasonGrid = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var playFocused: Bool

    init(meta: Meta, episodeHint: (season: Int, episode: Int)? = nil) {
        _model = StateObject(wrappedValue: KidsDetailModel(meta: meta))
        self.episodeHint = episodeHint
    }

    private var meta: Meta { model.meta }
    private var isSeries: Bool { meta.type == "series" }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: BP.px(40)) {
                hero
                VStack(alignment: .leading, spacing: BP.px(40)) {
                    if let o = model.detail?.overview, !o.isEmpty {
                        Text(o).font(KidsTheme.font(17, .medium)).foregroundStyle(KidsTheme.ink)
                            .lineSpacing(BP.px(5)).frame(maxWidth: BP.px(768), alignment: .leading)
                            .padding(.horizontal, BP.gutter)
                    }
                    if isSeries, let d = model.detail, d.tvId != nil, !d.seasons.isEmpty { episodes(d) }
                    if let c = model.detail?.collection {
                        KidsRowView(row: KidsModel.Row(key: "collection-\(c.id)", title: c.name, metas: c.metas, hasMore: false), onOpen: { related = $0 }) {}
                    }
                    if let recs = model.detail?.recs, !recs.isEmpty {
                        KidsRowView(row: KidsModel.Row(key: "kids-detail:\(meta.id)", title: "More to explore", metas: recs, hasMore: false), onOpen: { related = $0 }) {}
                    }
                }
                .padding(.bottom, BP.px(120))
            }
        }
        .background(KidsTheme.canvas.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .task {
            // (bug pass) Seed Play only on the first visit: after the player or picker closes the
            // ring stays where the viewer left it (an episode card) instead of jumping to Play.
            guard model.detail == nil else { return }
            await model.load()
            playFocused = true
        }
        .onExitCommand {
            if seasonGrid { seasonGrid = false } else { dismiss() }
        }
        .fullScreenCover(item: $related) { m in KidsDetailView(meta: m) }
        .fullScreenCover(item: $picker) { target in
            PlayPickerView(meta: target.meta, episode: target.episode, onPlay: { _, resolved in
                guard let link = resolved.data, let url = PlayableURL.make(link.url) else { return }   // (bug pass 2) the picker checked it
                self.picker = nil
                let pick = PlayerPickInfo(autoPicked: resolved.autoPicked ?? false, attempt: target.attempt, streamRef: resolved.streamRef)
                let ep = target.episode
                let s: Int? = ep?["season"]?.number.map { Int($0) }
                let e: Int? = ep?["episode"]?.number.map { Int($0) }
                let sub: String? = Self.subtitle(ep)
                let ctx = PlaybackContext(meta: meta, season: s, episode: e, videoId: ep?["videoId"]?.string,
                                          imdbId: meta.id.hasPrefix("tt") ? meta.id : nil, imdbVerified: meta.id.hasPrefix("tt"),
                                          homeServer: resolved.homeServer)
                // Present after the picker's cover has dismissed; a present-while-dismissing is dropped on tvOS.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    let upNext: String? = nextEpisode(after: ctx).map { n in "S\(n.season) E\(n.episode) · \(n.name)" }
                    playing = KidsPlayTarget(url: url, headers: link.headers ?? [:], title: meta.name, subtitle: sub, context: ctx, upNext: upNext, episode: ep, pick: pick)
                }
            }, autoPlay: pickerAuto)
        }
        .fullScreenCover(item: $playing) { t in
            PlayerScreen(title: t.title, subtitle: t.subtitle, url: t.url, headers: t.headers, context: t.context, upNext: t.upNext,
                         onChooseAnother: { pickerAuto = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { picker = KidsPickerTarget(meta: meta, episode: t.episode) } },
                         pick: t.pick,
                         onPickAgain: { auto in
                             // views/player.tsx openPicker(meta, episode, { autoPlay: true, attempt: attempt + 1 }).
                             pickerAuto = auto
                             let next = (t.pick?.attempt ?? 0) + 1
                             DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { picker = KidsPickerTarget(meta: meta, episode: t.episode, attempt: next) }
                         }) { natural in
                playing = nil
                // A finished episode opens the next one of the loaded season, straight to its best source.
                if natural, let next = nextEpisode(after: t.context) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { play(next, auto: true) }
                }
            }
        }
    }

    // MARK: hero

    private var hero: some View {
        let d = model.detail
        let backdrop = d?.backdrop ?? meta.background ?? meta.poster
        return ZStack(alignment: .bottomLeading) {
            KidsTheme.surface
            if let backdrop { RemoteImage(url: backdrop) }
            LinearGradient(stops: [.init(color: KidsTheme.canvas, location: 0), .init(color: KidsTheme.canvas.opacity(0.35), location: 0.5), .init(color: .clear, location: 1)],
                           startPoint: .bottom, endPoint: .top)
            LinearGradient(colors: [.black.opacity(0.3), .clear, .clear], startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: BP.px(20)) {
                if let logo = d?.logo ?? meta.logo {
                    KidsLogoImage(url: logo)
                        .frame(maxWidth: BP.px(560), maxHeight: BP.px(128), alignment: .leading)
                        .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
                } else {
                    Text(d?.name.isEmpty == false ? d!.name : meta.name)
                        .font(KidsTheme.font(60, .semibold)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 12, y: 3)
                }
                HStack(spacing: BP.px(8)) {
                    if let y = d?.year ?? meta.releaseInfo, !y.isEmpty { chip(y) }
                    if let r = d?.runtime, !r.isEmpty { chip(r) }
                    ForEach(d?.genres ?? [], id: \.self) { chip($0) }
                }
                Button { onPlay() } label: {
                    HStack(spacing: BP.px(12)) {
                        Image(systemName: "play.fill")
                            .font(.system(size: BP.px(22), weight: .bold))
                            .frame(width: BP.px(44), height: BP.px(44))
                            .background(Circle().fill(.white.opacity(0.25)))
                        Text("Play").font(KidsTheme.font(22, .heavy))
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, BP.px(10)).padding(.trailing, BP.px(36))
                    .frame(height: BP.px(64))
                    .background(Capsule().fill(KidsTheme.teal))
                }
                .buttonStyle(KidsCardStyle(radius: BP.px(32), ring: 0))
                .focused($playFocused)
                .accessibilityIdentifier("kids-detail-play")
            }
            .padding(.horizontal, BP.gutter)
            .padding(.bottom, BP.px(36))
        }
        .frame(height: BP.px(640))
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(KidsTheme.font(13.5, .bold)).foregroundStyle(KidsTheme.deep)
            .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(6))
            .background(Capsule().fill(.white.opacity(0.75)))
            .overlay(Capsule().stroke(.white.opacity(0.6), lineWidth: 1))
    }

    // MARK: episodes

    private func episodes(_ d: KidsDetailModel.Detail) -> some View {
        VStack(alignment: .leading, spacing: BP.px(16)) {
            HStack(spacing: BP.px(10)) {
                Image(systemName: "tv").font(.system(size: BP.px(24), weight: .bold)).foregroundStyle(KidsTheme.teal)
                Text("Episodes").font(KidsTheme.font(26, .heavy)).foregroundStyle(KidsTheme.deep)
            }
            .padding(.horizontal, BP.gutter)
            if d.seasons.count > 1 { seasonPicker(d.seasons) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BP.px(18)), count: 4), alignment: .leading, spacing: BP.px(22)) {
                if model.episodesLoading {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: BP.px(16), style: .continuous).fill(.white.opacity(0.4))
                            .aspectRatio(16 / 9, contentMode: .fit)
                    }
                } else {
                    ForEach(model.episodes) { ep in
                        Button { play(ep, auto: SettingsBridge.shared.slice.instantPlay ?? true) } label: { KidsEpisodeCard(ep: ep) }
                            .buttonStyle(KidsEpisodeStyle())
                    }
                }
            }
            .padding(.horizontal, BP.gutter)
            .focusSection()
        }
    }

    /// kids-episodes.tsx SeasonPicker: chips up to seven seasons; past that a stepper whose centre
    /// opens a five-column grid of season numbers.
    @ViewBuilder private func seasonPicker(_ seasons: [KidsDetailModel.Season]) -> some View {
        if seasons.count <= 7 {
            HStack(spacing: BP.px(8)) {
                ForEach(seasons, id: \.seasonNumber) { s in
                    let on = s.seasonNumber == model.season
                    Button { model.choose(s.seasonNumber) } label: { Text("Season \(s.seasonNumber)") }
                        .buttonStyle(KidsPillStyle(fill: on ? KidsTheme.teal : .white.opacity(0.7), ink: on ? .white : KidsTheme.deep))
                }
            }
            .padding(.horizontal, BP.gutter)
            .focusSection()
        } else {
            let idx = seasons.firstIndex { $0.seasonNumber == model.season } ?? 0
            VStack(alignment: .leading, spacing: BP.px(10)) {
                HStack(spacing: BP.px(8)) {
                    Button { if idx > 0 { model.choose(seasons[idx - 1].seasonNumber) } } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(KidsPillStyle(ink: KidsTheme.teal))
                        .disabled(idx <= 0)
                    Button { seasonGrid.toggle() } label: {
                        HStack(spacing: BP.px(8)) {
                            Text("Season \(model.season)")
                            Image(systemName: seasonGrid ? "chevron.up" : "chevron.down")
                        }
                        .frame(minWidth: BP.px(150))
                    }
                    .buttonStyle(KidsPillStyle(fill: KidsTheme.teal, ink: .white))
                    Button { if idx < seasons.count - 1 { model.choose(seasons[idx + 1].seasonNumber) } } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(KidsPillStyle(ink: KidsTheme.teal))
                        .disabled(idx >= seasons.count - 1)
                }
                if seasonGrid {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(BP.px(58)), spacing: BP.px(8)), count: 5), alignment: .leading, spacing: BP.px(8)) {
                        ForEach(seasons, id: \.seasonNumber) { s in
                            let on = s.seasonNumber == model.season
                            Button { model.choose(s.seasonNumber); seasonGrid = false } label: { Text("\(s.seasonNumber)") }
                                .buttonStyle(KidsPillStyle(fill: on ? KidsTheme.teal : Color(hex: 0xeaf6f5), ink: on ? .white : KidsTheme.deep))
                        }
                    }
                    .padding(BP.px(12))
                    .background(RoundedRectangle(cornerRadius: BP.px(16), style: .continuous).fill(.white))
                    .frame(width: BP.px(360), alignment: .leading)
                }
            }
            .padding(.horizontal, BP.gutter)
            .focusSection()
        }
    }

    // MARK: play

    /// kids-detail.tsx onPlay: openPicker(meta, episodeHint ?? S1E1 for a series, { autoPlay: true, resume: true }).
    private func onPlay() {
        pickerAuto = true
        if isSeries {
            let hint = episodeHint ?? (season: 1, episode: 1)
            picker = KidsPickerTarget(meta: meta, episode: .object(["season": .number(Double(hint.season)), "episode": .number(Double(hint.episode))]))
        } else {
            picker = KidsPickerTarget(meta: meta, episode: nil)
        }
    }

    /// kids-episodes.tsx play(ep): openPicker(meta, {season, episode}, { autoPlay: settings.instantPlay }).
    private func play(_ ep: KidsDetailModel.Episode, auto: Bool) {
        pickerAuto = auto
        picker = KidsPickerTarget(meta: meta, episode: .object(["season": .number(Double(ep.season)), "episode": .number(Double(ep.episode)), "name": .string(ep.name)]))
    }

    /// "S1 E2 · Name" for the player's subtitle line, as DetailView builds it.
    private static func subtitle(_ ep: AnyJSON?) -> String? {
        guard let s = ep?["season"]?.number, let e = ep?["episode"]?.number else { return nil }
        let name: String = ep?["name"]?.string.map { " · \($0)" } ?? ""
        return "S\(Int(s)) E\(Int(e))\(name)"
    }

    private func nextEpisode(after ctx: PlaybackContext) -> KidsDetailModel.Episode? {
        guard let s = ctx.season, let e = ctx.episode,
              let idx = model.episodes.firstIndex(where: { $0.season == s && $0.episode == e }), idx + 1 < model.episodes.count else { return nil }
        return model.episodes[idx + 1]
    }
}

struct KidsPickerTarget: Identifiable {
    let meta: Meta
    let episode: AnyJSON?
    /// view.ts picker frame `attempt`: how many times the player sent this title back (0 = the viewer opened it).
    var attempt = 0
    let id = UUID()
}

struct KidsPlayTarget: Identifiable {
    var id: String { url.absoluteString }
    var url: URL
    var headers: [String: String]
    var title: String
    var subtitle: String?
    var context: PlaybackContext
    var upNext: String?
    var episode: AnyJSON?
    /// PlayerSrc autoFired / attempt / streamRef (views/player.tsx next-stream skip).
    var pick: PlayerPickInfo? = nil
}

/// kids-episodes.tsx EpisodeCard: 16:9 still, "Ep n" badge, the star rating badge, name below.
struct KidsEpisodeCard: View {
    let ep: KidsDetailModel.Episode
    /// The episode button's focus (the nearest focusable ancestor), for the ring and the play disc.
    @Environment(\.isFocused) private var focused
    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            ZStack {
                KidsTheme.surface
                if let still = ep.still { RemoteImage(url: still) }
                LinearGradient(colors: [.black.opacity(0.6), .clear, .clear], startPoint: .bottom, endPoint: .top)
                Text("Ep \(ep.episode)")
                    .font(KidsTheme.font(12, .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(4))
                    .background(Capsule().fill(.black.opacity(0.75)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(BP.px(8))
                if let rating = ep.rating {
                    // /kids/starbadge.svg (tvOS cannot draw the SVG): a sunny star with the score on it.
                    ZStack {
                        Image(systemName: "star.fill").font(.system(size: BP.px(36))).foregroundStyle(KidsTheme.sunny)
                            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                        Text(rating).font(KidsTheme.font(9, .heavy)).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                            .offset(y: BP.px(1))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(BP.px(6))
                }
                if focused {
                    Image(systemName: "play.fill")
                        .font(.system(size: BP.px(24), weight: .bold)).foregroundStyle(KidsTheme.teal)
                        .frame(width: BP.px(56), height: BP.px(56))
                        .background(Circle().fill(.white.opacity(0.9)))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: BP.px(16), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.px(16), style: .continuous).stroke(focused ? KidsTheme.sunny : .white, lineWidth: focused ? BP.px(2) + 3 : BP.px(2)))
            .shadow(color: KidsTheme.shadow.opacity(focused ? 0.55 : 0.45), radius: focused ? 18 : 14, y: focused ? 16 : 12)
            Text(ep.name).font(KidsTheme.font(15, .bold)).foregroundStyle(KidsTheme.deep).lineLimit(1)
        }
    }
}

/// The episode button: the card lifts and shows its play disc while focused (group-hover).
struct KidsEpisodeStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .scaleEffect(focused ? (configuration.isPressed ? 1.02 : 1.05) : 1)
                .offset(y: focused ? -BP.px(4) : 0)
                .animation(BP.ease, value: focused)
        }
    }
}
