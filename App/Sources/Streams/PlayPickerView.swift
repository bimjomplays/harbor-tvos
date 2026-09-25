import SwiftUI

/// Stream picker: the ranked list grouped by quality tier, best cached pick first.
struct PlayPickerView: View {
    let meta: Meta
    let episode: AnyJSON?
    let onPlay: (ScoredStream?, StreamsModel.Resolved) -> Void
    /// use-bp-stream-play autoPlay: fire the best candidate once the pipeline settles (instantPlay).
    var autoPlay = false
    /// bp-streams.tsx applyPreference: this list opened from Play (not Sources or Switch source), so
    /// settings.playbackSourcePreference applies: only "online" fires on its own, and a home-server
    /// preference opens on the Media servers list and plays the preferred server's copy.
    var applyPreference = false
    /// (P8) bp-player-sources.tsx BpPlayerSources → `<BpStreams mode="switch">`: this list drawn in
    /// the player as a card over the running film (PlayerSourcesPanel), with the stream playing now
    /// first and marked "Now playing". nil is the picker. No home-server copies here (bp-streams
    /// `homeServerCopies = switching ? []`), no instant play, no source preference.
    var switching: PlayerSourcesPanel.Current? = nil
    /// The switcher's onClose (the player's closePanel); the picker dismisses its own cover instead.
    var onClose: (() -> Void)? = nil
    @StateObject private var model = StreamsModel()
    /// bp-stream-chips BpSourceKind, the kinds the TV has: "all", "media-server" or "online" (the
    /// source chip's Direct/debrid only and P2P only; no Local Library on a TV).
    @State private var sourceKind = "all"
    /// bp-stream-filters langFilter: the preferred-language chip, first set from
    /// requirePreferredLanguage once the engine has said which languages those are (model.setup).
    @State private var langFilter = false
    @State private var langSeeded = false
    /// bp-streams preferredSourceFired: the preference acts once per opening.
    @State private var preferenceFired = false
    /// The viewer picked a row by hand (the preference no longer auto-plays over it).
    @State private var handPicked = false
    @State private var autoState: AutoState = .off
    @State private var autoTried = 0
    @State private var startedAt = Date()
    @State private var firstResultAt: Date?
    enum AutoState: Equatable { case off, waiting, firing(String), cancelled, exhausted }
    @State private var resolving: String?
    @State private var resolveError: String?
    @State private var quality: String = "All"
    @State private var cachedOnly = false
    @State private var addonFilter: String?
    /// bp-stream-dialogs: the one dialog over the picker (P2P consent, debrid down, no sources, auto exhausted).
    @State private var dialog: PickerDialog?
    /// use-pick-handler debridFailStreak: two debrid-side failures in a row → "Debrid is down".
    @State private var debridFailStreak = 0
    /// use-bp-stream-play failedStreams: rows that already failed read "Unavailable, try another."
    @State private var failedIds: Set<String> = []
    @State private var alive = true
    /// play-picker.tsx stubBanner / auto-play-transition.tsx stubNotice: the player just sent a stub
    /// back (use-stub-detection.ts recordStubEvent), shown for 6 s.
    @State private var stubNotice = false
    /// (bug pass) A dialog's fullScreenCover makes this view disappear and re-appear: `.task` runs
    /// again (a second search cleared the list under the dialog) and onDisappear cancelled the
    /// search and set `alive = false`, so the P2P dialog's "Stream" resolved and then dropped the pick.
    @State private var searched = false
    @Environment(\.dismiss) private var dismiss
    /// (focus pass) bp-streams autofocus on the first row (the first home-server copy, else the first
    /// stream), taken by use-bp-focus's seed pass while the viewer has not moved (SETTLE_WINDOW_MS,
    /// 6 s): the cover opened with the ring on the "All" chip, so Select did nothing and every pick
    /// took a Down first. `seededKey` is where the last seed put the ring; the seed follows a new
    /// first row only while the ring is still there.
    @FocusState private var rowFocus: String?
    /// The quality chips ("q:<name>"); the cover's first ring lands on "q:All".
    @FocusState private var chipFocus: String?
    @State private var seededKey: String?
    @State private var seedFrom = Date()
    /// The auto step just handed over to the list (bp-streams recoverBpFocus on a surface swap):
    /// the next seed may take the ring from wherever it fell.
    @State private var seedAfterSwap = false

    enum PickerDialog: Identifiable {
        case p2p(ScoredStream), debridDown, noSources, exhausted(Int)
        var id: String {
            switch self {
            case .p2p(let s): return "p2p-\(s.id)"
            case .debridDown: return "debrid-down"
            case .noSources: return "no-sources"
            case .exhausted: return "exhausted"
            }
        }
    }

    /// bp-stream-chips.tsx quality chips, mapped onto the parser's resolution values.
    private static let qualities: [(String, [String])] = [("All", []), ("4K UHD", ["2160p", "4K"]), ("1080p", ["1080p"]), ("720p", ["720p"]), ("480p", ["480p"]), ("SD", ["SD", "360p", "240p"])]

