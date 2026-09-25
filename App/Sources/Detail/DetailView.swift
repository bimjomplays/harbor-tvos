import SwiftUI
import UIKit
import Combine

/// Detail page (bp-detail): hero with backdrop, logo/title, facts, actions, synopsis; then episodes.
struct DetailView: View {
    @StateObject private var model: DetailModel
    @State private var picker: (meta: Meta, episode: AnyJSON?)?
    /// use-bp-stream-play autoPlay: Play and auto-advance fire the best source; "Sources" never does.
    @State private var pickerAuto = false
    /// bp-detail.tsx onSources(…, applyPreference): the list was opened by Play (the hero, an
    /// episode, a Play handed over), so the Play button behavior setting applies to it.
    @State private var pickerPref = false
    /// view.ts picker frame `attempt`: how many times the player sent this title back to the picker
    /// (a stalled or failed auto pick, a stub); 0 for every picker the viewer opens.
    @State private var pickerAttempt = 0
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
    /// The season row: a Kitsu season button ("kitsu-<n>") or a TVDB chip ("chip-<key>").
    @FocusState private var seasonFocus: String?
    /// The episode card holding the ring, if any (the strip parks on the resume card only without it).
    @FocusState private var stripFocus: String?
    /// When a Kitsu season button last lost focus by vanishing (the TVDB chips replacing it).
    @State private var kitsuFocusLostAt: Date?
    @Environment(\.dismiss) private var dismiss
    /// (bug pass) Every fullScreenCover over this page (the picker, the player, a dialog) makes it
    /// disappear and re-appear, which re-runs `.task`. The reload is kept (resume and marks refresh
    /// after playback), but the hint season and autoPlay act once: an autoPlay page re-opened the
    /// picker (and instant play fired again) every time the player closed.
    @State private var didFirstLoad = false
    /// autoPlay opens the picker once, as soon as the page knows what Play would start
    /// (DetailModel.knowsPlayTarget), not after the whole page has loaded.
    @State private var autoPlayFired = false
    /// (detail/search pass 2) Something was played from this page: an episode hint (an AI search
    /// episode pick) is spent like a Continue Watching one (takeBpPlayIntent). Kept, it put Play back
    /// on the hinted episode from its start after an auto-advance had moved the resume point on,
    /// with the resume label and bar stood down (hintElsewhere).
    @State private var hintSpent = false
    /// (together pass 2) The page is on screen: any fullScreenCover over it (its own, or one a row
    /// presents, like the gallery's lightbox) makes it disappear. The room invite acts only then.
    @State private var onScreen = false
    /// (review 9 follow-up) The Watch Together invite to this page's own title while one is pending
    /// (TogetherModel incomingInvite naming this title), its 4 s countdown, and the last one spent here.
    @State private var ownInvite: TogetherModel.IncomingInvite?
    @State private var inviteShownAt: Date?
    @State private var inviteProgress: Double = 0
    @State private var handledInviteAt: Double?
    /// (review 9 follow-up) When the player over this page last closed, and on which episode: only
    /// then (within followWindowS) is the room's invite joined at once, with no second Back.
    @State private var playerClosed: ClosedPlay?
    /// The page's own view, to tell whether something (a context menu, an alert) is over it.
    @State private var pageProbe = DetailPageProbe()
    struct ClosedPlay { let at: Date; let season: Int?; let episode: Int? }
    struct OwnInviteKey: Equatable { let at: Double?; let onScreen: Bool }
    /// together-invite-toast.tsx AUTO_JOIN_MS.
    private static let inviteAutoJoinS = 4.0
    private static let followWindowS = 5.0

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
        // use-bp-detail-actions: always offered (Harbor's own watchlist needs no Stremio account).
        let saved = model.inWatchlist
        out.append(HeroAction(key: "watchlist", label: saved ? "In Watchlist" : "Add to Watchlist", icon: saved ? "checkmark" : "plus", active: saved) {
            guard !model.watchlistBusy else { return }
            Task { await model.toggleWatchlist() }
        })
        for tr in model.trackers {
            let label = tr.statusLabel.map { "\(tr.name) · \(T($0))" } ?? T("Add to %@", tr.name)
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
        out.append(HeroAction(key: "rate", label: score.map { T("Your rating %lld/10", $0) } ?? "Rate this", icon: score == nil ? "star" : "star.fill",
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
        out.append(HeroAction(key: "back", label: "Back", icon: "chevron.backward") { dismiss() })
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
        /// PlayerSrc autoFired / attempt / streamRef (views/player.tsx next-stream skip).
        var pick: PlayerPickInfo? = nil
        /// PlayerSrc.subtitles (use-pick-handler `subtitles: r.data.subtitles`): the stream's own subtitles.
        var subtitles: [SeedSubtitle] = []
    }

    /// Quick panel / Discovery Queue "Play now": open the picker as soon as the page knows what to play.
    var autoPlay = false
    /// Watch Together (together-invite-toast.tsx openPicker(meta, invite.episode, {autoPlay: !guestPick})):
    /// the episode the room is playing, and whether guests pick their own source.
    var roomEpisode: AnyJSON? = nil
    var roomPick = false
    /// views/detail.tsx episodeHint (an AI search episode pick, ai-result-list.tsx): the page opens
    /// on that season and Play starts that episode.
    var episodeHint: (season: Int, episode: Int)? = nil
    init(meta: Meta, autoPlay: Bool = false, roomEpisode: AnyJSON? = nil, roomPick: Bool = false, episodeHint: (season: Int, episode: Int)? = nil) {
        _model = StateObject(wrappedValue: DetailModel(meta: meta)); self.autoPlay = autoPlay
        self.roomEpisode = roomEpisode; self.roomPick = roomPick; self.episodeHint = episodeHint
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
        .background(DetailPageProbeView(probe: pageProbe))
        .ignoresSafeArea()
        // (review 9 follow-up) together-invite-toast.tsx for an invite to this title: see runOwnInvite.
        .overlay(alignment: .bottomLeading) {
            if let inv = ownInvite, inv.at != handledInviteAt, inviteShownAt != nil {
                TogetherInviteCard(invite: inv, progress: inviteProgress, onJoin: { joinOwnInvite(inv) },
                                   onDismiss: { dismissOwnInvite(inv) })
                    .padding(.leading, BP.gutter).padding(.bottom, BP.hintHeight + BP.px(16))
            }
        }
        .task {
            model.episodeHintSeason = roomEpisode?["season"]?.number.map { Int($0) } ?? episodeHint?.season
            // A Continue Watching one-press resume names its episode only for that one play (bp-detail
            // takeBpPlayIntent consumes the intent): once it fired, Play and the strip follow the resume
            // point again, not the episode the page was opened for (an auto-advance moved on from it).
            model.episodeHint = (autoPlayFired || hintSpent) ? nil : episodeHint
            let first = !didFirstLoad
            didFirstLoad = true
            await model.load()
            guard first else { return }
            if let h = episodeHint, model.seasons.contains(h.season) { model.season = h.season }
            // Normally fired already from the stage change below; this catches a load that
            // finished before the observer saw a stage.
            fireAutoPlayIfReady()
        }
        // bp-detail's pending-play effect: open playback once the meta and the episode are known;
        // awards, trackers, recommendations and the rest keep loading under the picker.
        .onChange(of: model.loadStage) { _, _ in fireAutoPlayIfReady() }
        // (together pass 2) A Watch Together invite to this title (the host moved on to the next
        // episode, or started it from here): see runOwnInvite.
        .onReceive(TogetherModel.shared.$view.map(\.incomingInvite).removeDuplicates()) { inv in
            var mine: TogetherModel.IncomingInvite? = nil
            if let i = inv, i.invite.mediaId == model.meta.id { mine = i }
            if ownInvite != mine { ownInvite = mine }
        }
        // Keyed by the invite and by the page being on screen: a cover over the page stops the
        // countdown, and the page coming back (the player closing) starts it again.
        .task(id: OwnInviteKey(at: ownInvite?.at, onScreen: onScreen)) { await runOwnInvite() }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false; hideOwnInvite() }
        // A Watch Together host who closed the player to reopen (Sources, Switch source, another
        // episode, a send-back) and leaves the picker with no pick has left the video (TogetherModel.abandonReopen).
        .fullScreenCover(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } }), onDismiss: { pickerAttempt = 0; TogetherModel.shared.abandonReopen() }) {
            if let picker {
                PlayPickerView(meta: picker.meta, episode: picker.episode, onPlay: { stream, resolved in
                    guard let link = resolved.data, let url = PlayableURL.make(link.url) else { return }   // (bug pass 2) the picker checked it
                    let ep = picker.episode
                    let sub = ep.flatMap { e -> String? in
                        guard let s = e["season"]?.number, let n = e["episode"]?.number else { return nil }
                        return "S\(Int(s)) E\(Int(n))" + (e["name"]?.string.map { " · \($0)" } ?? "")
                    }
                    // A pick: the player follows, so the picker's dismissal is not a host leaving.
                    TogetherModel.shared.setReopenPending(false)
                    self.picker = nil
                    let pick = PlayerPickInfo(autoPicked: resolved.autoPicked ?? false, attempt: pickerAttempt, streamRef: resolved.streamRef)
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
                            // views/player.tsx nextEpMask: a hidden title leaves only "S E" on the up-next card.
                            if let s = ctx.season, let e = ctx.episode, let n = model.airedNext(season: s, episode: e) {
                                upNext = await model.upNextText(n)
                            }
                            let hints = PlayerStreamHints(notWebReady: link.notWebReady, container: stream?.container,
                                                          hdrFormat: stream?.hdrFormat, filename: link.filename)
                            playing = PlayTarget(url: url, headers: link.headers ?? [:], title: model.meta.name, subtitle: sub, context: ctx, upNext: upNext, episode: ep, hints: hints, pick: pick,
                                                 subtitles: link.subtitles ?? [])
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
            SeasonsSheet(seasons: model.seasons, counts: Dictionary(grouping: model.episodes, by: \.season).mapValues(\.count), season: Binding(get: { model.season }, set: { model.pickKitsuSeason($0) }))
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
                         onPreviousEpisode: previousEpisodeAction(t.context), pick: t.pick,
                         onPickAgain: { auto in
                             // views/player.tsx openPicker(meta, episode, { autoPlay: true, attempt: attempt + 1 }).
                             pickerAuto = auto; pickerPref = false
                             let next = (t.pick?.attempt ?? 0) + 1
                             DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { pickerAttempt = next; picker = (model.meta, t.episode) }
                         }, streamSubtitles: t.subtitles) { natural in
                playerClosed = ClosedPlay(at: Date(), season: t.context.season, episode: t.context.episode)
                playing = nil
                hintSpent = true
                model.episodeHint = nil
                // The strip's started / next-up (and so its spoiler masks) move with what was just played.
                Task { await model.loadWatchedState() }
                // Auto-advance (player-spec §1.9, simplified): a finished episode opens the next one's picker.
                if natural, let s = t.context.season, let e = t.context.episode, let next = model.airedNext(season: s, episode: e) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        // (review 9) The room invite follow runs on the same return: a room's invite
                        // to the next episode may have opened the picker already (with the room's
                        // guest-pick rule), and this replaced its episode and autoplay under it.
                        guard picker == nil else { return }
                        // (review 9 follow-up) Or it is about to (it waits for the cover to go, then
                        // 0.4 s): the room's invite to this title wins over the local next episode.
                        guard !roomInviteToFollow() else { return }
                        pickerAuto = SettingsBridge.shared.slice.instantPlay ?? true; pickerPref = false; picker = (model.meta, next.playEpisode)
                    }
                }
            }
        }
    }

    /// autoPlay (quick panel / queue "Play", a Continue Watching resume, a Watch Together room):
    /// opens the picker once, the first time the page knows what Play starts. A failed load still
    /// ends in a stage, so it behaves as before (picker over the page it could show).
    private func fireAutoPlayIfReady() {
        guard autoPlay, !autoPlayFired, model.knowsPlayTarget(roomEpisode: roomEpisode != nil) else { return }
        autoPlayFired = true
        // The play request is spent (takeBpPlayIntent): the hint goes once the picker has its episode.
        defer { model.episodeHint = nil }
        // A picker the viewer already opened by hand wins; the autoplay is spent either way.
        guard picker == nil else { return }
        if let h = episodeHint, model.seasons.contains(h.season) { model.season = h.season }
        pickerAuto = roomPick ? false : (SettingsBridge.shared.slice.instantPlay ?? true)
        pickerPref = !roomPick
        if let re = roomEpisode, let s = re["season"]?.number, let e = re["episode"]?.number {
            picker = (model.meta, model.episodes.first(where: { $0.season == Int(s) && $0.episode == Int(e) })?.playEpisode ?? re)
        } else if model.isSeries { picker = (model.meta, model.playTarget?.playEpisode ?? model.premiereEpisode) } else { picker = (model.meta, nil) }
    }

    /// (together pass 2, review 9 follow-up) together-invite-toast.tsx: a 4 s toast with Join and
    /// Dismiss, joined with openPicker(meta, invite.episode, {autoPlay: !guestPick}). The shell's
    /// toast waits while anything covers the shell, and this page is a cover, so an invite to this
    /// page's own title shows here instead, over the page (TogetherInviteCard, the same 4 s). It is
    /// joined at once only when the page is coming back from its player (within followWindowS of
    /// the player closing): the host moved on to the next episode, and the guest needs no second
    /// Back. Pass 2 joined every invite to this title at once, so a guest reading the page (or the
    /// relay's repeat invite on a join or a reconnect) got the picker with no Dismiss. The first
    /// look waits 0.4 s after the page came back (a present while a cover is going is dropped).
    private func runOwnInvite() async {
        hideOwnInvite()
        guard ownInvite != nil, onScreen else { return }
        try? await Task.sleep(nanoseconds: 400_000_000)
        while !Task.isCancelled {
            guard tickOwnInvite() else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// One look at the invite: false once it is spent (joined, dismissed, dropped or gone).
    private func tickOwnInvite() -> Bool {
        guard let inv = ownInvite, inv.at != handledInviteAt else {
            hideOwnInvite()
            return false
        }
        let room = TogetherModel.shared
        let pending: Bool = room.view.inSession && room.view.incomingInvite?.at == inv.at
        guard pending else {
            hideOwnInvite()
            return true
        }
        let now = Date()
        var justClosed: ClosedPlay? = nil
        if let c = playerClosed, now.timeIntervalSince(c.at) < Self.followWindowS { justClosed = c }
        // The relay's repeat invite (someone joined, a reconnect) to the video the player over this
        // page was just showing: the player drops those while it is up (TogetherPlayback), and one
        // that landed while it was closing reopened the same episode here.
        if let c = justClosed, Self.invites(inv.invite, sameVideoAs: c) {
            dismissOwnInvite(inv)
            return false
        }
        guard !ownInviteHeld() else {
            hideOwnInvite()
            return true
        }
        if justClosed != nil {
            joinOwnInvite(inv)
            return false
        }
        let start: Date = inviteShownAt ?? now
        if inviteShownAt == nil { inviteShownAt = start }
        inviteProgress = min(1, now.timeIntervalSince(start) / Self.inviteAutoJoinS)
        if inviteProgress >= 1 {
            joinOwnInvite(inv)
            return false
        }
        return true
    }

    /// The invite waits (and its countdown restarts afterwards, as the shell's toast does under a
    /// cover) while the viewer has something else up: a cover over the page or one about to
    /// present, the screensaver or the curfew lock, a context menu (an episode's hold-Select menu)
    /// or an alert over the page, or this page's own room autoplay still to open its picker.
    private func ownInviteHeld() -> Bool {
        if !onScreen || ShellOverlay.shared.keyWindow != nil { return true }
        if picker != nil || playing != nil || related != nil || trailer != nil || person != nil { return true }
        if awardType != nil || trackerDialog != nil { return true }
        if listDialog || factsDialog || seasonsSheet || rateDialog { return true }
        if autoPlay && !autoPlayFired { return true }
        return pageProbe.somethingOver()
    }

    private func joinOwnInvite(_ inv: TogetherModel.IncomingInvite) {
        handledInviteAt = inv.at
        hideOwnInvite()
        playerClosed = nil
        TogetherModel.shared.dismiss("invite")
        guard picker == nil else { return }
        let guestPick: Bool = inv.invite.guestPick == true
        pickerAuto = guestPick ? false : (SettingsBridge.shared.slice.instantPlay ?? true)
        pickerPref = !guestPick
        pickerAttempt = 0
        switchFromSec = nil
        var episode: AnyJSON? = inv.invite.episode
        if let ref = inv.invite.episodeRef, let hit = model.episodes.first(where: { $0.season == ref.season && $0.episode == ref.episode }) {
            episode = hit.playEpisode
        }
        picker = (model.meta, episode)
    }

    private func dismissOwnInvite(_ inv: TogetherModel.IncomingInvite) {
        handledInviteAt = inv.at
        hideOwnInvite()
        TogetherModel.shared.dismiss("invite")
    }

    private func hideOwnInvite() {
        if inviteShownAt != nil { inviteShownAt = nil }
        if inviteProgress != 0 { inviteProgress = 0 }
    }

    /// A room invite to this title that the page will join or show (auto-advance leaves the next
    /// episode to it): not one to the video that just closed, which is dropped.
    private func roomInviteToFollow() -> Bool {
        guard TogetherModel.shared.view.inSession, let inv = ownInvite, inv.at != handledInviteAt else { return false }
        guard let c = playerClosed else { return true }
        return !Self.invites(inv.invite, sameVideoAs: c)
    }

    /// TogetherPlayback.showsInvited for the player that closed (the invite already names this title).
    private static func invites(_ i: TogetherModel.PlayInvite, sameVideoAs c: ClosedPlay) -> Bool {
        if let ep = i.episodeRef {
            guard let s = c.season, let e = c.episode else { return false }
            return ep.season == s && ep.episode == e
        }
        return c.season == nil || c.episode == nil
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
                // bp-tokens.ts --bp-scrim-side: the side scrim runs from the start edge (260deg under rtl).
                .flipsForRightToLeftLayoutDirection(true)
        }
        .ignoresSafeArea()
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            if let logo = model.meta.logo, !logo.isEmpty {
                RemoteImage(url: logo, contentMode: .fit).frame(maxWidth: BP.px(380), maxHeight: BP.px(140), alignment: .leading)
                    // The title logo is the page's heading: VoiceOver reads the name it draws.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: model.meta.name))
                    .accessibilityAddTraits(.isHeader)
            } else {
                Text(model.meta.name).font(BP.display(52)).foregroundStyle(BP.ink).lineLimit(2).frame(maxWidth: BP.px(700), alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
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
                    if model.isSeries { picker = (model.meta, model.playTarget?.playEpisode ?? model.premiereEpisode) }
                    else { picker = (model.meta, nil) }
                } label: {
                    VStack(spacing: 0) {
                        Label(model.playLabel, systemImage: "play.fill")
                        // Progress under Play, only mid-way through (0.01 < progress < 0.97).
                        // Hidden when an AI search episode pick names another episode (it plays from its start),
                        // or an anime's next-up is the target instead of the local resume point.
                        if let r = model.resume, model.resumeIsPlayTarget, r.progress > 0.01, r.progress < 0.97 {
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
                // The resume bar under Play, read as "{n}% watched" when it is drawn.
                .bpProgressValue(model.resumeIsPlayTarget ? model.resume?.progress : nil)
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
                    .accessibilityLabel(T(a.label))
                    .bpSelected(a.active)
                    .accessibilityIdentifier("detail-action-\(a.key)")
                }
            }
            .focusSection()
            // BP_ACTION_HINT: the focused icon's label; blank when Play or nothing in the row has focus.
            Text(heroActions.first(where: { $0.key == heroFocus }).map { T($0.label) } ?? " ")
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
                    .accessibilityElement(children: .ignore)
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
            if !x.recommendations.isEmpty { BPRowView(row: BrowseRow(key: "recommendations", title: T("More Like This"), metas: x.recommendations), onFocus: { _ in }, onSelect: { related = $0 }) }
            if !x.similar.isEmpty { BPRowView(row: BrowseRow(key: "similar", title: T("You Might Also Like"), metas: x.similar), onFocus: { _ in }, onSelect: { related = $0 }) }
            if let v = x.videos, !v.isEmpty { videosRow(v) }
            if !x.facts.isEmpty { factsCard(x.facts) }
        }
    }

    // detail/bp-videos-row: 16:9 YouTube thumbnails, kind over name; Select opens the trailer overlay.
    private func videosRow(_ clips: [DetailModel.Extras.Video]) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Videos").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.trackGap) {
                    ForEach(clips) { c in
                        Button { trailer = TrailerPick(ytId: c.ytId, name: c.name) } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                RemoteImage(url: "https://img.youtube.com/vi/\(c.ytId)/mqdefault.jpg")
                                    .frame(width: BP.px(300), height: BP.px(169)).clipped()
                                VStack(alignment: .leading, spacing: BP.px(3)) {
                                    Text(T(c.type)).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(1.4).foregroundStyle(BP.inkSubtle).lineLimit(1)
                                    // bp-videos-row.tsx: the engine's unnamed extra trailers are t("Trailer").
                                    Text(c.name == "Trailer" ? T("Trailer") : c.name).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
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

    /// bp-awards-row.tsx t("{n} wins") / t("{n} nominations"), with the nominations beside a win.
    private func awardCounts(_ g: DetailModel.TitleAwards.Group) -> String {
        let noms = TCount(g.nominations, one: "%lld nomination", "%lld nominations")
        guard g.wins > 0 else { return noms }
        let wins = TCount(g.wins, one: "%lld win", "%lld wins")
        return g.nominations > 0 ? "\(wins) · \(noms)" : wins
    }

    // detail/bp-awards-row: one cell per award body; Select opens the categories and years.
    private func awardsRow(_ a: DetailModel.TitleAwards) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Awards & Recognition").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.px(10)) {
                    ForEach(a.groups) { g in
                        Button { awardType = g } label: {
                            VStack(alignment: .leading, spacing: BP.px(4)) {
                                Text(g.title).font(BP.sans(14, .bold)).foregroundStyle(BP.ink).lineLimit(1)
                                Text(awardCounts(g))
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
            Text("Characters").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.trackGap) {
                    ForEach(model.characters.prefix(20)) { c in
                        // (detail pass) A tile like the cast row's: the bare .focusable() cell took focus
                        // with no ring. Upstream's Select favourites the character; that store is not ported.
                        Button { } label: {
                            VStack(spacing: BP.px(8)) {
                                RemoteImage(url: c.image).frame(width: BP.px(110), height: BP.px(110)).clipShape(Circle())
                                Text(c.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                if let r = c.role, !r.isEmpty { Text(r.capitalized).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1) }
                            }
                            .frame(width: BP.px(130))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.px(55)))
                        // bp-anime-characters.tsx aria-label `${character.name}, ${role}`: one focus stop reads both.
                        .accessibilityElement(children: .combine)
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
            Text("Cast").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.trackGap) {
                    // (bug pass) TMDB lists an actor once per role (same person id): unique ids for ForEach.
                    ForEach(cast.uniquedById()) { person in
                        Button { self.person = person } label: {
                            VStack(spacing: BP.px(8)) {
                                ZStack {
                                    Circle().fill(BP.panel2)
                                    if let p = person.profile { RemoteImage(url: p).clipShape(Circle()) } else { Image(systemName: "person.fill").font(.system(size: BP.px(30))).foregroundStyle(BP.inkSubtle).accessibilityHidden(true) }
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
    // (detail pass) A Button like bp-facts.tsx's: the bare .focusable() card took focus with no
    // ring, so the viewer lost track of the focus at the bottom of the page.
    private func factsCard(_ facts: [DetailModel.Extras.Fact]) -> some View {
        Button { factsDialog = true } label: {
            VStack(alignment: .leading, spacing: BP.px(6)) {
                Text("Details").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).accessibilityAddTraits(.isHeader)
                ForEach(facts.prefix(8)) { f in
                    HStack(alignment: .top, spacing: BP.px(8)) {
                        Text(T(f.label)).font(BP.sans(12, .bold)).foregroundStyle(BP.inkSubtle).frame(width: BP.px(120), alignment: .leading)
                        Text(f.value).font(BP.sans(12)).foregroundStyle(BP.inkMuted).lineLimit(2)
                    }
                }
            }
            .padding(BP.px(16))
            .frame(maxWidth: BP.px(620), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
        }
        // bp-facts-dialog: Select opens every row in a scrollable sheet.
        .buttonStyle(BPTileStyle(radius: BP.rSM))
        .padding(.horizontal, BP.gutter)
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
                        Text(T(c.label)).font(BP.sans(12, .bold)).foregroundStyle(BP.inkSubtle).frame(width: BP.px(80), alignment: .leading)
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

    /// The season buttons: the first eight, plus the season on screen when it sits past them (a
    /// resume in season 12, or a pick from the list). (detail pass) Without it no button read as
    /// selected while the strip showed that season (bp-season-menu's trigger names the active one).
    private var seasonChips: [Int] {
        var out = Array(model.seasons.prefix(8))
        if model.seasons.contains(model.season), !out.contains(model.season) { out.append(model.season) }
        return out
    }

    /// What the strip parks on: its first card and count, and the hinted / resume episode.
    private var stripParkKey: String {
        let strip = model.seasonEpisodes
        var key = "\(strip.first?.id ?? ""):\(strip.count)"
        if let t = model.stripTarget { key += ":\(t.season):\(t.episode)" }
        return key
    }

    private var episodes: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            if model.metaFailed, model.episodes.isEmpty {
                // (detail/search pass 2) bp-detail's BpPageMessage when the title can't be read.
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    BPNote(text: "Couldn't load this title.")
                    Button("Try again") { Task { await model.load() } }.buttonStyle(BPActionStyle())
                }
                .focusSection()
            }
            if model.animeSeasonKey != nil {
                animeSeasonChips
            } else {
                HStack(spacing: BP.px(8)) {
                    ForEach(seasonChips, id: \.self) { s in
                        Button(s == 0 ? "Specials" : "Season \(s)") { model.pickKitsuSeason(s) }
                            .buttonStyle(BPActionStyle(primary: model.season == s))
                            .bpSelected(model.season == s)
                            .focused($seasonFocus, equals: "kitsu-\(s)")
                    }
                    // bp-season-menu: long runs open the scrollable list instead of a chip wall.
                    if model.seasons.count > 8 {
                        Button("All \(model.seasons.count) seasons") { seasonsSheet = true }.buttonStyle(BPActionStyle())
                            .focused($seasonFocus, equals: "kitsu-all")
                    }
                }
                .focusSection()
            }
            ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: BP.trackGap) {
                    ForEach(model.seasonEpisodes) { ep in
                        // use-bp-detail play(ep, fromStrip): the strip fires like Play when instant play is on.
                        Button { pickerAuto = SettingsBridge.shared.slice.instantPlay ?? true; pickerPref = true; picker = (model.meta, ep.playEpisode) } label: {
                            EpisodeCell(episode: ep, watched: model.isWatched(ep), fact: model.fact(for: ep), chain: model.stillChain(for: ep), backdrop: model.meta.background,
                                        spoiler: model.spoilerMask(for: ep), showRating: model.showEpisodeRating, showDescription: model.showEpisodeDescription,
                                        progress: model.progress(for: ep))
                        }
                            .buttonStyle(BPTileStyle())
                            .focused($stripFocus, equals: ep.id)
                            .bpProgressValue(model.progress(for: ep))
                            // episode-watched-menu.tsx on hold-Select, plus use-mark-season's season toggle.
                            .contextMenu { episodeWatchedMenu(ep) }
                            .id(ep.id)
                            .accessibilityIdentifier("episode-\(ep.season)-\(ep.episode)")
                    }
                }
                .padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
            // use-bp-episode-strip: land on the hinted (AI search pick) or resume episode when the strip first shows.
            // Keyed by the strip's first card too: the hint's season can replace the resume season with the same count.
            // (detail pass) And by the target itself: the resume point is read after the episodes are in,
            // so a resume in the season already on screen (every one-season show) never parked the strip.
            // useBpParkedTrack: never while the ring is in the strip (the viewer's own spot wins).
            .onChange(of: stripParkKey) { _, _ in
                guard stripFocus == nil else { return }
                // An anime chip can hold several Kitsu seasons, so the card is found by its own pair.
                let strip = model.seasonEpisodes
                guard let firstCard = strip.first else { return }
                let s = model.stripTarget?.season, e = model.stripTarget?.episode
                let target: DetailModel.Episode? = strip.first(where: { $0.season == s && $0.episode == e })
                // (detail/search pass 2) A season without the target opens at its first card: the
                // strip kept the last season's scroll, so after scrolling to E20 of one season the
                // next opened on its late episodes (or blank space past a short season's end).
                let id: String = (target ?? firstCard).id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { withAnimation { proxy.scrollTo(id, anchor: .leading) } }
            }
            }
            .focusSection()
        }
        // Review 31: the TVDB chips replace the Kitsu season buttons under the viewer's focus. The
        // focused button vanishes first (focus falls to nil), so a loss in the last moment counts too;
        // focus lands on the chip that opened (seeded from the viewer's Kitsu pick) and stays in the row.
        .onChange(of: seasonFocus) { old, new in
            if new == nil, old?.hasPrefix("kitsu-") == true { kitsuFocusLostAt = Date() }
        }
        .onChange(of: model.animeSeasonKey) { old, new in
            guard old == nil, let new, model.animeHasChips, model.animeChips.count > 1 else { return }
            let wasOnKitsu = seasonFocus?.hasPrefix("kitsu-") == true
                || (kitsuFocusLostAt.map { Date().timeIntervalSince($0) < 0.1 } ?? false)   // the same update, not a move away (review 35)
            kitsuFocusLostAt = nil
            guard wasOnKitsu else { return }
            DispatchQueue.main.async { seasonFocus = "chip-\(new)" }
        }
    }

    /// bp-anime-seasons.tsx BpAnimeSeasonChips: the Episodes heading, then named season chips (year
    /// span and episode count under the name; specials and extras last behind a divider) and the
    /// TVDB order toggle on one track, so the strip stays one D-pad step below.
    private var animeSeasonChips: some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            // BpEpisodesHeading: "Episodes" and the strip's count.
            HStack(alignment: .firstTextBaseline, spacing: BP.px(10)) {
                Text(T("Episodes")).font(BP.sans(16, .bold)).foregroundStyle(BP.ink)
                let n = model.seasonEpisodes.count
                if n > 0 { Text(T("%lld episodes", n)).font(BP.sans(12, .semibold)).monospacedDigit().foregroundStyle(BP.inkSubtle) }
            }
            if model.animeHasChips {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BP.px(6)) {
                        let hasSeasons = model.animeChips.count > 1
                        let hasOrders = model.animeOrders.count > 1
                        if hasSeasons {
                            ForEach(model.animeChips) { c in
                                if c.divider { AnimeChipDivider() }
                                Button { model.selectAnimeSeason(c.key) } label: { AnimeSeasonChipLabel(chip: c, selected: c.key == model.animeSeasonKey) }
                                    .buttonStyle(AnimeSeasonChipStyle(selected: c.key == model.animeSeasonKey))
                                    .focused($seasonFocus, equals: "chip-\(c.key)")
                                    .accessibilityIdentifier("anime-season-\(c.key)")
                                    .bpSelected(c.key == model.animeSeasonKey)
                            }
                        }
                        if hasSeasons && hasOrders { AnimeChipDivider() }
                        if hasOrders {
                            Text(T("Order")).font(BP.sans(11, .bold)).textCase(.uppercase).tracking(BP.px(1.5)).foregroundStyle(BP.inkSubtle)
                                .padding(.trailing, BP.px(2))
                            ForEach(model.animeOrders) { o in
                                Button(o.short) { Task { await model.setAnimeOrder(o.value) } }
                                    .buttonStyle(PlayerChipStyle(on: o.value == model.animeOrderType))
                                    .accessibilityIdentifier("anime-order-\(o.value)")
                                    .bpSelected(o.value == model.animeOrderType)
                            }
                        }
                    }
                    .padding(.vertical, BP.px(14))
                }
                .scrollClipDisabled()
                .focusSection()
            }
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
                                Text(T(c.label))
                                Spacer()
                                if c.id == tracker.status { Image(systemName: "checkmark").accessibilityHidden(true) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(BPActionStyle(primary: c.id == tracker.status)).bpSelected(c.id == tracker.status)
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
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill).transition(.opacity).accessibilityHidden(true)
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

/// bp-anime-season-chip.tsx BpAnimeSeasonChip: BpChip's pill one line taller, the season's name
/// (and an OVA / Movie / Special badge when one comes) over its years and episode count.
struct AnimeSeasonChipLabel: View {
    let chip: DetailModel.AnimeSeasonChip
    let selected: Bool
    /// The chip button's focus: group-data-[bp-focus=true] turns both lines to the canvas colour.
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(1)) {
            HStack(spacing: BP.px(4)) {
                Text(chip.name).font(BP.sans(14, .semibold)).lineLimit(1).frame(maxWidth: BP.px(250), alignment: .leading)
                if let badge = chip.badge, !badge.isEmpty {
                    Text(badge).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(BP.px(1.2))
                        .padding(.horizontal, BP.px(5)).padding(.vertical, BP.px(1))
                        .background(Capsule().fill(BP.void_.opacity(focused ? 0.25 : 0.45)))
                }
            }
            .foregroundStyle(focused ? BP.canvas : (selected ? BP.ink : BP.inkSubtle))
            if !chip.meta.isEmpty {
                Text(chip.meta).font(BP.sans(12, .medium)).monospacedDigit().lineLimit(1)
                    .foregroundStyle(focused ? BP.canvas : BP.inkMuted)
            }
        }
        .padding(.horizontal, BP.px(13))
        .padding(.vertical, BP.px(5))
        .frame(minHeight: BP.px(43))
    }
}

/// BpAnimeSeasonChip faces: the picked season sits on the void, the rest are an edge hairline; focus floods ink.
struct AnimeSeasonChipStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(focused ? BP.ink : (selected ? BP.void_.opacity(0.72) : Color.clear)))
                .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(selected || focused ? Color.clear : BP.edge, lineWidth: 1))
                .modifier(BPFocusModifier(focused: focused, pressed: configuration.isPressed, radius: BP.rLG, lift: 1.02))
        }
    }
}

