import SwiftUI
import UIKit

/// Detail page (bp-detail): hero with backdrop, logo/title, facts, actions, synopsis; then episodes.
struct DetailView: View {
    @StateObject private var model: DetailModel
    @State private var picker: (meta: Meta, episode: AnyJSON?)?
    /// use-bp-stream-play autoPlay: Play and auto-advance fire the best source; "Sources" never does.
    @State private var pickerAuto = false
    /// bp-detail.tsx onSources(…, applyPreference): the list was opened by Play (the hero, an
    /// episode, a Play handed over), so the Play button behavior setting applies to it.
    @State private var pickerPref = false
    @State private var playing: PlayTarget?
    /// bp-player-sources: the position the next pick resumes from after "Switch source".
    @State private var switchFromSec: Double?
    @State private var related: Meta?
    @State private var listDialog = false
    @State private var factsDialog = false
    struct TrailerPick: Identifiable { let ytId: String; let name: String?; var id: String { ytId } }
    @State private var trailer: TrailerPick?
    @State private var awardType: DetailModel.TitleAwards.Group?
    @State private var seasonsSheet = false
    @State private var rateDialog = false
    @State private var person: DetailModel.Extras.Cast?
    /// bp-status-dialog: the tracker whose list status is being changed.
    @State private var trackerDialog: DetailModel.Tracker?
    @FocusState private var heroFocus: String?
    @Environment(\.dismiss) private var dismiss

    /// use-bp-detail-actions BpDetailAction.
    struct HeroAction: Identifiable {
        let key: String
        let label: String
        let icon: String
        var active = false
        var badge: String? = nil
        let run: () -> Void
        var id: String { key }
    }

    /// use-bp-detail-actions.ts, in its order: Sources (movies with instant play), Watchlist, trackers,
    /// Mark watched on Trakt, Favourite, Remind me (series), Rate, Add to list, Mark watched (movies),
    /// Watch trailer. Download is left out: tvOS has nowhere to keep a film offline. Back closes the page.
    private var heroActions: [HeroAction] {
        var out: [HeroAction] = []
        let hero = model.hero
        if model.isMovie, SettingsBridge.shared.slice.instantPlay ?? true {
            // A series has no single set of streams; its Play already is the picker's way in.
            out.append(HeroAction(key: "sources", label: "Sources", icon: "list.bullet") {
                pickerAuto = false; pickerPref = false
                picker = (model.meta, nil)
            })
        }
        if model.canWatchlist {
            let saved = model.inWatchlist
            out.append(HeroAction(key: "watchlist", label: saved ? "In Watchlist" : "Add to Watchlist", icon: saved ? "checkmark" : "plus", active: saved) {
                guard !model.watchlistBusy else { return }
                Task { await model.toggleWatchlist() }
            })
        }
        for tr in model.trackers {
            let label = tr.statusLabel.map { "\(tr.name) · \($0)" } ?? "Add to \(tr.name)"
            out.append(HeroAction(key: tr.key, label: label, icon: "plus", active: tr.status != nil) { trackerDialog = tr })
        }
        if model.isMovie, hero?.traktMovie == true {
            out.append(HeroAction(key: "trakt", label: "Mark watched on Trakt", icon: "t.circle") {
                Task { await model.traktMarkWatched() }
            })
        }
        let fav = hero?.favorite ?? false
        out.append(HeroAction(key: "favorite", label: fav ? "Favorited" : "Add to favorites", icon: fav ? "heart.fill" : "heart", active: fav) {
            Task { await model.toggleFavorite() }
        })
        if model.isSeries {
            let on = hero?.reminder ?? false
            out.append(HeroAction(key: "reminder", label: on ? "Reminder on" : "Remind me", icon: on ? "bell.fill" : "bell", active: on) {
                Task { await model.toggleReminder() }
            })
        }
        let score = hero?.rating
        out.append(HeroAction(key: "rate", label: score.map { "Your rating \($0)/10" } ?? "Rate this", icon: score == nil ? "star" : "star.fill",
                              active: score != nil, badge: score.map { String($0) }) { rateDialog = true })
        out.append(HeroAction(key: "lists", label: "Add to list", icon: "square.stack.3d.up") { listDialog = true })
        if model.isMovie, hero?.showWatchedButton ?? true {
            let watched = model.movieWatched
            out.append(HeroAction(key: "watched", label: watched ? "Marked watched" : "Mark watched", icon: "checkmark", active: watched) {
                Task { await model.toggleWatched() }
            })
        }
        if let yt = model.trailerYtId {
            out.append(HeroAction(key: "trailer", label: "Watch trailer", icon: "film") { trailer = TrailerPick(ytId: yt, name: nil) })
        }
        out.append(HeroAction(key: "back", label: "Back", icon: "chevron.left") { dismiss() })
        return out
    }