    var body: some View {
        ZStack {
            if switching != nil {
                switchCard
                // (P8) bp-streams: in the player the dialogs sit over the card inside the player, not
                // in a cover: a cover over the player takes it off screen (its onDisappear releases
                // the stream, Now Playing and the torrent while the film plays on).
                if let d = dialog { dialogView(d).transition(.opacity) }
            } else {
                BPAmbientBackground()
                pickerSurface
            }
        }
        .ignoresSafeArea()
        .task {
            guard !searched else { return }
            searched = true
            // bp-streams: sourceKind starts on the preferred kind when the preference applies.
            if applyPreference, SettingsBridge.shared.slice.playbackSourcePreference == "home-server" { sourceKind = "media-server" }
            if autoEnabled { autoState = .waiting; startedAt = Date() }
            await model.search(meta: meta, episode: episode)
            await autoTick(done: true)
        }
        .task {
            // use-auto-fire: settle windows (1.5 s after the first result, 4 s when no cached exact episode,
            // 10 s cap) so a fast addon does not beat a better one by a few hundred milliseconds.
            guard autoEnabled else { return }
            // (detail/search pass 2) Ticks until auto is over, not only while it waits: when the
            // search-done tick fired a candidate this loop saw `.firing` and ended, so a failed first
            // candidate set `.waiting` with nothing left to tick, and the auto step sat on screen for
            // good. It also runs from before the first task sets `.waiting` (`.off`).
            while !Task.isCancelled {
                if autoState == .cancelled || autoState == .exhausted { return }
                try? await Task.sleep(for: .milliseconds(400))
                // A cancelled sleep returns at once: no last tick (and resolve) once the view has gone.
                if Task.isCancelled { return }
                await autoTick(done: false)
            }
        }
        .task {
            // play-picker.tsx / auto-play-transition.tsx: consumeRecentStubEvent(8000) as the picker
            // opens; the notice clears itself after 6 s. (P8) Not the in-player switcher: it has no
            // stub banner, and reading the event here would take it from the picker it was meant for.
            guard switching == nil else { return }
            let ev: String? = try? await HarborEngine.shared.call("deadStreams.consumeStubEvent", [8000])
            guard ev != nil, !Task.isCancelled else { return }
            stubNotice = true
            try? await Task.sleep(for: .seconds(6))
            stubNotice = false
        }
        .onAppear {
            // (P8) The switcher opens inside the player with no ring of its own: it starts on the
            // "All" chip, where the picker's cover lands, so the first row's seed takes it from there.
            guard switching != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if rowFocus == nil, chipFocus == nil { chipFocus = "q:All" }
            }
        }
        .onChange(of: model.streams.count) { _, n in if n > 0, firstResultAt == nil { firstResultAt = Date() } }
        // bp-stream-filters useState(requirePreferredLanguage && preferredLanguages.length > 0): once per opening.
        .onChange(of: model.setup) { _, setup in
            guard !langSeeded, let setup else { return }
            langSeeded = true
            langFilter = setup.langFilterDefault
        }
        .onChange(of: firstRowKey) { _, _ in seedRing() }
        .onChange(of: showAutoStep) { _, busy in
            guard !busy else { return }
            seededKey = nil
            seedFrom = Date()
            seedAfterSwap = true
            seedRing()
        }
        .onChange(of: dialog == nil) { _, clear in if clear { seedRing() } }
        .onChange(of: model.copiesLoaded) { _, loaded in if loaded { Task { await applySourcePreference() } } }
        // bp-streams: BpNoSourcesDialog when there is no addon, no debrid and no home-server copy
        // (the switcher lists no copies: `homeServerCopies.length === 0` holds there).
        .onChange(of: model.phase) { _, phase in
            let noCopies: Bool = switching != nil || model.copies.isEmpty
            // It outranks "tried N sources" (bp-streams shows that one only when !noSources).
            if phase == .done, model.addonCount == 0, model.debridCount == 0, noCopies, dialog == nil || dialog?.id == "exhausted" { dialog = .noSources }
        }
        // BpAutoExhaustedDialog: shown unless no sources or debrid down already explains it.
        .onChange(of: autoState) { _, state in
            if state == .exhausted, dialog == nil { dialog = .exhausted(autoTried) }
        }
        .onDisappear {
            // Covered by one of its own dialogs, not closed (bug pass). The switcher draws its
            // dialogs inline, so it only disappears when it closes.
            guard dialog == nil || switching != nil else { return }
            alive = false; if autoState == .waiting { autoState = .cancelled }; model.cancel()
        }
        .fullScreenCover(item: coverDialog) { d in dialogView(d) }
    }

    /// The picker's dialogs come up in a cover; the in-player switcher's never do (drawn inline).
    private var coverDialog: Binding<PickerDialog?> {
        if switching != nil { return Binding<PickerDialog?>.constant(nil) }
        return $dialog
    }

    /// The picker's own page: the auto step, or the list beside the title's column.
    @ViewBuilder private var pickerSurface: some View {
        if showAutoStep {
            // bp-streams.tsx: while auto is busy BpAutoStep stands in for the panel (a kid
            // profile's is auto-play-transition.tsx's kid branch).
            PickerAutoStep(meta: meta, episode: episode, attemptIdx: autoTried, resolving: autoFiring,
                           p2p: model.p2pStarting, kid: ProfilesStore.shared.active?.kid != nil,
                           stubNotice: stubNotice, onCancel: { cancelAuto() })
                .transition(.opacity)
        } else {
            HStack(alignment: .top, spacing: BP.px(40)) {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    Text("Play").font(BP.sans(11, .bold)).foregroundStyle(BP.accent).textCase(.uppercase).tracking(1)
                    Text(meta.name).font(BP.display(30)).foregroundStyle(BP.ink).lineLimit(3)
                    if let ep = episodeLabel { Text(ep).font(BP.sans(16, .semibold)).foregroundStyle(BP.inkMuted) }
                    statusLine
                    if stubNotice { stubBanner }
                    if let resolveError { BPNote(text: resolveError, tone: BP.danger) }
                    RemoteImage(url: meta.poster).frame(width: BP.px(177), height: BP.px(265)).clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous)).padding(.top, BP.px(10))
                }
                .frame(width: BP.px(300), alignment: .leading)
                list
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.px(50))
        }
    }

    // bp-stream-dialogs.tsx, one view per dialog. Back acts like the seeded button's escape
    // (useSeededFocus onBack): Cancel, Back, Back, Browse sources.
    @ViewBuilder private func dialogView(_ d: PickerDialog) -> some View {
        switch d {
        case .p2p(let s):
            StreamDialogShell(title: "Stream this via peer-to-peer?",
                              message: "This source isn't cached on your debrid, so Harbor would pull it directly from peers. It can take a moment to start and may buffer on low-seed torrents.") {
                VStack(alignment: .leading, spacing: BP.px(6)) {
                    Text(s.parsedTitle ?? s.title ?? s.name ?? T("This source")).font(.system(size: BP.px(14), design: .monospaced)).foregroundStyle(BP.ink).lineLimit(2)
                    HStack(spacing: BP.px(12)) {
                        if let seeds = s.seeders { Label("\(Int(seeds)) seeders", systemImage: "person.2") }
                        if let sz = s.sizeText { Text(sz) }
                        let summary = badges(s).filter { $0 != "Cached" }
                        if !summary.isEmpty { Text(summary.joined(separator: " · ")) }
                    }
                    .font(BP.sans(13, .medium)).foregroundStyle(BP.inkSubtle)
                }
                .padding(BP.px(14)).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge, lineWidth: 1))
            } buttons: {
                Button("Cancel") { dialog = nil }.buttonStyle(BPActionStyle())
                Button("Stream") { dialog = nil; Task { await start(s, forceP2p: true) } }.buttonStyle(BPActionStyle(primary: true))
                Button("Always stream P2P") { dialog = nil; Task { await model.setP2pAutoConsent(); await start(s, forceP2p: true) } }.buttonStyle(BPActionStyle())
            }
            .onExitCommand { dialog = nil }
        case .debridDown:
            StreamDialogShell(title: "Your debrid service can't process this right now.",
                              message: "Real-Debrid, TorBox, AllDebrid and Premiumize all have brief outages where they stop returning links. Wait a few minutes and try again, or check the service's status page.") {
                EmptyView()
            } buttons: {
                // use-pick-handler resetDebridDown: the streak clears and the list stays up.
                Button("Try again") { debridFailStreak = 0; dialog = nil }.buttonStyle(BPActionStyle(primary: true))
                Button("Back") { closePicker() }.buttonStyle(BPActionStyle())
            }
            .onExitCommand { closePicker() }
        case .noSources:
            // Upstream's second button ("Leave Big Picture and open settings") has no TV equivalent.
            StreamDialogShell(title: "No streaming sources yet",
                              message: T("Harbor needs at least one streaming source before it can play %@. Install a stream addon or add a debrid key in settings.", meta.name)) {
                EmptyView()
            } buttons: {
                Button("Back") { closePicker() }.buttonStyle(BPActionStyle(primary: true))
            }
            .onExitCommand { closePicker() }
        case .exhausted(let n):
            StreamDialogShell(title: "We could not find a working stream",
                              message: T("Harbor tried %lld sources for %@ and none of them played. Usually that means a debrid key has expired, no stream addon is installed yet, or nothing has this title cached.", n, exhaustedLabel)) {
                EmptyView()
            } buttons: {
                Button("Browse sources") { browseManually() }.buttonStyle(BPActionStyle(primary: true))
                Button("Back") { closePicker() }.buttonStyle(BPActionStyle())
            }
            .onExitCommand { browseManually() }
        }
    }

    /// bp-streams: the row that carries data-bp-autofocus (a home-server copy first, else the first stream).
    private var firstRowKey: String? {
        if showHomeServers, let c = model.copies.first { return "copy:" + c.key }
        guard showOnline, let s = visible.first else { return nil }
        return "stream:" + s.id
    }

    /// use-bp-focus seed pass: the first row takes the ring while the viewer has not moved it.
    private func seedRing() {
        guard !showAutoStep, dialog == nil, resolving == nil, let key = firstRowKey, key != rowFocus,
              Date().timeIntervalSince(seedFrom) < 6 else { return }
        let from = seededKey
        // Untouched: the first seed while the ring is on the "All" chip (where the cover lands) or
        // just after the auto step went; a later seed only while the ring is on the row seeded last.
        // (P8) The in-player switcher also takes its first seed while nothing in it has the ring yet.
        let fresh: Bool = chipFocus == "q:All" || seedAfterSwap || (switching != nil && rowFocus == nil && chipFocus == nil)
        let untouched = from == nil ? fresh : rowFocus == from
        guard untouched else { return }
        seededKey = key
        seedAfterSwap = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard from == nil || rowFocus == from else { return }
            rowFocus = key
        }
    }

    /// use-bp-stream-play autoBusy: auto is still finding or starting a source. Before the first
    /// task sets `.waiting`, an auto picker already shows the step (no flash of the list).
    private var showAutoStep: Bool {
        switch autoState {
        case .waiting, .firing: return true
        case .off: return autoEnabled
        case .cancelled, .exhausted: return false
        }
    }

    private var autoFiring: Bool { if case .firing = autoState { return true }; return false }

    /// bp-detail.tsx play(): `auto = playbackSourcePreference === "online" && instantPlay`. The caller
    /// passes instantPlay as `autoPlay`; a Play press under another preference never fires online.
    private var autoEnabled: Bool {
        autoPlay && (!applyPreference || (SettingsBridge.shared.slice.playbackSourcePreference ?? "online") == "online")
    }

    /// bp-streams.tsx's applyPreference effect, once the home-server copies are in (the engine
    /// ports decidePlaybackSource: engine/homeServers.ts preferredSource).
    private func applySourcePreference() async {
        guard applyPreference, !preferenceFired else { return }
        preferenceFired = true
        struct Decision: Decodable { var action: String; var copyKey: String? }
        let p = ProfilesStore.shared.active
        let copies: [[String: String]] = model.copies.map { ["key": $0.key, "connectionId": $0.connectionId] }
        guard let d: Decision = try? await HarborEngine.shared.call("homeServers.preferredSource", [p?.id ?? "default", p?.linked ?? true, copies]) else { return }
        switch d.action {
        case "show-all": sourceKind = "all"
        case "show-media-server": sourceKind = "media-server"
        case "play":
            // The engine can wait up to 5 s on the server health probe: a pick by hand in the meantime wins.
            guard let copy = model.copies.first(where: { $0.key == d.copyKey }), resolving == nil, alive, !handPicked else { return }
            await pick(copy: copy)
        default: break
        }
    }

    /// use-bp-stream-play cancelAuto: the resolve in flight stops counting (its result is dropped by
    /// autoTick) and auto is off for good; the list is the picker again.
    private func cancelAuto() {
        if case .firing(let id) = autoState, resolving == id { resolving = nil }
        autoState = .cancelled
    }

    /// use-bp-stream-play browseManually: auto stops for good and the list is the picker again.
    private func browseManually() { dialog = nil; autoState = .cancelled }

    private func closePicker() {
        dialog = nil
        // (P8) The in-player switcher closes its panel (bp-stream-dialogs onBack={onClose}); a
        // dismiss here would take the player's own cover down.
        if switching != nil { onClose?(); return }
        // Leave once the dialog's cover is gone; a dismiss while it is still dismissing is dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
    }

    /// BpAutoExhaustedDialog label: "{title} S{s}E{ee}" with the IMDb numbering when the episode has one.
    private var exhaustedLabel: String {
        let s = episode?["imdbSeason"]?.number ?? episode?["season"]?.number
        let e = episode?["imdbEpisode"]?.number ?? episode?["episode"]?.number
        guard let s, let e else { return meta.name }
        return "\(meta.name) S\(Int(s))E" + String(format: "%02d", Int(e))
    }

    private var episodeLabel: String? {
        guard let s = episode?["season"]?.number, let e = episode?["episode"]?.number else { return nil }
        let name = episode?["name"]?.string
        return "S\(Int(s)) E\(Int(e))" + (name.map { " · \($0)" } ?? "")
    }

    private func autoTick(done: Bool) async {
        guard autoState == .waiting else { return }
        let now = Date()
        let sinceStart = now.timeIntervalSince(startedAt)
        let sinceFirst = firstResultAt.map { now.timeIntervalSince($0) } ?? -1
        let hasEpisode = episode?["episode"]?.number != nil
        let hasCachedExact = model.streams.contains { $0.isCached }
        let settle: Double = hasEpisode && !hasCachedExact ? 4.0 : 1.5
        let ready = done || model.phase == .done || (sinceFirst >= settle) || sinceStart >= 10
        guard ready else { return }
        if model.streams.isEmpty {
            if done || model.phase == .done || sinceStart >= 10 { autoState = .exhausted }
            return
        }
        // use-bp-stream-play: auto picks from the filtered list (the saved filter's pool) (review 29).
        let allowed = Set(pool.map(\.id))
        let candidates = await model.autoCandidates(meta: meta, episode: episode).filter { model.streams.indices.contains($0) && allowed.contains(model.streams[$0].id) }
        guard autoState == .waiting else { return }
        // (detail/search pass 2) The next candidate that has not failed yet: rows keep their ids now,
        // while a candidate list that grew between ticks shifted what dropFirst(autoTried) skipped.
        guard let first = candidates.first(where: { !failedIds.contains(model.streams[$0].id) }), model.streams.indices.contains(first) else {
            if done || model.phase == .done || sinceStart >= 10 { autoState = .exhausted }
            return
        }
        let s = model.streams[first]
        autoState = .firing(s.id)
        resolving = s.id
        // use-pick-handler: during auto-fire a debrid-side failure retries the same source only under the season lock.
        let r = await resolveRetrying(s, forceP2p: false, sameSource: model.seasonLock) { if case .firing = autoState { return true }; return false }
        guard case .firing = autoState, !Task.isCancelled else {
            // The viewer picked by hand, or left: free the rows unless a manual pick owns the spinner now.
            if resolving == s.id { resolving = nil }
            return
        }
        resolving = nil
        // (bug pass 2) A link no URL can be made of counts as a failed candidate, not a silent no-op.
        if r.ok, let ready = Self.playable(r) {
            debridFailStreak = 0
            await model.remember(s, meta: meta, episode: episode, url: r.data?.url)
            // use-pick-handler: PlayerSrc.autoFired + streamRef, so a stall or a failed open can
            // mark this stream dead and bring the picker back on the next candidate (views/player.tsx).
            var handed = ready
            handed.autoPicked = true
            handed.streamRef = await model.deadRef(s)
            onPlay(s, handed)
        } else {
            failedIds.insert(s.id)
            autoTried += 1
            if countDebridFailure(r) {
                // Debrid down ends auto-fire; its dialog explains it instead of "tried N sources".
                dialog = .debridDown
                autoState = .exhausted
                return
            }
            autoState = autoTried >= 3 ? .exhausted : .waiting
        }
    }

    /// use-pick-handler: the debrid-side streak. True when this failure makes two in a row.
    private func countDebridFailure(_ r: StreamsModel.Resolved) -> Bool {
        if r.debridFailure == true, model.debridCount > 0 {
            debridFailStreak += 1
            return debridFailStreak >= 2
        }
        debridFailStreak = 0
        return false
    }

    /// use-pick-handler scheduleSameSourceRetry: a debrid-side failure retries the same source up to
    /// four times, 1.5 s × n apart, before it counts as a failure.
    private func resolveRetrying(_ s: ScoredStream, forceP2p: Bool, sameSource: Bool, stillWanted: () -> Bool) async -> StreamsModel.Resolved {
        var r = await model.resolve(s, forceP2p: forceP2p)
        var n = 0
        while sameSource, !r.ok, r.debridFailure == true, n < 4, alive, stillWanted() {
            n += 1
            try? await Task.sleep(for: .milliseconds(1500 * n))
            guard alive, stillWanted() else { break }
            r = await model.resolve(s, forceP2p: forceP2p)
        }
        return r
    }

    @ViewBuilder private var autoBanner: some View {
        // While auto is busy PickerAutoStep covers the list; only its outcome shows here.
        switch autoState {
        case .exhausted: BPNote(text: "Nothing started on its own. Pick a source.", tone: BP.inkMuted)
        default: EmptyView()
        }
    }

    /// play-picker.tsx stubBanner: the amber card over the list (border amber-300/30, fill
    /// amber-400/10, text amber-100).
    private var stubBanner: some View {
        Text("Last source wasn't actually cached on your debrid yet. Pick another from the list.")
            .font(BP.sans(13.5)).foregroundStyle(Color(red: 0.996, green: 0.953, blue: 0.78))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(12))
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(Color(red: 0.984, green: 0.749, blue: 0.141).opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(Color(red: 0.988, green: 0.827, blue: 0.302).opacity(0.3), lineWidth: 1))
    }

    @ViewBuilder private var statusLine: some View {
        autoBanner
        if model.p2pStarting {
            // A torrent is fetching its metadata in the TV's engine (bp-p2p-status "Looking for peers…").
            HStack(spacing: BP.px(8)) {
                ProgressView().tint(BP.accent)
                Text("Looking for peers…").font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
            }
        }
        switch model.phase {
        case .searching, .done:
            // bp-streams header: "Searching" or "{shown} of {total} sources", then "{n} addons loading".
            Text(verbatim: sourcesLine).font(BP.sans(14, .medium)).foregroundStyle(BP.inkSubtle)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let why): BPNote(text: why, tone: BP.danger)
        case .idle: EmptyView()
        }
    }

    /// bp-streams s.loading: the pipeline is still running and nothing has passed the filters yet.
    private var listLoading: Bool {
        // (review 18) On the Media servers list only the home-server copies are drawn: until they
        // are in it is still looking. A finished stream search there read "No sources match these
        // filters" (with the loosen ladder when no addon answered) over a copy about to arrive.
        if sourceKind == "media-server", !model.copiesLoaded { return true }
        let running: Bool = model.phase == .searching || model.phase == .idle
        return running && pool.isEmpty
    }

    /// bp-streams header counts: every kind the source chip shows (online streams after every
    /// filter over the ones after the mode / language / cached / saved-filter pass, plus the
    /// home-server copies).
    private var sourcesLine: String {
        let copies: Int = showHomeServers ? model.copies.count : 0
        let shown: Int = (showOnline ? visible.count : 0) + copies
        let total: Int = (showOnline ? pool.count : 0) + copies
        var line: String = listLoading ? T("Searching") : T("%lld of %lld sources", shown, total)
        let pending: Int = model.pendingAddonCount
        if pending > 0 { line += " · " + T("%lld addons loading", pending) }
        return line
    }

    /// Flat, cached-first list (the pipeline already ranked it), narrowed by the chips.
    // play-picker/stream-facets.ts, minus resolution and availability which the chips above own.
    struct Facet { let key: String; let label: String; let order: [String]; let valueOf: (ScoredStream) -> String? }
    private static let facets: [Facet] = [
        Facet(key: "source", label: "Source", order: ["Remux", "BluRay", "WEB-DL", "WEBRip", "HDTV", "CAM"]) { s in
            if s.remux == true { return "Remux" }
            switch (s.source ?? "").uppercased() {
            case "BLURAY", "BDRIP", "BRRIP", "BLU-RAY": return "BluRay"
            case "WEB-DL", "WEBDL", "WEB": return "WEB-DL"
            case "WEBRIP", "HDRIP": return "WEBRip"
            case "HDTV", "DVDRIP": return "HDTV"
            case "CAM", "TS", "HDTS", "TC", "SCR": return "CAM"
            default: return nil
            }
        },
        Facet(key: "codec", label: "Codec", order: ["HEVC", "AV1", "AVC"]) { s in ["HEVC", "AV1", "AVC"].contains(s.codec ?? "") ? s.codec : nil },
        Facet(key: "hdr", label: "HDR", order: ["HDR", "SDR"]) { s in s.hdrFormat != nil ? "HDR" : "SDR" },
        Facet(key: "audio", label: "Audio", order: ["Atmos", "TrueHD", "DTS-HD", "DTS", "DD+"]) { s in
            switch s.audio?.codec { case "Atmos": return "Atmos"; case "TrueHD": return "TrueHD"; case "DTS-HD MA": return "DTS-HD"; case "DTS": return "DTS"; case "DD+": return "DD+"; default: return nil }
        },
    ]
    @State private var facet: [String: String] = [:]
    /// bp-stream-filters addonOrderMode: settings.streamSort === "addon" (the default) or an addon
    /// that ranks its own list; else the Harbor order.
    private var sortByAddon: Bool { model.addonRanked || model.streamSort == "addon" }
    /// bp-stream-chips sort chip label (sortForced / sort === "addon" / Harbor's order).
    private var sortChipLabel: String {
        T(model.addonRanked ? "Addon order (locked)" : (model.streamSort == "addon" ? "Addon order" : "Harbor pick"))
    }

    private func matchesFacets(_ s: ScoredStream, except: String? = nil) -> Bool {
        for f in Self.facets where f.key != except {
            guard let sel = facet[f.key] else { continue }
            if f.valueOf(s) != sel { return false }
        }
        return true
    }

    private func facetOptions(_ f: Facet) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for s in pool where matchesFacets(s, except: f.key) {
            if let v = f.valueOf(s) { counts[v, default: 0] += 1 }
        }
        return f.order.compactMap { k in counts[k].map { (k, $0) } }
    }

    private var filtered: Bool { quality != "All" || cachedOnly || langFilter || addonFilter != nil || !facet.isEmpty }

    /// bp-stream-filters `base`, in its order: the stream mode (settings.streamMode), the preferred
    /// languages (langFilter), Cached only, then the active saved filter. Each step that would leave
    /// nothing is skipped; a saved filter that matched nothing, or a pool left empty, brings every
    /// stream back and the banner says so (filterFellBack).
    private var filterPool: (streams: [ScoredStream], fellBack: Bool) {
        let candidates: [ScoredStream] = model.streams
        guard !candidates.isEmpty else { return (candidates, false) }
        var all: [ScoredStream] = candidates
        // filterStreamsByMode (its own keep-everything fallback is in the engine's flags).
        if model.streamMode == "addons" {
            all = all.filter { $0.tvModes?.addons ?? true }
        } else if model.streamMode == "p2p" {
            all = all.filter { $0.tvModes?.p2p ?? true }
        }
        let langs: [String] = model.setup?.preferredLangs ?? []
        if langFilter, !langs.isEmpty {
            let matched = all.filter { $0.tvLang ?? true }
            if !matched.isEmpty { all = matched }
        }
        if cachedOnly {
            let cached = all.filter(\.isCached)
            if !cached.isEmpty { all = cached }
        }
        var fellBack = false
        // `activeStreamFilter && !hostMatch`: a room host's match overrides the saved filter.
        if let id = model.activeFilterId, model.hostScores == nil {
            let matched = all.filter { $0.tvFilters?.contains(id) ?? true }
            if matched.isEmpty { fellBack = true } else { all = matched }
        }
        if all.isEmpty {
            all = candidates
            fellBack = true
        }
        return (all, fellBack)
    }
    private var pool: [ScoredStream] { filterPool.streams }

    /// bp-stream-filters langHiddenCount: streams (of every one listed) not in a preferred language.
    private var langHiddenCount: Int {
        guard !(model.setup?.preferredLangs.isEmpty ?? true) else { return 0 }
        return model.streams.filter { !($0.tvLang ?? true) }.count
    }

    /// bp-stream-chips source chip label: Media servers, else the stream mode's name.
    private var sourceChipLabel: String {
        if sourceKind == "media-server" { return T("Media servers") }
        switch model.streamMode {
        case "addons": return T("Direct/debrid only")
        case "p2p": return T("P2P only")
        default: return T("All sources")
        }
    }

    /// bp-stream-chips source menu value, and its options as one chip that steps through them:
    /// All sources, Media servers (when this title has a home-server copy), Direct/debrid only, P2P only.
    private func nextSource() {
        let current: String = sourceKind == "online" || (sourceKind == "all" && model.streamMode != "both") ? model.streamMode : sourceKind
        var ids: [String] = ["all"]
        if switching == nil, !model.copies.isEmpty || sourceKind == "media-server" { ids.append("media-server") }
        ids.append("addons")
        ids.append("p2p")
        let at: Int = ids.firstIndex(of: current) ?? 0
        let next: String = ids[(at + 1) % ids.count]
        if next == "addons" || next == "p2p" {
            sourceKind = "online"
            model.setStreamMode(next)
        } else {
            if model.streamMode != "both" { model.setStreamMode("both") }
            sourceKind = next
        }
    }

    /// bp-streams showOnline / showHomeServers.
    private var showOnline: Bool { sourceKind == "all" || sourceKind == "online" }
    /// (P8) bp-streams `homeServerCopies = download || switching ? [] : …`: none in the switcher.
    private var showHomeServers: Bool { switching == nil && (sourceKind == "all" || sourceKind == "media-server") }

    /// bp-stream-chips filter chip: the active filter's name (or "Filter" when it has none), else "Filters".
    private var filterChipLabel: String {
        guard let id = model.activeFilterId, let f = model.savedFilters.first(where: { $0.id == id }) else { return T("Filters") }
        return f.name.isEmpty ? T("Filter") : f.name
    }

    /// The filter menu (No filter, then each saved filter) as one chip that steps through it.
    private func nextFilter() {
        let ids: [String?] = [nil] + model.savedFilters.map { Optional($0.id) }
        let i = ids.firstIndex { $0 == model.activeFilterId } ?? 0
        let next = ids[(i + 1) % ids.count]
        Task { await model.setActiveFilter(next) }
    }

    private var visible: [ScoredStream] {
        let wanted = Self.qualities.first { $0.0 == quality }?.1 ?? []
        let filtered = pool.filter { s in
            (wanted.isEmpty || wanted.contains(s.resolution ?? "")) &&
            (addonFilter == nil || s.addonName == addonFilter) &&
            matchesFacets(s)
        }
        let sorted: [ScoredStream]
        if sortByAddon {
            // orderByAddonNative: addons in the installed order, each stream where its addon listed it.
            var rank: [String: Int] = [:]
            for (i, url) in model.addonOrder.enumerated() { rank[url] = i }
            sorted = filtered.sorted { a, b in
                let ra = a.addonUrl.flatMap { rank[$0] } ?? 9999, rb = b.addonUrl.flatMap { rank[$0] } ?? 9999
                if ra != rb { return ra < rb }
                let na = a.nativeIdx ?? Int.max, nb = b.nativeIdx ?? Int.max
                return na != nb ? na < nb : a.index < b.index
            }
        } else {
            // bp-stream-filters: cached first (base); with every addon shown, the Harbor order puts
            // WatchHub and still-downloading links last, then addons in installed order, then instant
            // markers first; ties keep the cached-first score order.
            var rank: [String: Int] = [:]
            for (i, url) in model.addonOrder.enumerated() where rank[url] == nil { rank[url] = i }
            // (review 20) bp-stream-filters `if (addonOrderMode || hostMatch) return visible`: under
            // a room host's match the Harbor order is skipped, so rows the match ties keep the
            // cached-first order (the host-match sort below is stable over it), as upstream.
            let everyAddon = addonFilter == nil && model.hostScores == nil
            sorted = filtered.sorted { a, b in
                if everyAddon {
                    let wa = a.tvSort?.watchHub == true, wb = b.tvSort?.watchHub == true
                    if wa != wb { return wb }
                    let da = a.tvSort?.needsDownload == true, db = b.tvSort?.needsDownload == true
                    if da != db { return db }
                    let ra = a.addonUrl.flatMap { rank[$0] } ?? 9999, rb = b.addonUrl.flatMap { rank[$0] } ?? 9999
                    if ra != rb { return ra < rb }
                    let ia = a.tvSort?.instant == true, ib = b.tvSort?.instant == true
                    if ia != ib { return ia }
                }
                return a.isCached != b.isCached ? a.isCached : a.index < b.index
            }
        }
        // (player parity pass 2) bp-stream-filters displayStreams: under a room host playing this
        // title the host match leads (a stable sort), in place of the remembered pick.
        let ordered: [ScoredStream]
        if let scores = model.hostScores { ordered = hostMatchFirst(sorted, scores) } else { ordered = pinnedFirst(sorted) }
        // (P8) bp-streams switch mode `list`: the stream playing now moves to the front.
        guard let current = switching, let at = ordered.firstIndex(where: { current.matches($0) }), at > 0 else { return ordered }
        var out: [ScoredStream] = ordered
        let playing: ScoredStream = out.remove(at: at)
        out.insert(playing, at: 0)
        return out
    }

    /// bp-stream-filters `ordered.slice().sort((a, b) => hostMatch(b) - hostMatch(a))`, stable.
    private func hostMatchFirst(_ list: [ScoredStream], _ scores: [String: Double]) -> [ScoredStream] {
        let ranked: [(offset: Int, element: ScoredStream)] = Array(list.enumerated())
        let sorted: [(offset: Int, element: ScoredStream)] = ranked.sorted { a, b in
            let sa: Double = a.element.tvKey.flatMap { scores[$0] } ?? 0
            let sb: Double = b.element.tvKey.flatMap { scores[$0] } ?? 0
            if sa != sb { return sa > sb }
            return a.offset < b.offset
        }
        return sorted.map { $0.element }
    }

    /// bp-stream-filters `pinned`: the remembered stream leads the list whenever the filters keep it.
    private func pinnedFirst(_ list: [ScoredStream]) -> [ScoredStream] {
        guard let p = model.rememberedIndex, let i = list.firstIndex(where: { $0.index == p }) else { return list }
        var out = list
        let s = out.remove(at: i)
        out.insert(s, at: 0)
        return out
    }

    private var addons: [String] { Array(Set(pool.map(\.addonName))).sorted() }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BP.px(8)) {
                ForEach(Self.qualities, id: \.0) { q in
                    let n = q.1.isEmpty ? pool.count : pool.filter { q.1.contains($0.resolution ?? "") }.count
                    if n > 0 || q.0 == "All" {
                        // A String, not a literal: "%@ %lld" is a catalog entry some languages re-order (review 20).
                        Button(T(q.0) + " \(n)") { quality = q.0 }.buttonStyle(BPActionStyle(primary: quality == q.0))
                            .bpSelected(quality == q.0)
                            .focused($chipFocus, equals: "q:" + q.0)
                    }
                }
                // bp-stream-chips Cached chip with its count (cachedCount: every cached stream listed).
                if cachedOnly || model.streams.contains(where: \.isCached) {
                    let cachedCount: Int = model.streams.filter(\.isCached).count
                    Button(T("Cached") + " \(cachedCount)") { cachedOnly.toggle() }.buttonStyle(BPActionStyle(primary: cachedOnly))
                        .bpSelected(cachedOnly)
                }
                if addons.count > 1 {
                    Rectangle().fill(BP.edge2).frame(width: 1, height: BP.px(24))
                    Button(addonFilter ?? T("All addons")) {
                        let list = [nil] + addons.map { Optional($0) }
                        let i = list.firstIndex { $0 == addonFilter } ?? 0
                        addonFilter = list[(i + 1) % list.count]
                    }.buttonStyle(BPActionStyle(primary: addonFilter != nil))
                }
                // Facet chips cycle All → each value that exists (with counts), like bp-stream-menu.
                ForEach(Self.facets, id: \.key) { f in
                    let opts = facetOptions(f)
                    if opts.count > 1 || facet[f.key] != nil {
                        Button(facet[f.key].map { v in "\(T(f.label)): \(v) \(opts.first { $0.0 == v }?.1 ?? 0)" } ?? T(f.label)) {
                            let keys = opts.map(\.0)
                            if let cur = facet[f.key], let i = keys.firstIndex(of: cur) {
                                if i + 1 < keys.count { facet[f.key] = keys[i + 1] } else { facet[f.key] = nil }
                            } else { facet[f.key] = keys.first }
                        }.buttonStyle(BPActionStyle(primary: facet[f.key] != nil))
                    }
                }
                // bp-stream-chips preferred-language chip: the languages' codes and how many streams
                // they hide, while any are hidden. (Parity pass) It can leave with the ring on it, so it
                // stays drawn, dimmed and ignored, while it holds the ring (a vanished chip drops focus).
                let langCount: Int = langHiddenCount
                if langCount > 0 || chipFocus == "lang" {
                    let label: String = model.setup?.langLabel ?? ""
                    Button(label + " \(langCount)") {
                        guard langCount > 0 else { return }
                        langFilter.toggle()
                    }
                    .buttonStyle(BPActionStyle(primary: langFilter, busy: langCount == 0))
                    .bpSelected(langFilter)
                    .focused($chipFocus, equals: "lang")
                }
                // bp-stream-chips source chip: All sources, Media servers, Direct/debrid only, P2P only.
                Button(sourceChipLabel) { nextSource() }
                    .buttonStyle(BPActionStyle(primary: sourceKind != "all" || model.streamMode != "both"))
                // bp-stream-chips filter chip: the saved stream filters (Settings → Stream filters on
                // the desktop), No filter first.
                if !model.savedFilters.isEmpty {
                    Button { nextFilter() } label: { Label(filterChipLabel, systemImage: "line.3.horizontal.decrease") }
                        .buttonStyle(BPActionStyle(primary: model.activeFilterId != nil))
                }
                Rectangle().fill(BP.edge2).frame(width: 1, height: BP.px(24))
                // (device-flow pass 3) Dimmed and ignored, not disabled, while an addon ranks its
                // own list: that flag can land with the ring on this chip, and a disabled button
                // drops focus on tvOS. Labels are bp-stream-chips' sort chip.
                Button {
                    guard !model.addonRanked else { return }
                    let next = sortByAddon ? "harbor" : "addon"
                    Task { await model.setStreamSort(next) }
                } label: {
                    Label(sortChipLabel, systemImage: "arrow.up.arrow.down")
                }
                .buttonStyle(BPActionStyle(busy: model.addonRanked))
                if filtered {
                    // (detail/search pass 2) The chip goes with the filters: the ring moves to "All"
                    // instead of falling off the row.
                    Button("Clear filters") { quality = "All"; cachedOnly = false; langFilter = false; addonFilter = nil; facet = [:]; chipFocus = "q:All" }.buttonStyle(BPActionStyle())
                }
                // bp-stream-chips Refresh (use-pipeline-result refresh): the search runs again.
                Button { Task { await model.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(BPActionStyle())
            }
            .padding(.vertical, BP.px(6))
        }
        .scrollClipDisabled()
        .focusSection()
    }

    /// (P8) bp-streams.tsx switch mode (SWITCH_SURFACE over a 50% void scrim): a card the size of the
    /// player's other panels (the Audio dialog's frame), "Switch source", the title line with the
    /// source counts, the chips and rows, and the footer note.
    private var switchCard: some View {
        ZStack {
            BP.void_.opacity(0.5).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: BP.px(5)) {
                    Text("Switch source").font(BP.display(26)).foregroundStyle(BP.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: switchHeading + " · " + sourcesLine)
                        .font(BP.sans(13, .medium)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                    if model.p2pStarting {
                        HStack(spacing: BP.px(8)) {
                            ProgressView().tint(BP.accent)
                            Text("Looking for peers…").font(BP.sans(13, .semibold)).foregroundStyle(BP.ink)
                        }
                    }
                    if case .failed(let why) = model.phase { BPNote(text: why, tone: BP.danger) }
                    if let resolveError { BPNote(text: resolveError, tone: BP.danger) }
                }
                .padding(.horizontal, BP.px(30)).padding(.top, BP.px(30)).padding(.bottom, BP.px(6))

                list
                    .padding(.horizontal, BP.px(30))
                    .frame(maxHeight: .infinity, alignment: .top)

                Text("Pick a source to swap in place. Playback keeps running.")
                    .font(BP.sans(12.5, .semibold)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, BP.px(30)).padding(.vertical, BP.px(12))
                    .overlay(alignment: .top) { Rectangle().fill(BP.edge).frame(height: 1) }
            }
            .frame(width: BP.px(1049), height: BP.px(551), alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.void_))
            .clipShape(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge, lineWidth: 1))
            .focusSection()
            // The dialog over the card owns the remote while it is up.
            .disabled(dialog != nil)
        }
    }

    /// bp-streams heading: "{name} · S{imdbSeason ?? season}E{imdbEpisode ?? episode}", else the name.
    private var switchHeading: String {
        let s: Double? = episode?["imdbSeason"]?.number ?? episode?["season"]?.number
        let e: Double? = episode?["imdbEpisode"]?.number ?? episode?["episode"]?.number
        guard let s, let e else { return meta.name }
        return "\(meta.name) · S\(Int(s))E\(Int(e))"
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            chips
            // bp-streams: the saved filter matched nothing, so the whole list is back.
            if filterPool.fellBack, model.activeFilterId != nil {
                BPNote(text: "No sources match your filter. Showing all sources.")
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: BP.px(10)) {
                    let rows: [ScoredStream] = showOnline ? visible : []
                    if showHomeServers, !model.copies.isEmpty {
                        Text("On your home servers").font(BP.sans(12, .bold)).textCase(.uppercase).tracking(0.6).foregroundStyle(BP.inkMuted)
                        ForEach(model.copies) { c in copyRow(c) }
                        if !rows.isEmpty { Text("Addons").font(BP.sans(12, .bold)).textCase(.uppercase).tracking(0.6).foregroundStyle(BP.inkMuted).padding(.top, BP.px(6)) }
                    }
                    ForEach(rows) { s in row(s, highlight: isHighlighted(s)) }
                    if rows.isEmpty, !showHomeServers || model.copies.isEmpty { emptyList }
                    Color.clear.frame(height: BP.px(60))
                }
                .padding(.vertical, BP.px(6))
            }
            .focusSection()
        }
    }

    /// bp-streams empty state: a spinner while the search runs, else "No sources found" (nothing
    /// listed at all) with the loosen ladder, or "No sources match these filters".
    private var emptyList: some View {
        VStack(spacing: BP.px(12)) {
            if listLoading {
                ProgressView().tint(BP.inkSubtle)
            } else {
                Image(systemName: "shippingbox").font(.system(size: BP.px(30), weight: .regular)).foregroundStyle(BP.inkSubtle)
                    .accessibilityHidden(true)
            }
            let note: String = listLoading ? "Looking for sources" : (pool.isEmpty ? "No sources found" : "No sources match these filters")
            Text(verbatim: T(note))
                .font(BP.sans(16, .semibold)).foregroundStyle(BP.inkSubtle)
            // bp-streams ladder: nothing listed at all, so widen the search, then show everything. The
            // pressed button goes with the list, so the ring waits on the "All" chip.
            if !listLoading, pool.isEmpty, model.canLoosen {
                HStack(spacing: BP.px(10)) {
                    if model.strict {
                        Button("Search wider") { chipFocus = "q:All"; Task { await model.searchWider() } }
                            .buttonStyle(BPActionStyle(primary: true))
                    }
                    if !model.showAll {
                        Button("Show everything") { chipFocus = "q:All"; Task { await model.showEverything() } }
                            .buttonStyle(BPActionStyle())
                    }
                }
                .focusSection()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, BP.px(40))
    }

    /// The picker lifts its best pick; the switcher marks the stream playing now (bp-stream-row
    /// isCurrent: the stronger edge).
    private func isHighlighted(_ s: ScoredStream) -> Bool {
        if let current = switching { return current.matches(s) }
        return s.id == model.primary?.id
    }

    private func row(_ s: ScoredStream, highlight: Bool) -> some View {
        Button {
            // (P8 follow-up) The stream playing now is picked like any other row: use-stream-switcher
            // onSwitchStream resolves it again (a fresh debrid link, the same torrent) and reloads it
            // in place at the resume spot, which is how a stalled or dead copy is brought back.
            // (focus pass) One pick at a time, guarded here rather than by disabling every row.
            guard resolving == nil else { return }
            // (detail/search pass 2) Held from the press: the Task starts a beat later and the P2P
            // consent read awaits, so a double press got past the guard and resolved the row twice
            // (two debrid unrestricts, or two torrent adds).
            handPicked = true; resolving = s.id; Task { await pick(s) }
        } label: {
            VStack(alignment: .leading, spacing: BP.px(5)) {
                HStack(alignment: .center, spacing: BP.px(10)) {
                    // The pills take what the marks on the right leave (a Spacer beside a wrapping
                    // row would be offered half and wrap early).
                    Group {
                        if let labels = s.tvLabels {
                            rowMeta(s, labels)
                        } else {
                            HStack(spacing: BP.px(8)) {
                                ForEach(badges(s), id: \.self) { b in
                                    Text(b == "Cached" ? T("Cached") : b).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(0.4)
                                        .foregroundStyle(b == "Cached" ? BP.canvas : BP.ink)
                                        .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2))
                                        .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(b == "Cached" ? BP.live : BP.on))
                                }
                                Text(s.addonName).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // bp-stream-row: the stream playing now wears "Now playing" (the switcher), else
                    // the remembered pick "Played last".
                    if let current = switching, current.matches(s) {
                        // bp-stream-row PILL_STATE: an outlined capsule (edge-2), uppercase, ink.
                        Text("Now playing")
                            .font(BP.sans(10.5, .bold)).textCase(.uppercase).tracking(1.2).foregroundStyle(BP.ink)
                            .padding(.horizontal, BP.px(9)).padding(.vertical, BP.px(4))
                            .overlay(Capsule().stroke(BP.edge2, lineWidth: 1))
                            .fixedSize()
                    } else if model.rememberedIndex == s.index {
                        Label("Played last", systemImage: "clock.arrow.circlepath")
                            .font(BP.sans(10.5, .bold)).foregroundStyle(BP.ink)
                            .padding(.horizontal, BP.px(7)).padding(.vertical, BP.px(2))
                            .background(Capsule().fill(BP.glass))
                            .fixedSize()
                    }
                    if let labels = s.tvLabels { availabilityMark(labels) }
                    if resolving == s.id { ProgressView().tint(BP.inkMuted).scaleEffect(0.7) }
                }
                let headline = s.tvRow?.headline ?? s.parsedTitle ?? s.title ?? s.name ?? "Stream"
                Text(headline).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                // bp-stream-row.tsx: the addon's whole description (fullStreamDescription), else the
                // one-line summary; both with the pictographs dropped (engine stampPickerRows).
                if let text = s.tvRow, SettingsBridge.shared.slice.fullStreamDescription ?? true, !text.description.isEmpty {
                    Text(verbatim: text.description).font(BP.sans(12, .medium)).foregroundStyle(BP.inkMuted).lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let text = s.tvRow, !text.detail.isEmpty {
                    Text(verbatim: text.detail).font(BP.sans(12, .medium)).foregroundStyle(BP.inkMuted).lineLimit(1)
                } else {
                    HStack(spacing: BP.px(10)) {
                        if let g = s.releaseGroup { Text(g) }
                        if let sz = s.sizeText { Text(sz) }
                        if let seeds = s.seeders, seeds > 0 { Text("\(Int(seeds)) seeders") }
                        if let langs = s.audioLanguages, !langs.isEmpty { Text(langs.prefix(3).joined(separator: ", ")) }
                    }
                    .font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
                }
                // settings.pickerShowFilename: the torrent's filename in mono, unless it is the headline.
                if SettingsBridge.shared.slice.pickerShowFilename ?? false, let name = s.tvRow?.filename, !name.isEmpty, name != headline, name != s.tvRow?.headline {
                    Text(verbatim: name).font(.system(size: BP.px(11), design: .monospaced)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                }
                if failedIds.contains(s.id) {
                    Text("Unavailable, try another.").font(BP.sans(12, .bold)).foregroundStyle(BP.ink)
                }
            }
            .padding(BP.px(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(highlight ? BP.panel2 : BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(highlight ? BP.accent.opacity(0.6) : BP.edge, lineWidth: 1))
            .opacity(failedIds.contains(s.id) ? 0.7 : 1)
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM))
        // (focus pass) Was .disabled(resolving != nil): the pressed row turned unfocusable the moment
        // its resolve began, so the ring was thrown onto the filter chips and stayed there when the
        // link failed ("Unavailable, try another."), a whole list away from the next row to try.
        .focused($rowFocus, equals: "stream:" + s.id)
        .accessibilityIdentifier("stream-\(s.index)")
    }

    /// bp-stream-row.tsx META: the quality pill (showQualityBadge), the addon's name, the DUB/SUB
    /// pill (showDubBadge, anime only), the format badges (showQualityBadge) and the edition. It
    /// wraps like upstream's flex-wrap rather than squeezing the pills.
    private func rowMeta(_ s: ScoredStream, _ labels: ScoredStream.Labels) -> some View {
        let slice = SettingsBridge.shared.slice
        let showQuality: Bool = slice.showQualityBadge ?? true
        let showDub: Bool = slice.showDubBadge ?? true
        return PickerFlowRow(spacing: BP.px(8), lineSpacing: BP.px(6)) {
            if showQuality {
                // "No Label" and "Unverified" are catalog keys; QUALITY_LABEL values are not translated upstream.
                let quality: String = labels.confidence == "labeled" ? labels.quality : T(labels.quality)
                Text(verbatim: quality).font(BP.sans(12.5, .heavy)).foregroundStyle(BP.ink).lineLimit(1)
                    .padding(.horizontal, BP.px(8)).padding(.vertical, BP.px(2))
                    .background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(BP.glass))
            }
            Text(verbatim: s.addonName).font(BP.sans(11, .bold)).textCase(.uppercase).tracking(1.2).foregroundStyle(BP.inkMuted)
                .lineLimit(1).frame(maxWidth: BP.px(240), alignment: .leading)
            if let match = model.hostMatchBadge(s) { hostMatchChip(match) }
            if showDub, let kind = labels.dubSub { dubSubPill(kind) }
            if showQuality, let formats = labels.formats {
                // (player parity pass 2) bp-stream-row `badges.map(FormatBadge)`: the badge images.
                ForEach(formats, id: \.kind) { b in formatBadge(b) }
            } else if showQuality {
                ForEach(labels.badges, id: \.self) { b in
                    Text(verbatim: b).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(0.4).foregroundStyle(BP.ink).lineLimit(1)
                        .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2))
                        .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.on))
                }
            }
            if let edition = labels.edition {
                Text(verbatim: edition).font(BP.sans(10.5, .bold)).textCase(.uppercase).tracking(1.2).foregroundStyle(BP.inkMuted).lineLimit(1)
                    .padding(.horizontal, BP.px(8)).padding(.vertical, BP.px(3))
                    .background(Capsule().fill(BP.glass))
            }
        }
    }

    /// (player parity pass 2) format-badge.tsx FormatBadge size "md": the image at 80% of MAX_HEIGHT
    /// (40), no wider than 1.8 x WIDTH (42), with its two drop shadows; the badge's name when the
    /// image is missing from the bundle.
    @ViewBuilder private func formatBadge(_ b: ScoredStream.Labels.Format) -> some View {
        if let art = StreamBadgeArt.image(b.file) {
            let height: CGFloat = BP.px(32)
            let aspect: CGFloat = art.size.height > 0 ? art.size.width / art.size.height : 1
            let width: CGFloat = min(BP.px(75.6), height * aspect)
            Image(uiImage: art).resizable().scaledToFit()
                .frame(width: width, height: height)
                .shadow(color: Color.black.opacity(0.55), radius: 1)
                .shadow(color: Color.black.opacity(0.4), radius: 2, y: 1)
                .accessibilityLabel(Text(verbatim: b.text))
        } else {
            Text(verbatim: b.text).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(0.4).foregroundStyle(BP.ink).lineLimit(1)
                .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2))
                .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.on))
        }
    }

    /// (player parity pass 2) components/host-match-chip.tsx (short form): "Same file" in the accent,
    /// "Close match" quiet.
    private func hostMatchChip(_ match: String) -> some View {
        let same: Bool = match == "same"
        let fg: Color = same ? BP.accent : BP.inkMuted
        let bg: Color = same ? BP.accent.opacity(0.15) : BP.raised
        let ring: Color = same ? BP.accent.opacity(0.3) : BP.edge
        let label: String = same ? T("Same file") : T("Close match")
        return Text(verbatim: label).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(1)
            .foregroundStyle(fg).lineLimit(1)
            .padding(.horizontal, BP.px(8)).padding(.vertical, BP.px(2))
            .background(RoundedRectangle(cornerRadius: BP.px(6)).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: BP.px(6)).stroke(ring, lineWidth: 1))
    }

    /// components/dub-sub-pill.tsx: SUB quiet, DUB in the accent, DUAL in emerald.
    private func dubSubPill(_ kind: String) -> some View {
        let text: String = kind == "dual" ? "DUAL" : (kind == "dub" ? "DUB" : "SUB")
        let emerald300 = Color(red: 0.431, green: 0.906, blue: 0.718)
        let emerald400 = Color(red: 0.204, green: 0.827, blue: 0.600)
        let emerald500 = Color(red: 0.063, green: 0.725, blue: 0.506)
        let fg: Color = kind == "dual" ? emerald300 : (kind == "dub" ? BP.accent : BP.inkSubtle)
        let bg: Color = kind == "dual" ? emerald500.opacity(0.15) : (kind == "dub" ? BP.accent.opacity(0.15) : BP.canvas.opacity(0.7))
        let ring: Color = kind == "dual" ? emerald400.opacity(0.3) : (kind == "dub" ? BP.accent.opacity(0.35) : BP.edge)
        return Text(verbatim: text).font(BP.sans(10, .bold)).tracking(0.8).foregroundStyle(fg).lineLimit(1)
            .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2))
            .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: BP.px(4)).stroke(ring, lineWidth: 1))
    }

    /// bp-stream-row.tsx right-hand mark: "In {name}" (your own cloud), "Cached on {name}", "Cached";
    /// else External, P2P, or Cache (a source the debrid would have to fetch first).
    @ViewBuilder private func availabilityMark(_ labels: ScoredStream.Labels) -> some View {
        let kind: String = labels.availability ?? ""
        if kind == "cached" {
            HStack(spacing: BP.px(6)) {
                Image(systemName: "checkmark").font(.system(size: BP.px(13), weight: .heavy)).foregroundStyle(BP.live)
                Text(verbatim: cachedText(labels)).font(BP.sans(11.5, .bold)).foregroundStyle(BP.ink).lineLimit(1)
            }
            .fixedSize()
        } else if kind == "external" {
            markPill(T("External"), icon: "arrow.up.right.square")
        } else if kind == "p2p" {
            markPill(T("P2P"), icon: "point.3.connected.trianglepath.dotted")
        } else if kind == "cache" {
            markPill(T("Cache"), icon: "arrow.down.to.line")
        }
    }

    private func cachedText(_ labels: ScoredStream.Labels) -> String {
        guard let on = labels.cachedOn else { return T("Cached") }
        return on.owned ? T("In %@", on.name) : T("Cached on %@", on.name)
    }

    /// bp-stream-row PILL: an outlined capsule, muted.
    private func markPill(_ text: String, icon: String) -> some View {
        HStack(spacing: BP.px(5)) {
            Image(systemName: icon).font(.system(size: BP.px(11), weight: .bold))
            Text(verbatim: text).lineLimit(1)
        }
        .font(BP.sans(11, .bold)).foregroundStyle(BP.inkMuted)
        .padding(.horizontal, BP.px(9)).padding(.vertical, BP.px(4))
        .overlay(Capsule().stroke(BP.edge, lineWidth: 1))
        .fixedSize()
    }

    /// A copy on a Plex/Jellyfin/Emby server (bp-streams home-server rows): direct play or transcode through the server.
    private func copyRow(_ c: StreamsModel.HomeCopy) -> some View {
        Button {
            guard resolving == nil else { return }
            handPicked = true; resolving = c.key; Task { await pick(copy: c) }
        } label: {
            VStack(alignment: .leading, spacing: BP.px(5)) {
                HStack(spacing: BP.px(8)) {
                    ForEach([c.resolution, c.quality].compactMap { $0 }.filter { !$0.isEmpty && $0 != "unknown" }, id: \.self) { b in
                        Text(b).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(0.4).foregroundStyle(BP.ink)
                            .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2))
                            .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.on))
                    }
                    if c.progressMs > 0 { Text("Resume").font(BP.sans(10, .bold)).textCase(.uppercase).foregroundStyle(BP.canvas).padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2)).background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.live)) }
                    Spacer()
                    Text(c.sourceLabel).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted)
                    if resolving == c.key { ProgressView().tint(BP.inkMuted).scaleEffect(0.7) }
                }
                Text(c.label).font(BP.sans(14)).foregroundStyle(BP.ink).lineLimit(2)
                if let b = c.sizeBytes, b > 0 { Text(ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)).font(BP.sans(11)).foregroundStyle(BP.inkSubtle) }
            }
            .padding(BP.px(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge, lineWidth: 1))
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM))
        .focused($rowFocus, equals: "copy:" + c.key)
    }

    private func pick(copy: StreamsModel.HomeCopy) async {
        resolving = copy.key; resolveError = nil
        let r = await model.play(copy: copy, meta: meta)
        resolving = nil
        if r.ok, let ready = Self.playable(r) { onPlay(nil, ready) }
        else if r.ok, r.data != nil { resolveError = Self.badLinkMessage }   // (bug pass 2)
        else { resolveError = "This server couldn't start playback (\(r.code ?? "unknown"))." }
    }

    private func badges(_ s: ScoredStream) -> [String] {
        var out: [String] = []
        if s.isCached { out.append("Cached") }
        if let r = s.resolution, r != "unknown" { out.append(r) }
        if let h = s.hdrFormat { out.append(h) }
        if let c = s.codec, c != "unknown", c != "Other" { out.append(c) }
        if let a = s.audio?.codec, a != "Other" { out.append(a + ((s.audio?.channels ?? 0) >= 6 ? " 5.1" : "")) }
        if s.remux == true { out.append("Remux") }
        if let src = s.source, !["unknown", "other"].contains(src.lowercased()) { out.append(src) }
        return out
    }

    private func pick(_ s: ScoredStream) async {
        if autoState == .waiting || { if case .firing = autoState { return true }; return false }() { autoState = .cancelled }
        // use-pick-handler onPlay: an uncached torrent the P2P engine could stream asks first.
        if await model.p2pConsentNeeded(s) {
            if resolving == s.id { resolving = nil }
            dialog = .p2p(s)
            return
        }
        await start(s, forceP2p: false)
    }

    /// use-pick-handler startResolve + resolveAndOpen for a committed pick.
    private func start(_ s: ScoredStream, forceP2p: Bool) async {
        resolving = s.id; resolveError = nil
        let r = await resolveRetrying(s, forceP2p: forceP2p, sameSource: true) { resolving == s.id }
        guard alive, resolving == s.id else { return }
        resolving = nil
        if r.ok, let ready = Self.playable(r) {
            debridFailStreak = 0
            await model.remember(s, meta: meta, episode: episode, url: r.data?.url)
            // PlayerSrc.streamRef for use-stub-detection.ts; a pick by hand is never autoFired.
            var handed = ready
            handed.autoPicked = false
            handed.streamRef = await model.deadRef(s)
            onPlay(s, handed)
        } else if r.ok, r.data != nil {
            // (bug pass 2) The addon answered with a link no URL can be made of: say so (the call
            // sites used to drop it on `URL(string:)` and the picker just sat there).
            failedIds.insert(s.id)
            resolveError = Self.badLinkMessage
        } else {
            failedIds.insert(s.id)
            if countDebridFailure(r) { dialog = .debridDown; return }
            resolveError = r.message ?? "Couldn't get a playable link (\(r.code ?? "unknown")). Try another stream."
        }
    }

    static let badLinkMessage = "This stream's link isn't a valid address. Try another stream."

    /// (bug pass 2) The resolved result with its link as the player will open it (PlayableURL), or
    /// nil when there is no link or no URL can be made of it.
    static func playable(_ r: StreamsModel.Resolved) -> StreamsModel.Resolved? {
        guard var link = r.data, let url = PlayableURL.make(link.url) else { return nil }
        link.url = url.absoluteString
        var out = r
        out.data = link
        return out
    }
}