/// bp-library-chips.tsx BpChipDivider: a hairline between chip groups.
struct AnimeChipDivider: View {
    var body: some View {
        Rectangle().fill(BP.edge2).frame(width: 1, height: BP.px(26)).padding(.horizontal, BP.px(4))
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
    /// bp-episode-card.tsx progress: the resume episode's bar along the still's bottom edge (0.01–0.97).
    var progress: Double = 0
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
                Text(episode.tag ?? "E\(episode.episode)").font(BP.sans(12, .bold)).foregroundStyle(BP.ink).padding(BP.px(8))
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
                        .accessibilityLabel(Text(T("Watched")))
                        .frame(width: BP.px(21), height: BP.px(21)).background(Circle().fill(BP.ink))
                        .padding(BP.px(7)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                if let d = episode.released, d > Date() {
                    Text("Unaired").font(BP.sans(9.8, .bold)).textCase(.uppercase).foregroundStyle(BP.canvas)
                        .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2)).background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.ink))
                        .padding(BP.px(7)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                // (detail pass) The strip never showed where the viewer stopped inside an episode.
                if progress > 0.01, progress < 0.97 {
                    ZStack(alignment: .leading) {
                        BP.void_.opacity(0.6)
                        BP.accent.frame(width: Self.size.width * progress)
                    }
                    .frame(width: Self.size.width, height: BP.px(3))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .accessibilityHidden(true)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
            Text(episode.title).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                .blur(radius: hideTitle ? BP.px(6) : 0)
                .animation(BP.easeFast, value: hideTitle)
            // bp-anime-seasons.tsx facts: "Abs E{n}" (absolute order renumbers the run) · the air date.
            let facts = [episode.absoluteLabel, episode.released.map { $0.formatted(date: .abbreviated, time: .omitted) }].compactMap { $0 }
            if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(BP.sans(11)).monospacedDigit().foregroundStyle(BP.inkSubtle).lineLimit(1) }
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

/// (review 9 follow-up) Where a Detail page's views live, so its room invite can tell whether the
/// viewer has something up over the page that is not one of the page's own covers: a context menu
/// (the episode strip's hold-Select menu), an alert, or the focus somewhere outside the page.
final class DetailPageProbe {
    weak var view: UIView?

    @MainActor func somethingOver() -> Bool {
        guard let v = view, let window = v.window else { return true }
        var responder: UIResponder? = v
        var owner: UIViewController?
        while let next = responder?.next {
            if let vc = next as? UIViewController {
                owner = vc
                break
            }
            responder = next
        }
        guard var host = owner else { return false }
        while let parent = host.parent { host = parent }
        // (open-items sweep) The page is going (Back, Menu): a 4 s that ran out now joined onto a page
        // whose picker can never present, and spent the invite. It waits; once the page is gone the
        // shell's toast takes it.
        if host.isBeingDismissed { return true }
        if host.presentedViewController != nil { return true }
        let focused: UIView? = UIFocusSystem.focusSystem(for: window)?.focusedItem as? UIView
        guard let focused else { return false }
        return !focused.isDescendant(of: host.view)
    }
}

private struct DetailPageProbeView: UIViewRepresentable {
    let probe: DetailPageProbe

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        probe.view = v
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if probe.view !== uiView { probe.view = uiView }
    }
}