    struct PlayTarget: Identifiable {
        var id: String { url.absoluteString }
        var url: URL
        var headers: [String: String]
        var title: String
        var subtitle: String?
        var context: PlaybackContext
        var upNext: String?
        var episode: AnyJSON?
        /// What the Auto engine rule reads (engine/player.ts pickEngine).
        var hints: PlayerStreamHints? = nil
    }

    /// Quick panel / Discovery Queue "Play now": open the picker as soon as the page knows what to play.
    var autoPlay = false
    /// Watch Together (together-invite-toast.tsx openPicker(meta, invite.episode, {autoPlay: !guestPick})):
    /// the episode the room is playing, and whether guests pick their own source.
    var roomEpisode: AnyJSON? = nil
    var roomPick = false
    init(meta: Meta, autoPlay: Bool = false, roomEpisode: AnyJSON? = nil, roomPick: Bool = false) {
        _model = StateObject(wrappedValue: DetailModel(meta: meta)); self.autoPlay = autoPlay
        self.roomEpisode = roomEpisode; self.roomPick = roomPick
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(26)) {
                    VStack(alignment: .leading, spacing: BP.px(26)) {
                        hero
                        if model.isSeries { episodes }
                    }
                    .padding(.horizontal, BP.gutter)
                    // Rail rows carry their own gutter (BPRowView), so they sit outside the padded column.
                    tmdbRows
                    Color.clear.frame(height: BP.px(60))
                }
                .padding(.top, BP.px(250))
            }
        }
        .ignoresSafeArea()
        .task {
            await model.load()
            if autoPlay, picker == nil {
                pickerAuto = roomPick ? false : (SettingsBridge.shared.slice.instantPlay ?? true)
                pickerPref = !roomPick
                if let re = roomEpisode, let s = re["season"]?.number, let e = re["episode"]?.number {
                    picker = (model.meta, model.episodes.first(where: { $0.season == Int(s) && $0.episode == Int(e) })?.playEpisode ?? re)
                } else if model.isSeries, let target = model.playTarget { picker = (model.meta, target.playEpisode) } else { picker = (model.meta, nil) }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } })) {
            if let picker {
                PlayPickerView(meta: picker.meta, episode: picker.episode, onPlay: { stream, resolved in
                    guard let link = resolved.data, let url = URL(string: link.url) else { return }
                    let ep = picker.episode
                    let sub = ep.flatMap { e -> String? in
                        guard let s = e["season"]?.number, let n = e["episode"]?.number else { return nil }
                        return "S\(Int(s)) E\(Int(n))" + (e["name"]?.string.map { " · \($0)" } ?? "")
                    }
                    self.picker = nil
                    let ctx = PlaybackContext(meta: model.meta,
                                              season: ep?["season"]?.number.map { Int($0) }, episode: ep?["episode"]?.number.map { Int($0) },
                                              videoId: ep?["videoId"]?.string, imdbId: model.meta.id.hasPrefix("tt") ? model.meta.id : nil,
                                              imdbVerified: model.meta.id.hasPrefix("tt"), homeServer: resolved.homeServer,
                                              explicitStartSec: switchFromSec)
                    switchFromSec = nil
                    // Present after the picker's cover has dismissed; a present-while-dismissing is dropped on tvOS.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        Task { @MainActor in
                            var upNext: String?
                            if let s = ctx.season, let e = ctx.episode, let idx = model.episodes.firstIndex(where: { $0.season == s && $0.episode == e }), idx + 1 < model.episodes.count {
                                let n = model.episodes[idx + 1]
                                // views/player.tsx nextEpMask: a hidden title leaves only "S E" on the up-next card.
                                if n.season > 0 { upNext = await model.upNextText(n) }
                            }
                            let hints = PlayerStreamHints(notWebReady: link.notWebReady, container: stream?.container,
                                                          hdrFormat: stream?.hdrFormat, filename: link.filename)
                            playing = PlayTarget(url: url, headers: link.headers ?? [:], title: model.meta.name, subtitle: sub, context: ctx, upNext: upNext, episode: ep, hints: hints)
                        }
                    }
                }, autoPlay: pickerAuto, applyPreference: pickerPref)
            }
        }
        .fullScreenCover(item: $related) { m in DetailView(meta: m) }
        .fullScreenCover(isPresented: $listDialog) { ListDialogView(meta: model.meta) }
        .fullScreenCover(isPresented: $factsDialog) { FactsDialogView(title: model.meta.name, facts: model.extras?.facts ?? []) }
        .fullScreenCover(item: $trailer) { t in TrailerView(ytId: t.ytId, title: model.meta.name, clipName: t.name) { trailer = nil } }
        .fullScreenCover(isPresented: $seasonsSheet) {
            SeasonsSheet(seasons: model.seasons, counts: Dictionary(grouping: model.episodes, by: \.season).mapValues(\.count), season: Binding(get: { model.season }, set: { model.season = $0 }))
        }
        .fullScreenCover(item: $awardType) { g in AwardsDialogView(group: g, entries: (model.awards?.entries ?? []).filter { $0.type == g.type }) }
        // The Rate cell shows the score, so it re-reads the rating when the dialog closes.
        .fullScreenCover(isPresented: $rateDialog, onDismiss: { Task { await model.loadHero() } }) { RateDialogView(meta: model.meta) }
        .fullScreenCover(item: $trackerDialog) { tr in
            TrackerDialogView(tracker: tr,
                              onPick: { status in Task { await model.setTracker(tr.key, status: status) } },
                              onRemove: { Task { await model.removeTracker(tr.key) } })
        }
        .fullScreenCover(item: $person) { c in PersonView(personId: c.id, name: c.name) }
        .fullScreenCover(item: $playing) { t in
            PlayerScreen(title: t.title, subtitle: t.subtitle, url: t.url, headers: t.headers, context: t.context, upNext: t.upNext, streamHints: t.hints,
                         onChooseAnother: { pickerAuto = false; pickerPref = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { picker = (model.meta, t.episode) } },
                         onSwitchSource: { at in pickerAuto = false; pickerPref = false; switchFromSec = at; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { picker = (model.meta, t.episode) } },
                         onPreviousEpisode: previousEpisodeAction(t.context)) { natural in
                playing = nil
                // The strip's started / next-up (and so its spoiler masks) move with what was just played.
                Task { await model.loadWatchedState() }
                // Auto-advance (player-spec §1.9, simplified): a finished episode opens the next one's picker.
                if natural, let s = t.context.season, let e = t.context.episode,
                   let idx = model.episodes.firstIndex(where: { $0.season == s && $0.episode == e }),
                   idx + 1 < model.episodes.count {
                    let next = model.episodes[idx + 1]
                    if next.season > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { pickerAuto = SettingsBridge.shared.slice.instantPlay ?? true; pickerPref = false; picker = (model.meta, next.playEpisode) } }
                }
            }
        }
    }

    /// bp-player-controls "Previous episode": the episode before this one opens its picker (after
    /// the player's cover has dismissed, like Switch source); nil on the first episode or a movie.
    private func previousEpisodeAction(_ ctx: PlaybackContext) -> (() -> Void)? {
        guard let s = ctx.season, let e = ctx.episode,
              let idx = model.episodes.firstIndex(where: { $0.season == s && $0.episode == e }), idx > 0 else { return nil }
        let prev = model.episodes[idx - 1]
        guard prev.season > 0 else { return nil }
        let episode = prev.playEpisode
        return {
            pickerAuto = SettingsBridge.shared.slice.instantPlay ?? true
            pickerPref = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { picker = (model.meta, episode) }
        }
    }

    private var backdrop: some View {
        ZStack {
            BP.void_
            GeometryReader { g in
                RemoteImage(url: model.meta.background ?? model.meta.poster)
                    .frame(width: g.size.width * 0.76, height: g.size.height * 0.75)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .leading, endPoint: .init(x: 0.45, y: 0.5)))
                    .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.9)))
            }
            LinearGradient(colors: [BP.void_.opacity(0.85), BP.void_.opacity(0.4), .clear], startPoint: .leading, endPoint: .init(x: 0.7, y: 0.5))
        }
        .ignoresSafeArea()
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            if let logo = model.meta.logo, !logo.isEmpty {
                RemoteImage(url: logo, contentMode: .fit).frame(maxWidth: BP.px(380), maxHeight: BP.px(140), alignment: .leading)
            } else {
                Text(model.meta.name).font(BP.display(52)).foregroundStyle(BP.ink).lineLimit(2).frame(maxWidth: BP.px(700), alignment: .leading)
            }
            HStack(spacing: BP.px(12)) {
                // bp-detail: every provider the detail settings allow (use-bp-card-badges "detail").
                ScoreChipsView(meta: model.meta, surface: "detail", limit: 6)
                Text(model.meta.facts).font(BP.sans(13.4, .medium)).foregroundStyle(BP.inkMuted)
            }
            HStack(spacing: BP.px(8)) {
                Button {
                    pickerAuto = SettingsBridge.shared.slice.instantPlay ?? true
                    pickerPref = true
                    if model.isSeries, let target = model.playTarget { picker = (model.meta, target.playEpisode) }
                    else { picker = (model.meta, nil) }
                } label: {
                    VStack(spacing: 0) {
                        Label(model.playLabel, systemImage: "play.fill")
                        // Progress under Play, only mid-way through (0.01 < progress < 0.97).
                        if let r = model.resume, r.progress > 0.01, r.progress < 0.97 {
                            GeometryReader { g in
                                Capsule().fill(BP.accent).frame(width: g.size.width * r.progress, height: BP.px(3))
                            }
                            .frame(height: BP.px(3))
                        }
                    }
                }
                .buttonStyle(BPActionStyle(primary: true))
                .focused($heroFocus, equals: "play")
                .accessibilityIdentifier("detail-play")
                // bp-detail-actions BpSecondaryAction: icon cells; the line under the row names the focused one.
                ForEach(heroActions) { a in
                    Button { a.run() } label: {
                        if let badge = a.badge {
                            Text(badge).font(BP.sans(13.4, .bold)).monospacedDigit()
                        } else {
                            Image(systemName: a.icon)
                        }
                    }
                    .buttonStyle(DetailIconActionStyle(active: a.active))
                    .focused($heroFocus, equals: a.key)
                    .accessibilityLabel(a.label)
                    .accessibilityIdentifier("detail-action-\(a.key)")
                }
            }
            .focusSection()
            // BP_ACTION_HINT: the focused icon's label; blank when Play or nothing in the row has focus.
            Text(heroActions.first(where: { $0.key == heroFocus })?.label ?? " ")
                .font(BP.sans(12.5, .semibold)).tracking(0.5).foregroundStyle(BP.inkSubtle)
                .frame(height: BP.px(16), alignment: .leading)
            // bp-hero-manga: "Read the Manga" on an anime while the manga reader is on, and "Read
            // the eBook" for a light novel while the eBook tab is on (MangaHeroEntry picks which).
            if model.isAnimeId, SettingsBridge.shared.mangaOn || UserDefaults.standard.bool(forKey: EBookGate.key) { MangaHeroEntry(meta: model.meta) }
            if let tag = model.extras?.tagline, !tag.isEmpty {
                Text(tag).font(BP.sans(14, .semibold)).italic().foregroundStyle(BP.inkMuted).lineLimit(1).frame(maxWidth: BP.px(620), alignment: .leading)
            }
            Text(model.meta.description ?? model.extras?.overview ?? "").font(BP.sans(13, .regular)).foregroundStyle(BP.inkMuted).lineSpacing(4).lineLimit(4)
                .frame(maxWidth: BP.px(620), alignment: .leading)
            if let providers = model.extras?.watchOn, !providers.isEmpty { watchOn(providers) }
            credits
        }
    }

    // bp-watch-on-row: provider marks, not a picker.
    private func watchOn(_ providers: [DetailModel.Extras.Provider]) -> some View {
        HStack(spacing: BP.px(8)) {
            Text("Watch on").font(BP.sans(11, .bold)).tracking(1).foregroundStyle(BP.inkSubtle)
            ForEach(providers.prefix(8)) { p in
                RemoteImage(url: p.logo, contentMode: .fit).frame(width: BP.px(28), height: BP.px(28)).clipShape(RoundedRectangle(cornerRadius: BP.px(6), style: .continuous))
                    .accessibilityLabel(p.name)
            }
        }
    }

    /// The rows under the hero (detail-spec §1.1 order): cast, collection, More Like This, You Might Also Like, facts.
    @ViewBuilder private var tmdbRows: some View {
        if !model.characters.isEmpty { charactersRow }
        if let a = model.awards, !a.groups.isEmpty { awardsRow(a) }
        if !model.isAnimeId, !SettingsBridge.shared.slice.tmdbKey.isEmpty { GalleryRow(meta: model.meta) }
        if let x = model.extras {
            if !x.cast.isEmpty { castRow(x.cast) }
            if let col = model.collectionRow { BPRowView(row: col, onFocus: { _ in }, onSelect: { related = $0 }) }
            if !x.recommendations.isEmpty { BPRowView(row: BrowseRow(key: "recommendations", title: "More Like This", metas: x.recommendations), onFocus: { _ in }, onSelect: { related = $0 }) }
            if !x.similar.isEmpty { BPRowView(row: BrowseRow(key: "similar", title: "You Might Also Like", metas: x.similar), onFocus: { _ in }, onSelect: { related = $0 }) }
            if let v = x.videos, !v.isEmpty { videosRow(v) }
            if !x.facts.isEmpty { factsCard(x.facts) }
        }
    }

    // detail/bp-videos-row: 16:9 YouTube thumbnails, kind over name; Select opens the trailer overlay.
    private func videosRow(_ clips: [DetailModel.Extras.Video]) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Videos").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.trackGap) {
                    ForEach(clips) { c in
                        Button { trailer = TrailerPick(ytId: c.ytId, name: c.name) } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                RemoteImage(url: "https://img.youtube.com/vi/\(c.ytId)/mqdefault.jpg")
                                    .frame(width: BP.px(300), height: BP.px(169)).clipped()
                                VStack(alignment: .leading, spacing: BP.px(3)) {
                                    Text(c.type).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(1.4).foregroundStyle(BP.inkSubtle).lineLimit(1)
                                    Text(c.name).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                }
                                .padding(BP.px(10)).frame(width: BP.px(300), alignment: .leading)
                            }
                            .background(BP.panel)
                            .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rMD))
                        .accessibilityLabel(c.name)
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    // detail/bp-awards-row: one cell per award body; Select opens the categories and years.
    private func awardsRow(_ a: DetailModel.TitleAwards) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Awards & Recognition").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.px(10)) {
                    ForEach(a.groups) { g in
                        Button { awardType = g } label: {
                            VStack(alignment: .leading, spacing: BP.px(4)) {
                                Text(g.title).font(BP.sans(14, .bold)).foregroundStyle(BP.ink).lineLimit(1)
                                Text(g.wins > 0 ? "\(g.wins) win\(g.wins == 1 ? "" : "s")" + (g.nominations > 0 ? " · \(g.nominations) nomination\(g.nominations == 1 ? "" : "s")" : "") : "\(g.nominations) nomination\(g.nominations == 1 ? "" : "s")")
                                    .font(BP.sans(12)).foregroundStyle(BP.inkMuted)
                            }
                            .padding(BP.px(14)).frame(width: BP.px(260), alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(10))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    // bp-anime-characters: AniList characters, distinct from the cast row.
    private var charactersRow: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Characters").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.trackGap) {
                    ForEach(model.characters.prefix(20)) { c in
                        VStack(spacing: BP.px(8)) {
                            RemoteImage(url: c.image).frame(width: BP.px(110), height: BP.px(110)).clipShape(Circle())
                            Text(c.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                            if let r = c.role, !r.isEmpty { Text(r.capitalized).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1) }
                        }
                        .frame(width: BP.px(130))
                        .focusable()
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    // bp-cast-row: round portraits, name over character, up to 20.
    private func castRow(_ cast: [DetailModel.Extras.Cast]) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Cast").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.trackGap) {
                    ForEach(cast) { person in
                        Button { self.person = person } label: {
                            VStack(spacing: BP.px(8)) {
                                ZStack {
                                    Circle().fill(BP.panel2)
                                    if let p = person.profile { RemoteImage(url: p).clipShape(Circle()) } else { Image(systemName: "person.fill").font(.system(size: BP.px(30))).foregroundStyle(BP.inkSubtle) }
                                }
                                .frame(width: BP.px(110), height: BP.px(110))
                                Text(person.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                Text(person.character).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                            }
                            .frame(width: BP.px(130))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.px(55)))
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    // bp-facts: a preview card of the first rows.
    private func factsCard(_ facts: [DetailModel.Extras.Fact]) -> some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            Text("Details").font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
            ForEach(facts.prefix(8)) { f in
                HStack(alignment: .top, spacing: BP.px(8)) {
                    Text(f.label).font(BP.sans(12, .bold)).foregroundStyle(BP.inkSubtle).frame(width: BP.px(120), alignment: .leading)
                    Text(f.value).font(BP.sans(12)).foregroundStyle(BP.inkMuted).lineLimit(2)
                }
            }
        }
        .padding(BP.px(16))
        .frame(maxWidth: BP.px(620), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
        .padding(.horizontal, BP.gutter)
        .focusable()
        // bp-facts-dialog: Select opens every row in a scrollable sheet.
        .onTapGesture { factsDialog = true }
        .onPlayPauseCommand { factsDialog = true }
    }

    /// Crew/cast lines from Cinemeta until TMDB cast cards arrive (detail-spec §1.1 rows 4-5).
    @ViewBuilder private var credits: some View {
        let director = (model.meta.director ?? []).filter { !$0.isEmpty }
        let cast = (model.meta.cast ?? []).filter { !$0.isEmpty }
        if let crew = model.extras?.crew, !crew.isEmpty {
            // bp-crew-row: each name is a cell into the Person page when TMDB knows the person.
            VStack(alignment: .leading, spacing: BP.px(6)) {
                ForEach(crew.prefix(5)) { c in
                    HStack(alignment: .top, spacing: BP.px(8)) {
                        Text(c.label).font(BP.sans(12, .bold)).foregroundStyle(BP.inkSubtle).frame(width: BP.px(80), alignment: .leading)
                        HStack(spacing: BP.px(6)) {
                            ForEach(Array((c.people ?? c.names.map { DetailModel.Extras.Crew.Person(id: nil, name: $0) }).enumerated()), id: \.offset) { _, p in
                                if let id = p.id {
                                    Button(p.name) { person = DetailModel.Extras.Cast(id: id, name: p.name, character: "", profile: nil) }.buttonStyle(BPActionStyle())
                                } else {
                                    Text(p.name).font(BP.sans(12)).foregroundStyle(BP.inkMuted)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: BP.px(760), alignment: .leading)
            .focusSection()
        } else if !director.isEmpty || !cast.isEmpty {
            VStack(alignment: .leading, spacing: BP.px(3)) {
                if !director.isEmpty { creditLine(model.isSeries ? "Created by" : "Directed by", director.prefix(3).joined(separator: ", ")) }
                if !cast.isEmpty { creditLine("Cast", cast.prefix(6).joined(separator: ", ")) }
            }
            .frame(maxWidth: BP.px(620), alignment: .leading)
        }
    }

    private func creditLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: BP.px(8)) {
            Text(T(label)).font(BP.sans(12, .bold)).foregroundStyle(BP.inkSubtle).frame(width: BP.px(80), alignment: .leading)
            Text(value).font(BP.sans(12)).foregroundStyle(BP.inkMuted).lineLimit(2)
        }
    }

    private var episodes: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            HStack(spacing: BP.px(8)) {
                ForEach(model.seasons.prefix(8), id: \.self) { s in
                    Button(s == 0 ? "Specials" : "Season \(s)") { model.season = s }
                        .buttonStyle(BPActionStyle(primary: model.season == s))
                }
                // bp-season-menu: long runs open the scrollable list instead of a chip wall.
                if model.seasons.count > 8 { Button("All \(model.seasons.count) seasons") { seasonsSheet = true }.buttonStyle(BPActionStyle()) }
            }
            .focusSection()
            ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: BP.trackGap) {
                    ForEach(model.seasonEpisodes) { ep in
                        // use-bp-detail play(ep, fromStrip): the strip fires like Play when instant play is on.
                        Button { pickerAuto = SettingsBridge.shared.slice.instantPlay ?? true; pickerPref = true; picker = (model.meta, ep.playEpisode) } label: {
                            EpisodeCell(episode: ep, watched: model.isWatched(ep), fact: model.fact(for: ep), chain: model.stillChain(for: ep), backdrop: model.meta.background,
                                        spoiler: model.spoilerMask(for: ep), showRating: model.showEpisodeRating, showDescription: model.showEpisodeDescription)
                        }
                            .buttonStyle(BPTileStyle())
                            // episode-watched-menu.tsx on hold-Select, plus use-mark-season's season toggle.
                            .contextMenu { episodeWatchedMenu(ep) }
                            .id(ep.id)
                            .accessibilityIdentifier("episode-\(ep.season)-\(ep.episode)")
                    }
                }
                .padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
            // use-bp-episode-strip: land on the resume episode when the strip first shows.
            .onChange(of: model.seasonEpisodes.count) { _, n in
                guard n > 0, let r = model.resume, r.season == model.season, let e = r.episode, let target = model.seasonEpisodes.first(where: { $0.episode == e }) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { withAnimation { proxy.scrollTo(target.id, anchor: .leading) } }
            }
            }
            .focusSection()
        }
    }

    /// components/episode-watched-menu.tsx: a watched episode offers "Mark as unwatched"; an
    /// unwatched one "Mark as watched" and "Mark watched up to here", plus "Mark as unwatched" once
    /// it has been started. The season item is episode-grid-controls OptionsMenu (use-mark-season).
    @ViewBuilder
    private func episodeWatchedMenu(_ ep: DetailModel.Episode) -> some View {
        if model.isWatched(ep) {
            Button { Task { await model.markWatched(ep, .episode, watched: false) } } label: { Label(T("Mark as unwatched"), systemImage: "eye.slash") }
        } else {
            Button { Task { await model.markWatched(ep, .episode, watched: true) } } label: { Label(T("Mark as watched"), systemImage: "checkmark") }
            Button { Task { await model.markWatched(ep, .upTo, watched: true) } } label: { Label(T("Mark watched up to here"), systemImage: "eye") }
            if model.isStarted(ep) {
                Button { Task { await model.markWatched(ep, .episode, watched: false) } } label: { Label(T("Mark as unwatched"), systemImage: "eye.slash") }
            }
        }
        if model.seasonAllWatched {
            Button { Task { await model.markWatched(ep, .season, watched: false) } } label: { Label(T("Mark season as unwatched"), systemImage: "eye.slash") }
        } else {
            Button { Task { await model.markWatched(ep, .season, watched: true) } } label: { Label(T("Mark season as watched"), systemImage: "checkmark.circle") }
        }
    }
}

/// bp-detail-actions BpSecondaryAction: a square icon cell, `on` face when active, edge border otherwise.
struct DetailIconActionStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .font(.system(size: BP.px(17), weight: .semibold))
                .foregroundStyle(BP.ink)
                .frame(width: BP.tabItem, height: BP.tabItem)
                .background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(active || focused ? BP.on : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).stroke(active ? Color.clear : BP.edge2, lineWidth: 1))
                .modifier(BPFocusModifier(focused: focused, pressed: configuration.isPressed, radius: BP.rXS, lift: 1.02))
        }
    }
}