/// (bug pass 2) A resolved stream link as a URL. Some addons hand back links with spaces or other
/// characters a URL can't hold. The tvOS 17 SDK's `URL(string:)` already escapes most of those;
/// this also escapes a stray `%` and trims whitespace, keeping the `%XX` escapes already in the
/// link so nothing is encoded twice. nil when no absolute URL can be made of it.
enum PlayableURL {
    static func make(_ raw: String) -> URL? {
        if let u = URL(string: raw), u.scheme != nil { return u }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let u = URL(string: trimmed), u.scheme != nil { return u }
        // A `%` that does not start an escape is itself escaped; existing escapes stay as they are.
        let percents = trimmed.replacingOccurrences(of: "%(?![0-9A-Fa-f]{2})", with: "%25", options: .regularExpression)
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "%#[]")
        guard let encoded = percents.addingPercentEncoding(withAllowedCharacters: allowed),
              let u = URL(string: encoded), u.scheme != nil else { return nil }
        return u
    }
}

/// bp-stream-dialogs BpDialogShell: title, body, an optional detail card, then a row of buttons.
struct StreamDialogShell<Extra: View, Buttons: View>: View {
    let title: String
    let message: String
    let extra: Extra
    let buttons: Buttons

    init(title: String, message: String, @ViewBuilder extra: () -> Extra, @ViewBuilder buttons: () -> Buttons) {
        self.title = title
        self.message = message
        self.extra = extra()
        self.buttons = buttons()
    }

    var body: some View {
        ZStack {
            BP.void_.opacity(0.8).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(22)) {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    Text(T(title)).font(BP.display(26)).foregroundStyle(BP.ink).fixedSize(horizontal: false, vertical: true)
                    Text(T(message)).font(BP.sans(15)).foregroundStyle(BP.inkSubtle).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
                extra
                HStack(spacing: BP.px(12)) { buttons }
                    .focusSection()
            }
            .padding(BP.px(40))
            .frame(width: BP.px(720), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge2, lineWidth: 1))
        }
    }
}

/// bp-stream-row.tsx META (`flex flex-wrap`): the row's pills left to right, wrapping onto another
/// line when they run out of room instead of squeezing.
struct PickerFlowRow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth: CGFloat = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size: CGSize = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            widest = max(widest, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size: CGSize = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
