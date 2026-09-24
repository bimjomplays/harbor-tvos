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
    @StateObject private var model = StreamsModel()
    /// bp-stream-chips BpSourceKind, the kinds the TV has: "all" or "media-server" (no Local Library,
    /// and no streamMode chip, so "online" is never picked on its own).
    @State private var sourceKind = "all"
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
    @Environment(\.dismiss) private var dismiss

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
            BPAmbientBackground()
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
        .ignoresSafeArea()
        .task {
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
            while !Task.isCancelled, autoState == .waiting {
                try? await Task.sleep(for: .milliseconds(400))
                await autoTick(done: false)
            }
        }
        .task {
            // play-picker.tsx / auto-play-transition.tsx: consumeRecentStubEvent(8000) as the picker
            // opens; the notice clears itself after 6 s.
            let ev: String? = try? await HarborEngine.shared.call("deadStreams.consumeStubEvent", [8000])
            guard ev != nil, !Task.isCancelled else { return }
            stubNotice = true
            try? await Task.sleep(for: .seconds(6))
            stubNotice = false
        }
        .onChange(of: model.streams.count) { _, n in if n > 0, firstResultAt == nil { firstResultAt = Date() } }
        .onChange(of: model.copiesLoaded) { _, loaded in if loaded { Task { await applySourcePreference() } } }
        // bp-streams: BpNoSourcesDialog when there is no addon, no debrid and no home-server copy.
        .onChange(of: model.phase) { _, phase in
            // It outranks "tried N sources" (bp-streams shows that one only when !noSources).
            if phase == .done, model.addonCount == 0, model.debridCount == 0, model.copies.isEmpty, dialog == nil || dialog?.id == "exhausted" { dialog = .noSources }
        }
        // BpAutoExhaustedDialog: shown unless no sources or debrid down already explains it.
        .onChange(of: autoState) { _, state in
            if state == .exhausted, dialog == nil { dialog = .exhausted(autoTried) }
        }
        .onDisappear { alive = false; if autoState == .waiting { autoState = .cancelled }; model.cancel() }
        .fullScreenCover(item: $dialog) { d in dialogView(d) }
    }

    // bp-stream-dialogs.tsx, one view per dialog. Back acts like the seeded button's escape
    // (useSeededFocus onBack): Cancel, Back, Back, Browse sources.
    @ViewBuilder private func dialogView(_ d: PickerDialog) -> some View {
        switch d {
        case .p2p(let s):
            StreamDialogShell(title: "Stream this via peer-to-peer?",
                              message: "This source isn't cached on your debrid, so Harbor would pull it directly from peers. It can take a moment to start and may buffer on low-seed torrents.") {
                VStack(alignment: .leading, spacing: BP.px(6)) {
                    Text(s.parsedTitle ?? s.title ?? s.name ?? "This source").font(.system(size: BP.px(14), design: .monospaced)).foregroundStyle(BP.ink).lineLimit(2)
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
                              message: "Harbor needs at least one streaming source before it can play \(meta.name). Install a stream addon or add a debrid key in settings.") {
                EmptyView()
            } buttons: {
                Button("Back") { closePicker() }.buttonStyle(BPActionStyle(primary: true))
            }
            .onExitCommand { closePicker() }
        case .exhausted(let n):
            StreamDialogShell(title: "We could not find a working stream",
                              message: "Harbor tried \(n) sources for \(exhaustedLabel) and none of them played. Usually that means a debrid key has expired, no stream addon is installed yet, or nothing has this title cached.") {
                EmptyView()
            } buttons: {
                Button("Browse sources") { browseManually() }.buttonStyle(BPActionStyle(primary: true))
                Button("Back") { closePicker() }.buttonStyle(BPActionStyle())
            }
            .onExitCommand { browseManually() }
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
        guard let first = candidates.dropFirst(autoTried).first, model.streams.indices.contains(first) else {
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
        if r.ok, r.data != nil {
            debridFailStreak = 0
            await model.remember(s, meta: meta, episode: episode, url: r.data?.url)
            // use-pick-handler: PlayerSrc.autoFired + streamRef, so a stall or a failed open can
            // mark this stream dead and bring the picker back on the next candidate (views/player.tsx).
            var handed = r
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
        case .searching:
            HStack(spacing: BP.px(8)) {
                ProgressView().tint(BP.inkMuted)
                Text(model.progress.total > 0 ? "Asking addons… \(model.progress.settled)/\(model.progress.total)" : "Asking your addons…").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
            }
        case .done:
            Text(model.streams.isEmpty ? (model.addonCount == 0 ? "No stream addons installed. Sign in to Stremio or add addons." : "No streams found.") : "\(model.streams.count) streams from \(model.addonCount) addons")
                .font(BP.sans(14)).foregroundStyle(BP.inkMuted)
            // bp-streams ladder: when the filters left nothing, widen the search, then show everything.
            if model.streams.isEmpty, model.addonCount > 0, model.canLoosen {
                HStack(spacing: BP.px(8)) {
                    if model.strict { Button("Search wider") { Task { await model.searchWider() } }.buttonStyle(BPActionStyle(primary: true)) }
                    if !model.showAll { Button("Show everything") { Task { await model.showEverything() } }.buttonStyle(BPActionStyle()) }
                }
            }
        case .failed(let why): BPNote(text: why, tone: BP.danger)
        case .idle: EmptyView()
        }
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
    /// bp-stream-filters sort: "harbor" (score order) or "addon" (each addon's own order, addons in install order).
    @State private var sortByAddon = false

    private func matchesFacets(_ s: ScoredStream, except: String? = nil) -> Bool {
        for f in Self.facets where f.key != except {
            guard let sel = facet[f.key] else { continue }
            if f.valueOf(s) != sel { return false }
        }
        return true
    }

    private func facetOptions(_ f: Facet) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for s in pool where matchesFacets(s, except: f.key) && (!cachedOnly || s.isCached) {
            if let v = f.valueOf(s) { counts[v, default: 0] += 1 }
        }
        return f.order.compactMap { k in counts[k].map { (k, $0) } }
    }

    private var filtered: Bool { quality != "All" || cachedOnly || addonFilter != nil || !facet.isEmpty }

    /// bp-stream-filters `base`: the active saved filter narrows the pool the chips and the list
    /// work on; when nothing passes it, every stream stays and the banner says so (filterFellBack).
    private var filterPool: (streams: [ScoredStream], fellBack: Bool) {
        guard let id = model.activeFilterId, !model.streams.isEmpty else { return (model.streams, false) }
        let matched = model.streams.filter { $0.tvFilters?.contains(id) ?? true }
        return matched.isEmpty ? (model.streams, true) : (matched, false)
    }
    private var pool: [ScoredStream] { filterPool.streams }

    /// bp-streams showOnline / showHomeServers for the TV's two kinds.
    private var showOnline: Bool { sourceKind == "all" }

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
            (!cachedOnly || s.isCached) &&
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
            sorted = filtered.sorted { a, b in a.isCached != b.isCached ? a.isCached : a.index < b.index }
        }
        return pinnedFirst(sorted)
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
                    }
                }
                if pool.contains(where: \.isCached) {
                    Button("Cached") { cachedOnly.toggle() }.buttonStyle(BPActionStyle(primary: cachedOnly))
                }
                if addons.count > 1 {
                    Rectangle().fill(BP.edge2).frame(width: 1, height: BP.px(24))
                    Button(addonFilter ?? "All addons") {
                        let list = [nil] + addons.map { Optional($0) }
                        let i = list.firstIndex { $0 == addonFilter } ?? 0
                        addonFilter = list[(i + 1) % list.count]
                    }.buttonStyle(BPActionStyle(primary: addonFilter != nil))
                }
                // Facet chips cycle All → each value that exists (with counts), like bp-stream-menu.
                ForEach(Self.facets, id: \.key) { f in
                    let opts = facetOptions(f)
                    if opts.count > 1 || facet[f.key] != nil {
                        Button(facet[f.key].map { v in "\(f.label): \(v) \(opts.first { $0.0 == v }?.1 ?? 0)" } ?? f.label) {
                            let keys = opts.map(\.0)
                            if let cur = facet[f.key], let i = keys.firstIndex(of: cur) {
                                if i + 1 < keys.count { facet[f.key] = keys[i + 1] } else { facet[f.key] = nil }
                            } else { facet[f.key] = keys.first }
                        }.buttonStyle(BPActionStyle(primary: facet[f.key] != nil))
                    }
                }
                // bp-stream-chips source-kind chip: every source, or only the home-server copies.
                if !model.copies.isEmpty || sourceKind != "all" {
                    Button(T(sourceKind == "media-server" ? "Media servers" : "All sources")) {
                        sourceKind = sourceKind == "media-server" ? "all" : "media-server"
                    }.buttonStyle(BPActionStyle(primary: sourceKind != "all"))
                }
                // bp-stream-chips filter chip: the saved stream filters (Settings → Stream filters on
                // the desktop), No filter first.
                if !model.savedFilters.isEmpty {
                    Button { nextFilter() } label: { Label(filterChipLabel, systemImage: "line.3.horizontal.decrease") }
                        .buttonStyle(BPActionStyle(primary: model.activeFilterId != nil))
                }
                Rectangle().fill(BP.edge2).frame(width: 1, height: BP.px(24))
                Button(sortByAddon ? "Sort: addon order" : "Sort: Harbor") { sortByAddon.toggle() }.buttonStyle(BPActionStyle())
                if filtered {
                    Button("Clear filters") { quality = "All"; cachedOnly = false; addonFilter = nil; facet = [:] }.buttonStyle(BPActionStyle())
                }
            }
            .padding(.vertical, BP.px(6))
        }
        .scrollClipDisabled()
        .focusSection()
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
                    if !model.copies.isEmpty {
                        Text("On your home servers").font(BP.sans(12, .bold)).textCase(.uppercase).tracking(0.6).foregroundStyle(BP.inkMuted)
                        ForEach(model.copies) { c in copyRow(c) }
                        if showOnline, !model.streams.isEmpty { Text("Addons").font(BP.sans(12, .bold)).textCase(.uppercase).tracking(0.6).foregroundStyle(BP.inkMuted).padding(.top, BP.px(6)) }
                    }
                    if showOnline {
                        ForEach(visible) { s in row(s, highlight: s.id == model.primary?.id) }
                        if !model.streams.isEmpty && visible.isEmpty { BPNote(text: "Nothing matches these filters.") }
                    } else if model.copies.isEmpty {
                        BPNote(text: model.copiesLoaded ? "No sources match these filters" : "Looking for sources")
                    }
                    Color.clear.frame(height: BP.px(60))
                }
                .padding(.vertical, BP.px(6))
            }
            .focusSection()
        }
    }

    private func row(_ s: ScoredStream, highlight: Bool) -> some View {
        Button { handPicked = true; Task { await pick(s) } } label: {
            VStack(alignment: .leading, spacing: BP.px(5)) {
                HStack(spacing: BP.px(8)) {
                    ForEach(badges(s), id: \.self) { b in
                        Text(b).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(0.4)
                            .foregroundStyle(b == "Cached" ? BP.canvas : BP.ink)
                            .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2))
                            .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(b == "Cached" ? BP.live : BP.on))
                    }
                    Spacer()
                    // bp-stream-row: the remembered pick wears "Played last".
                    if model.rememberedIndex == s.index {
                        Label("Played last", systemImage: "clock.arrow.circlepath")
                            .font(BP.sans(10.5, .bold)).foregroundStyle(BP.ink)
                            .padding(.horizontal, BP.px(7)).padding(.vertical, BP.px(2))
                            .background(Capsule().fill(BP.glass))
                    }
                    Text(s.addonName).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted)
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
        .disabled(resolving != nil)
        .accessibilityIdentifier("stream-\(s.index)")
    }

    /// A copy on a Plex/Jellyfin/Emby server (bp-streams home-server rows): direct play or transcode through the server.
    private func copyRow(_ c: StreamsModel.HomeCopy) -> some View {
        Button { handPicked = true; Task { await pick(copy: c) } } label: {
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
        .disabled(resolving != nil)
    }

    private func pick(copy: StreamsModel.HomeCopy) async {
        resolving = copy.key; resolveError = nil
        let r = await model.play(copy: copy, meta: meta)
        resolving = nil
        if r.ok, r.data != nil { onPlay(nil, r) } else { resolveError = "This server couldn't start playback (\(r.code ?? "unknown"))." }
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
        if await model.p2pConsentNeeded(s) { dialog = .p2p(s); return }
        await start(s, forceP2p: false)
    }

    /// use-pick-handler startResolve + resolveAndOpen for a committed pick.
    private func start(_ s: ScoredStream, forceP2p: Bool) async {
        resolving = s.id; resolveError = nil
        let r = await resolveRetrying(s, forceP2p: forceP2p, sameSource: true) { resolving == s.id }
        guard alive, resolving == s.id else { return }
        resolving = nil
        if r.ok, r.data != nil {
            debridFailStreak = 0
            await model.remember(s, meta: meta, episode: episode, url: r.data?.url)
            // PlayerSrc.streamRef for use-stub-detection.ts; a pick by hand is never autoFired.
            var handed = r
            handed.autoPicked = false
            handed.streamRef = await model.deadRef(s)
            onPlay(s, handed)
        } else {
            failedIds.insert(s.id)
            if countDebridFailure(r) { dialog = .debridDown; return }
            resolveError = r.message ?? "Couldn't get a playable link (\(r.code ?? "unknown")). Try another stream."
        }
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