/// bp-status-dialog.tsx: the tracker's statuses (the current one lit and ticked), Close, and
/// "Remove from list" when there is an entry. Select sets the status and closes.
struct TrackerDialogView: View {
    let tracker: DetailModel.Tracker
    let onPick: (String) -> Void
    let onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: String?

    var body: some View {
        ZStack {
            BP.void_.opacity(0.78).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(18)) {
                Text(tracker.name).font(BP.display(26)).foregroundStyle(BP.ink)
                VStack(alignment: .leading, spacing: BP.px(8)) {
                    ForEach(tracker.choices) { c in
                        Button { onPick(c.id); dismiss() } label: {
                            HStack {
                                Text(c.label)
                                Spacer()
                                if c.id == tracker.status { Image(systemName: "checkmark") }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(BPActionStyle(primary: c.id == tracker.status))
                        .focused($focus, equals: c.id)
                    }
                }
                .focusSection()
                HStack(spacing: BP.px(10)) {
                    Button("Close") { dismiss() }.buttonStyle(BPActionStyle())
                    if tracker.canRemove {
                        Button { onRemove(); dismiss() } label: { Label("Remove from list", systemImage: "trash") }.buttonStyle(BPActionStyle())
                    }
                }
                .focusSection()
            }
            .padding(BP.px(36))
            .frame(width: BP.px(760), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge2, lineWidth: 1))
        }
        .onExitCommand { dismiss() }
        .task {
            // Seed focus on the current status, else the first choice.
            try? await Task.sleep(for: .milliseconds(100))
            focus = tracker.status ?? tracker.choices.first?.id
        }
    }
}

