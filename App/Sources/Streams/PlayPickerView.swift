import SwiftUI

/// Stream picker: the ranked list grouped by quality tier, best cached pick first.
struct PlayPickerView: View {
    let meta: Meta
    let episode: AnyJSON?
    let onPlay: (ScoredStream?, StreamsModel.Resolved) -> Void
    /// use-bp-stream-play autoPlay: fire the best candidate once the pipeline settles (instantPlay).
    var autoPlay = false
    @StateObject private var model = StreamsModel()
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
    @Environment(\.dismiss) private var dismiss

    /// bp-stream-chips.tsx quality chips, mapped onto the parser's resolution values.
    private static let qualities: [(String, [String])] = [("All", []), ("4K UHD", ["2160p", "4K"]), ("1080p", ["1080p"]), ("720p", ["720p"]), ("480p", ["480p"]), ("SD", ["SD", "360p", "240p"])]

    var body: some View {
        ZStack {
            BPAmbientBackground()
            HStack(alignment: .top, spacing: BP.px(40)) {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    Text("Play").font(BP.sans(11, .bold)).foregroundStyle(BP.accent).textCase(.uppercase).tracking(1)
                    Text(meta.name).font(BP.display(30)).foregroundStyle(BP.ink).lineLimit(3)
                    if let ep = episodeLabel { Text(ep).font(BP.sans(16, .semibold)).foregroundStyle(BP.inkMuted) }
                    statusLine
                    if let resolveError { BPNote(text: resolveError, tone: BP.danger) }
                    RemoteImage(url: meta.poster).frame(width: BP.px(177), height: BP.px(265)).clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous)).padding(.top, BP.px(10))
                }
                .frame(width: BP.px(300), alignment: .leading)
                list
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.px(50))
        }
        .ignoresSafeArea()
        .task {
            if autoPlay { autoState = .waiting; startedAt = Date() }
            await model.search(meta: meta, episode: episode)
            await autoTick(done: true)
        }
        .task {
            // use-auto-fire: settle windows (1.5 s after the first result, 4 s when no cached exact episode,
            // 10 s cap) so a fast addon does not beat a better one by a few hundred milliseconds.
            guard autoPlay else { return }
            while !Task.isCancelled, autoState == .waiting {
                try? await Task.sleep(for: .milliseconds(400))
                await autoTick(done: false)
            }
        }
        .onChange(of: model.streams.count) { _, n in if n > 0, firstResultAt == nil { firstResultAt = Date() } }
        .onDisappear { if autoState == .waiting { autoState = .cancelled }; model.cancel() }
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
        let candidates = await model.autoCandidates(meta: meta, episode: episode)
        guard autoState == .waiting else { return }
        guard let first = candidates.dropFirst(autoTried).first, model.streams.indices.contains(first) else {
            if done || model.phase == .done || sinceStart >= 10 { autoState = .exhausted }
            return
        }
        let s = model.streams[first]
        autoState = .firing(s.id)
        resolving = s.id
        let r = await model.resolve(s)
        guard case .firing = autoState, !Task.isCancelled else { return }   // the viewer picked by hand, or left
        resolving = nil
        if r.ok, r.data != nil {
            await model.remember(s, meta: meta, episode: episode, url: r.data?.url)
            onPlay(s, r)
        } else {
            autoTried += 1
            autoState = autoTried >= 3 ? .exhausted : .waiting
            if autoState == .exhausted { resolveError = "Harbor couldn't start any source. Pick one." }
        }
    }

    @ViewBuilder private var autoBanner: some View {
        switch autoState {
        case .waiting, .firing:
            HStack(spacing: BP.px(8)) {
                ProgressView().tint(BP.accent)
                Text(autoState == .waiting ? "Finding the best source…" : "Starting…").font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
                Button("Choose instead") { autoState = .cancelled }.buttonStyle(BPActionStyle())
            }
        case .exhausted: BPNote(text: "Nothing started on its own. Pick a source.", tone: BP.inkMuted)
        default: EmptyView()
        }
    }

    @ViewBuilder private var statusLine: some View {
        autoBanner
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
        for s in model.streams where matchesFacets(s, except: f.key) && (!cachedOnly || s.isCached) {
            if let v = f.valueOf(s) { counts[v, default: 0] += 1 }
        }
        return f.order.compactMap { k in counts[k].map { (k, $0) } }
    }

    private var filtered: Bool { quality != "All" || cachedOnly || addonFilter != nil || !facet.isEmpty }

    private var visible: [ScoredStream] {
        let wanted = Self.qualities.first { $0.0 == quality }?.1 ?? []
        let filtered = model.streams.filter { s in
            (wanted.isEmpty || wanted.contains(s.resolution ?? "")) &&
            (!cachedOnly || s.isCached) &&
            (addonFilter == nil || s.addonName == addonFilter) &&
            matchesFacets(s)
        }
        if sortByAddon {
            // orderByAddonNative: addons in the installed order, each stream where its addon listed it.
            var rank: [String: Int] = [:]
            for (i, url) in model.addonOrder.enumerated() { rank[url] = i }
            return filtered.sorted { a, b in
                let ra = a.addonUrl.flatMap { rank[$0] } ?? 9999, rb = b.addonUrl.flatMap { rank[$0] } ?? 9999
                if ra != rb { return ra < rb }
                let na = a.nativeIdx ?? Int.max, nb = b.nativeIdx ?? Int.max
                return na != nb ? na < nb : a.index < b.index
            }
        }
        return filtered.sorted { a, b in a.isCached != b.isCached ? a.isCached : a.index < b.index }
    }

    private var addons: [String] { Array(Set(model.streams.map(\.addonName))).sorted() }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BP.px(8)) {
                ForEach(Self.qualities, id: \.0) { q in
                    let n = q.1.isEmpty ? model.streams.count : model.streams.filter { q.1.contains($0.resolution ?? "") }.count
                    if n > 0 || q.0 == "All" {
                        Button("\(q.0) \(n)") { quality = q.0 }.buttonStyle(BPActionStyle(primary: quality == q.0))
                    }
                }
                if model.streams.contains(where: \.isCached) {
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
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: BP.px(10)) {
                    if !model.copies.isEmpty {
                        Text("On your home servers").font(BP.sans(12, .bold)).textCase(.uppercase).tracking(0.6).foregroundStyle(BP.inkMuted)
                        ForEach(model.copies) { c in copyRow(c) }
                        if !model.streams.isEmpty { Text("Addons").font(BP.sans(12, .bold)).textCase(.uppercase).tracking(0.6).foregroundStyle(BP.inkMuted).padding(.top, BP.px(6)) }
                    }
                    ForEach(visible) { s in row(s, highlight: s.id == model.primary?.id) }
                    if !model.streams.isEmpty && visible.isEmpty { BPNote(text: "Nothing matches these filters.") }
                    Color.clear.frame(height: BP.px(60))
                }
                .padding(.vertical, BP.px(6))
            }
            .focusSection()
        }
    }

    private func row(_ s: ScoredStream, highlight: Bool) -> some View {
        Button { Task { await pick(s) } } label: {
            VStack(alignment: .leading, spacing: BP.px(5)) {
                HStack(spacing: BP.px(8)) {
                    ForEach(badges(s), id: \.self) { b in
                        Text(b).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(0.4)
                            .foregroundStyle(b == "Cached" ? BP.canvas : BP.ink)
                            .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2))
                            .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(b == "Cached" ? BP.live : BP.on))
                    }
                    Spacer()
                    Text(s.addonName).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted)
                    if resolving == s.id { ProgressView().tint(BP.inkMuted).scaleEffect(0.7) }
                }
                Text(s.parsedTitle ?? s.title ?? s.name ?? "Stream").font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                HStack(spacing: BP.px(10)) {
                    if let g = s.releaseGroup { Text(g) }
                    if let sz = s.sizeText { Text(sz) }
                    if let seeds = s.seeders, seeds > 0 { Text("\(Int(seeds)) seeders") }
                    if let langs = s.audioLanguages, !langs.isEmpty { Text(langs.prefix(3).joined(separator: ", ")) }
                }
                .font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
            }
            .padding(BP.px(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(highlight ? BP.panel2 : BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(highlight ? BP.accent.opacity(0.6) : BP.edge, lineWidth: 1))
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM))
        .disabled(resolving != nil)
        .accessibilityIdentifier("stream-\(s.index)")
    }

    /// A copy on a Plex/Jellyfin/Emby server (bp-streams home-server rows): direct play or transcode through the server.
    private func copyRow(_ c: StreamsModel.HomeCopy) -> some View {
        Button { Task { await pick(copy: c) } } label: {
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
        resolving = s.id; resolveError = nil
        let r = await model.resolve(s)
        resolving = nil
        if r.ok, r.data != nil {
            await model.remember(s, meta: meta, episode: episode, url: r.data?.url)
            onPlay(s, r)
        } else {
            resolveError = "Couldn't get a playable link (\(r.code ?? "unknown")). Try another stream."
        }
    }
}