/// bp-episode-still.tsx BpEpisodeStill: walks the still ladder and lands on the numbered plate
/// (the series backdrop dimmed behind the episode number) once every url has failed.
struct EpisodeStill: View {
    let chain: [String]
    let label: Int
    var backdrop: String?
    @State private var image: UIImage?
    @State private var exhausted = false

    var body: some View {
        ZStack {
            BP.panel2
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill).transition(.opacity)
            } else if exhausted {
                if let backdrop {
                    RemoteImage(url: backdrop).opacity(0.25).saturation(0.6)
                    BP.void_.opacity(0.6)
                }
                Text("\(label)").font(BP.display(40)).monospacedDigit().foregroundStyle(BP.ink).opacity(0.6)
            }
        }
        .task(id: chain.joined(separator: "|")) {
            image = nil
            exhausted = false
            for url in chain {
                guard let u = URL(string: url) else { continue }
                if let img = await ImageLoader.shared.image(for: u) {
                    withAnimation(BP.easeFast) { image = img }
                    return
                }
                if Task.isCancelled { return }
            }
            exhausted = true
        }
    }
}

struct EpisodeCell: View {
    let episode: DetailModel.Episode
    var watched = false
    var fact: DetailModel.EpisodeFact? = nil
    /// use-bp-episode-art ladder; nil draws the Cinemeta thumbnail alone.
    var chain: [String]? = nil
    var backdrop: String? = nil
    /// lib/spoilers.ts spoilerMaskFor for this card; nil shows everything.
    var spoiler: DetailModel.SpoilerMask? = nil
    /// bp-episode-card.tsx: settings.showEpisodeRating / showEpisodeDescription !== false.
    var showRating = true
    var showDescription = true
    /// The episode button's focus (the nearest focusable ancestor): bp-episode-still BP_SPOILER_THUMB /
    /// BP_SPOILER_TEXT lift the blur on focus, since a remote has no hover to reveal it.
    @Environment(\.isFocused) private var focused
    private static let size = CGSize(width: BP.px(230), height: (BP.px(230) * 9 / 16).rounded())

    private var hideThumb: Bool { spoiler?.thumb == true && !focused }
    private var hideTitle: Bool { spoiler?.title == true && !focused }
    private var hideDesc: Bool { spoiler?.desc == true && !focused }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            ZStack(alignment: .bottomLeading) {
                EpisodeStill(chain: chain ?? episode.thumbnail.map { [$0] } ?? [], label: episode.episode, backdrop: backdrop)
                    // BP_SPOILER_THUMB: blur-[16px] scale-[1.05], back to sharp on focus.
                    .blur(radius: hideThumb ? BP.px(16) : 0)
                    .scaleEffect(hideThumb ? 1.05 : 1)
                    .animation(BP.easeFast, value: hideThumb)
                LinearGradient(colors: [.clear, BP.void_.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                Text("E\(episode.episode)").font(BP.sans(12, .bold)).foregroundStyle(BP.ink).padding(BP.px(8))
                // use-bp-episode-facts chip: rating (IMDb mark when it is IMDb's) and runtime.
                if let f = fact, (f.rating != nil && showRating) || f.runtime != nil {
                    HStack(spacing: BP.px(4)) {
                        if let r = f.rating, showRating { Text((f.ratingIsImdb ? "IMDb " : "★ ") + String(format: "%.1f", r)) }
                        if let m = f.runtime { Text("\(m) min") }
                    }
                    .font(BP.sans(9.5, .bold)).foregroundStyle(BP.ink)
                    .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(3))
                    .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.void_.opacity(0.85)))
                    .padding(BP.px(8))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if watched {
                    Image(systemName: "checkmark").font(.system(size: BP.px(10), weight: .bold)).foregroundStyle(BP.canvas)
                        .frame(width: BP.px(21), height: BP.px(21)).background(Circle().fill(BP.ink))
                        .padding(BP.px(7)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                if let d = episode.released, d > Date() {
                    Text("Unaired").font(BP.sans(9.8, .bold)).textCase(.uppercase).foregroundStyle(BP.canvas)
                        .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2)).background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.ink))
                        .padding(BP.px(7)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
            Text(episode.title).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                .blur(radius: hideTitle ? BP.px(6) : 0)
                .animation(BP.easeFast, value: hideTitle)
            if let d = episode.released { Text(d.formatted(date: .abbreviated, time: .omitted)).font(BP.sans(11)).foregroundStyle(BP.inkSubtle) }
            // bp-episode-card.tsx: the overview, two lines, when showEpisodeDescription is on.
            if showDescription, let o = episode.overview, !o.isEmpty {
                Text(o).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).lineLimit(2).lineSpacing(2)
                    .blur(radius: hideDesc ? BP.px(6) : 0)
                    .animation(BP.easeFast, value: hideDesc)
            }
        }
        .frame(width: Self.size.width, alignment: .leading)
    }
}
