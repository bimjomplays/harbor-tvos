import SwiftUI

/// bp-player-subtitles.tsx: the in-player Subtitles dialog. Four lanes (Tracks, Find more, Sync,
/// Look) under a header that says what is on and how far it is shifted. The labels, badges and
/// best-match order come from the engine (`subtitles.trackView`), which runs upstream's own
/// track-label / classification / best-match code.
struct PlayerSubtitlesPanel: View {
    let controller: (any PlayerEngineControlling)?
    let context: PlaybackContext?
    let title: String
    @Binding var subDelay: Double
    let onClose: () -> Void
    /// The AVPlayer engine shows the file's own subtitle options only: no sideloaded (Find more),
    /// shifted (Sync), restyled (Look) or second subtitle.
    private var mpvExtras: Bool { controller?.supportsMpvExtras ?? true }

    enum Lane: Hashable { case tracks, find, sync, style }

    struct TrackRow: Decodable { var id: String; var keep: Bool; var langKey: String; var langDisplay: String; var title: String; var detail: String; var tags: [String] }
    struct Ranked: Decodable { var id: String; var eligible: Bool }
    struct TrackView: Decodable { var tracks: [TrackRow]; var ranked: [Ranked] }
    struct TrackIn: Encodable {
        var id: Int
        var lang: String?
        var title: String?
        var codec: String?
        var external: Bool
        var forced: Bool
        var hearingImpaired: Bool
        var `default`: Bool
        var selected: Bool
        var secondary: Bool
        var externalFilename: String?
    }
    struct LangGroup: Identifiable { var id: String; var display: String; var count: Int }
    /// bp-subtitle-find.tsx BpSubtitleTarget.
    struct Target: Codable, Equatable { var imdbId: String; var type: String; var title: String; var season: Int?; var episode: Int? }
    struct Found: Decodable, Identifiable {
        var id: String; var url: String; var lang: String; var langName: String; var title: String
        var detail: String; var tags: [String]; var provider: String; var hearingImpaired: Bool; var forced: Bool
    }
    struct FindResult: Decodable { var results: [Found]; var tooNew: Bool }
    struct Preset: Decodable, Identifiable { var id: String; var name: String; var values: [String: AnyJSON] }

    private static let all = "__all__"
    private static let page = 40

    @State private var lane: Lane = .tracks
    @State private var tracks: [MPVPlayerController.Track] = []
    @State private var rows: [String: TrackRow] = [:]
    @State private var ranked: [Ranked] = []
    @State private var activeLang = PlayerSubtitlesPanel.all
    @State private var source = "all"
    @State private var hideHI = false
    @State private var forcedOnly = false
    @FocusState private var focus: String?
    @ObservedObject private var settings = SettingsBridge.shared
    @State private var presets: [Preset] = []

    // Find more (bp-subtitle-find.tsx)
    @State private var target: Target?
    @State private var override = false
    @State private var query = ""
    @State private var results: [Found]?
    @State private var tooNew = false
    @State private var searching = false
    @State private var limit = PlayerSubtitlesPanel.page
    @State private var seq = 0
    @State private var ranOnce = false
    @State private var added: Set<String> = []
    @State private var findNote: String?

    var body: some View {
        ZStack {
            BP.void_.opacity(0.88).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: BP.px(5)) {
                    Label("Subtitles", systemImage: "captions.bubble").font(BP.display(26)).foregroundStyle(BP.ink)
                    Text(headerLine).font(BP.sans(13, .medium)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                }
                .padding(.top, BP.px(24))

                HStack(spacing: BP.px(8)) {
                    laneChip(.tracks, "Tracks", "captions.bubble")
                    if mpvExtras {
                        laneChip(.find, "Find more", "magnifyingglass")
                        laneChip(.sync, "Sync", "timer")
                        laneChip(.style, "Look", "slider.horizontal.3")
                    }
                    Spacer(minLength: 0)
                    Button { onClose() } label: { Label("Close", systemImage: "xmark") }
                        .buttonStyle(PlayerChipStyle())
                        .focused($focus, equals: "close")
                }
                .padding(.vertical, BP.px(10))
                .focusSection()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: BP.px(8)) {
                        switch lane {
                        case .tracks: tracksLane
                        case .find: findLane
                        case .sync: syncLane
                        case .style: lookLane
                        }
                    }
                    .padding(.horizontal, BP.px(6))
                    .padding(.top, BP.px(6)).padding(.bottom, BP.px(24))
                }
                .focusSection()
            }
            .padding(.horizontal, BP.px(30))
            .frame(width: BP.px(1049), height: BP.px(551), alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge, lineWidth: 1))
        }
        .onAppear {
            if target == nil { target = home; query = context?.meta.name ?? title }
            Task {
                await refresh()
                seedFocus()
                if let list = try? await loadPresets() { presets = list }
            }
        }
        .onChange(of: lane) {
            if lane == .find, !ranOnce, let t = target {
                ranOnce = true
                Task { await run(t) }
            }
            seedFocus()
        }
    }

    // MARK: header + lanes

    private var isSeries: Bool { context?.season != nil && context?.episode != nil }

    private var headerLine: String {
        let name = context?.meta.name ?? title
        let where_: String
        if isSeries, let s = context?.season, let e = context?.episode {
            where_ = "\(name) · S\(String(format: "%02d", s))E\(String(format: "%02d", e))"
        } else {
            where_ = name
        }
        let on = tracks.first { $0.selected }.map { titleOf($0) } ?? "Off"
        return "\(where_) · \(on) · \(offsetLabel)"
    }

    /// bp-subtitle-parts.tsx offsetLabel.
    private var offsetLabel: String {
        subDelay == 0 ? "In sync" : "\(subDelay > 0 ? "+" : "")\(String(format: "%.1f", subDelay))s"
    }

    private func laneChip(_ id: Lane, _ label: String, _ icon: String) -> some View {
        Button { lane = id } label: { Label(T(label), systemImage: icon) }
            .buttonStyle(PlayerChipStyle(on: lane == id))
            .focused($focus, equals: "lane-\(label)")
    }

    /// `id` names the focus target when the label alone is not unique (a stepper's − and +).
    private func chip(_ label: String, on: Bool = false, icon: String? = nil, id: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let icon { Label(T(label), systemImage: icon) } else { Text(T(label)) }
        }
        .buttonStyle(PlayerChipStyle(on: on))
        .focused($focus, equals: id ?? "chip-\(label)")
    }

    private func note(_ text: String) -> some View {
        Text(T(text)).font(BP.sans(13, .medium)).foregroundStyle(BP.inkSubtle).padding(.vertical, BP.px(4))
    }

    /// The shell seeds focus from the panel id, never the lane, so each lane seeds its own ring.
    private func seedFocus() {
        let seed: String
        switch lane {
        case .tracks: seed = tracks.first { $0.selected }.map { "line-\($0.id)" } ?? "line-off"
        case .find: seed = "chip-Search"
        case .sync: seed = "chip--0.1s"
        case .style: seed = presets.first.map { "chip-\($0.name)" } ?? "chip-Shadow"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { focus = seed }
    }

    // MARK: Tracks

    private func row(_ t: MPVPlayerController.Track) -> TrackRow? { rows[String(t.id)] }
    private func titleOf(_ t: MPVPlayerController.Track) -> String { row(t)?.title ?? t.label }

    /// langTracks: the viewer's languages, plus whatever is selected or secondary.
    private var langTracks: [MPVPlayerController.Track] { tracks.filter { row($0)?.keep ?? true } }

    /// groupByLang, in first-seen order.
    private var groups: [LangGroup] {
        var out: [LangGroup] = []
        for t in langTracks {
            let key = row(t)?.langKey ?? "embedded"
            if let i = out.firstIndex(where: { $0.id == key }) { out[i].count += 1 }
            else { out.append(LangGroup(id: key, display: row(t)?.langDisplay ?? "Embedded", count: 1)) }
        }
        return out
    }

    private var visible: [MPVPlayerController.Track] {
        let pool = activeLang == Self.all ? langTracks : langTracks.filter { row($0)?.langKey == activeLang }
        return pool.filter { t in
            if source == "embedded" && t.external { return false }
            if source == "external" && !t.external { return false }
            if hideHI && t.hearingImpaired { return false }
            return !(forcedOnly && !t.forced)
        }
    }

    /// best-match.ts pickBestMatch(visible): the first ranked track inside the pool, if it clears the gate.
    private var best: MPVPlayerController.Track? {
        let ids = Set(visible.map { String($0.id) })
        guard let top = ranked.first(where: { ids.contains($0.id) }), top.eligible else { return nil }
        return visible.first { String($0.id) == top.id }
    }

    @ViewBuilder private var tracksLane: some View {
        PlayerChipRow {
            PlayerRowLabel(text: "Languages")
            chip("All languages \(langTracks.count)", on: activeLang == Self.all) { activeLang = Self.all }
            ForEach(groups) { g in
                chip("\(g.display) \(g.count)", on: activeLang == g.id) { activeLang = g.id }
            }
        }
        PlayerChipRow {
            PlayerRowLabel(text: "Filters")
            chip("All", on: source == "all") { source = "all" }
            chip("Embedded", on: source == "embedded") { source = "embedded" }
            chip("External", on: source == "external") { source = "external" }
            chip("Hide HI/SDH", on: hideHI) { hideHI.toggle() }
            chip("Forced only", on: forcedOnly) { forcedOnly.toggle() }
        }
        if let better = best, !better.selected {
            PlayerChipRow {
                PlayerRowLabel(text: "Better match")
                chip(titleOf(better)) { select(better) }
            }
        }
        let noneOn = !tracks.contains { $0.selected }
        Button { select(nil) } label: {
            PlayerLineLabel(icon: noneOn ? "checkmark" : "captions.bubble.fill", title: "No subtitles")
        }
        .buttonStyle(PlayerLineStyle(on: noneOn))
        .focused($focus, equals: "line-off")
        ForEach(visible) { t in trackLine(t) }
        if visible.isEmpty {
            note("No tracks match these filters. Try toggling HI/SDH or Forced.")
        }
        if !mpvExtras {
            note("AVPlayer shows the file's own subtitles. Online subtitles, sync, style and a second track need the mpv engine.")
        }
    }

    private func trackLine(_ t: MPVPlayerController.Track) -> some View {
        var badges = row(t)?.tags ?? []
        if best?.id == t.id { badges.insert("Best match", at: 0) }
        return HStack(spacing: BP.px(10)) {
            Button { select(t) } label: {
                PlayerLineLabel(icon: t.selected ? "checkmark" : "captions.bubble", title: titleOf(t), detail: row(t)?.detail, badges: badges)
            }
            .buttonStyle(PlayerLineStyle(on: t.selected))
            .focused($focus, equals: "line-\(t.id)")
            // setSecondarySub: a second track under the first, or off again (mpv only).
            if mpvExtras {
                Button {
                    controller?.setSecondarySub(t.secondary ? nil : t)
                    refreshSoon()
                } label: { Label("2nd", systemImage: "character.bubble") }
                    .buttonStyle(PlayerChipStyle(on: t.secondary))
                    .focused($focus, equals: "second-\(t.id)")
            }
        }
    }

    private func select(_ t: MPVPlayerController.Track?) {
        controller?.select(track: t, type: "sub")
        refreshSoon()
    }

    private func refreshSoon() {
        Task {
            await refresh()
            try? await Task.sleep(for: .milliseconds(250))
            await refresh()
        }
    }

    /// mpv's subtitle tracks, then upstream's labels and best-match order for them.
    private func refresh() async {
        let list = (controller?.tracks() ?? []).filter { $0.type == "sub" }
        tracks = list
        let ins = list.map { t in
            TrackIn(id: t.id, lang: t.lang, title: t.title, codec: t.codec, external: t.external, forced: t.forced,
                    hearingImpaired: t.hearingImpaired, default: t.isDefault, selected: t.selected, secondary: t.secondary,
                    externalFilename: t.externalFilename)
        }
        let p = ProfilesStore.shared.active
        do {
            let view: TrackView = try await HarborEngine.shared.call("subtitles.trackView",
                [p?.id ?? "default", p?.linked ?? true, ins, controller?.streamFilename(), context?.season, context?.episode])
            var byId: [String: TrackRow] = [:]
            for r in view.tracks { byId[r.id] = r }
            rows = byId
            ranked = view.ranked
        } catch {
            rows = [:]
            ranked = []
        }
    }

    // MARK: Find more (bp-subtitle-find.tsx)

    private var home: Target {
        let meta = context?.meta
        let imdb = context?.imdbId ?? ((meta?.id.hasPrefix("tt") ?? false) ? (meta?.id ?? "") : "")
        return Target(imdbId: imdb, type: isSeries ? "series" : "movie", title: meta?.name ?? title,
                      season: isSeries ? context?.season : nil, episode: isSeries ? context?.episode : nil)
    }

    /// Results without the filtered-out HI / non-forced entries, grouped by language in first-seen order.
    private var flat: [Found] {
        let kept = (results ?? []).filter { !(hideHI && $0.hearingImpaired) && !(forcedOnly && !$0.forced) }
        var order: [String] = []
        var byLang: [String: [Found]] = [:]
        for r in kept {
            if byLang[r.langName] == nil { order.append(r.langName) }
            byLang[r.langName, default: []].append(r)
        }
        return order.flatMap { byLang[$0] ?? [] }
    }

    @ViewBuilder private var findLane: some View {
        BPField(label: "Search", placeholder: "Search any show or movie", text: $query)
            .frame(maxWidth: BP.px(620))
            .onSubmit { Task { await submit() } }
        PlayerChipRow {
            chip(searching ? "Searching…" : "Search", icon: "magnifyingglass", id: "chip-Search") { Task { await submit() } }
            if override {
                chip("Back to what's playing") {
                    override = false
                    query = context?.meta.name ?? title
                    target = home
                    Task { await run(home) }
                }
            }
            if let t = target, t.type == "series" {
                stepper("Season", value: t.season ?? 1, reset: { Task { await run(t) } }) { d in changeEp(season: max(1, (t.season ?? 1) + d), episode: t.episode) }
                stepper("Episode", value: t.episode ?? 1, reset: { Task { await run(t) } }) { d in changeEp(season: t.season, episode: max(1, (t.episode ?? 1) + d)) }
            }
            chip("Hide HI/SDH", on: hideHI) { hideHI.toggle() }
            chip("Forced only", on: forcedOnly) { forcedOnly.toggle() }
        }
        findResults
    }

    @ViewBuilder private var findResults: some View {
        if searching { note("Searching…") }
        if let findNote { note(findNote) }
        let list = flat
        if results != nil, list.isEmpty, !searching {
            note(tooNew ? "Too new. Subtitles haven't been published yet." : "No subtitles found. Try another title above, or adjust the season and episode.")
        }
        ForEach(Array(list.prefix(limit).enumerated()), id: \.element.id) { i, r in
            if i == 0 || list[i - 1].langName != r.langName { PlayerRowLabel(text: r.langName).padding(.top, BP.px(6)) }
            let isAdded = added.contains(r.url)
            Button {
                Task { await add(r) }
            } label: {
                PlayerLineLabel(icon: isAdded ? "checkmark" : "plus", title: r.title, detail: r.detail, badges: isAdded ? ["Added"] + r.tags : r.tags)
            }
            .buttonStyle(PlayerLineStyle())
            .focused($focus, equals: "find-\(r.id)")
        }
        if list.count > limit {
            PlayerChipRow {
                chip("Show \(list.count - limit) more") { limit += Self.page }
            }
        }
    }

    /// bp-subtitle-parts.tsx Stepper: − / value (resets) / +.
    private func stepper(_ label: String, value: Int, reset: @escaping () -> Void, step: @escaping (Int) -> Void) -> some View {
        HStack(spacing: BP.px(8)) {
            PlayerRowLabel(text: label)
            chip("−", id: "dec-\(label)", action: { step(-1) })
            chip("\(value)", id: "val-\(label)", action: reset)
            chip("+", id: "inc-\(label)", action: { step(1) })
        }
    }

    private func changeEp(season: Int?, episode: Int?) {
        guard var t = target else { return }
        t.season = season
        t.episode = episode
        target = t
        Task { await run(t) }
    }

    private func run(_ t: Target) async {
        seq += 1
        let mine = seq
        searching = true
        results = nil
        limit = Self.page
        findNote = nil
        let p = ProfilesStore.shared.active
        let authKey = p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
        let found: FindResult?
        do {
            let r: FindResult = try await HarborEngine.shared.call("subtitles.find",
                [p?.id ?? "default", p?.linked ?? true, authKey, t, home, context?.meta.id, context?.meta.releaseDate])
            found = r
        } catch {
            found = nil
            findNote = error.localizedDescription
        }
        guard mine == seq else { return }
        results = found?.results ?? []
        tooNew = found?.tooNew ?? false
        searching = false
    }

    /// submit(): a typed title (with an optional "S2E5" or year) becomes the new target.
    private func submit() async {
        guard let current = target else { return }
        searching = true
        results = nil
        let resolved: Target?
        do {
            let t: Target = try await HarborEngine.shared.call("subtitles.titleTarget", [query, current])
            resolved = t
        } catch {
            resolved = nil
        }
        guard let next = resolved else { await run(current); return }
        target = next
        override = true
        await run(next)
    }

    /// Download + decode through the engine (zips, encodings), then hand mpv a local file.
    private func add(_ r: Found) async {
        struct Prepared: Decodable { var text: String; var format: String }
        do {
            let prep: Prepared = try await HarborEngine.shared.call("subtitles.prepare", [r.url])
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("subs", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safe = r.id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            let file = dir.appendingPathComponent("\(safe).\(prep.format)")
            try prep.text.write(to: file, atomically: true, encoding: .utf8)
            controller?.addSubtitle(file: file, title: r.title, lang: r.lang)
            added.insert(r.url)
            findNote = nil
            refreshSoon()
        } catch {
            findNote = "Couldn't load that subtitle: \(error.localizedDescription)"
        }
    }

    // MARK: Sync (bp-subtitle-tune.tsx BpSubtitleSync, manual offset)

    @ViewBuilder private var syncLane: some View {
        PlayerChipRow {
            PlayerRowLabel(text: "Manual offset")
            ForEach([-1.0, -0.1, 0.1, 1.0], id: \.self) { step in
                chip("\(step > 0 ? "+" : "")\(String(format: "%.1f", step))s") { setDelay(((subDelay + step) * 10).rounded() / 10) }
            }
            Text(offsetLabel).font(BP.display(30)).foregroundStyle(BP.ink).monospacedDigit()
                .padding(.horizontal, BP.px(10))
            chip("Reset") { setDelay(0) }
        }
        note("Subtitles late? Nudge plus. Early? Nudge minus.")
    }

    private func setDelay(_ value: Double) {
        subDelay = value
        controller?.setSubDelay(value)
    }

    // MARK: Look (bp-subtitle-tune.tsx BpSubtitleLook)

    @ViewBuilder private var lookLane: some View {
        let s = settings.slice
        if !presets.isEmpty {
            PlayerChipRow {
                PlayerRowLabel(text: "Presets")
                ForEach(presets) { p in chip(p.name) { update(p.values) } }
            }
        }
        PlayerChipRow {
            let size = s.subFontSize ?? 32
            let height = s.subMarginY ?? 12
            let opacity = s.subOpacity ?? 1
            stepper("Size", value: Int(size), reset: { update(["subFontSize": .number(32)]) }) { d in
                update(["subFontSize": .number(clamp(size + Double(d) * 4, 16, 120))])
            }
            stepper("Height", value: Int(height), reset: { update(["subMarginY": .number(10)]) }) { d in
                update(["subMarginY": .number(clamp(height + Double(d) * 2, 0, 100))])
            }
            PlayerRowLabel(text: "Opacity")
            chip("−", id: "dec-Opacity") { update(["subOpacity": .number(clamp(((opacity - 0.1) * 100).rounded() / 100, 0.1, 1))]) }
            chip("\(Int((opacity * 100).rounded()))%", id: "val-Opacity") { update(["subOpacity": .number(1)]) }
            chip("+", id: "inc-Opacity") { update(["subOpacity": .number(clamp(((opacity + 0.1) * 100).rounded() / 100, 0.1, 1))]) }
        }
        PlayerChipRow {
            let style = s.subStyle ?? "shadow"
            PlayerRowLabel(text: "Backing")
            chip("Shadow", on: style == "shadow") { update(["subStyle": .string("shadow")]) }
            chip("Outline", on: style == "outline") { update(["subStyle": .string("outline")]) }
            chip("Box", on: style == "box") { update(["subStyle": .string("box")]) }
            chip("Bold", on: s.subBold ?? false) { update(["subBold": .bool(!(s.subBold ?? false))]) }
        }
        sample(s)
    }

    /// The sample approximates mpv; the colours are the viewer's own values, written as-is.
    private func sample(_ s: SettingsBridge.Slice) -> some View {
        let style = s.subStyle ?? "shadow"
        let outline = style == "outline" ? hexColor(s.subBorderColor, .black) : Color.clear
        let edge = CGFloat(max(1, min(s.subBorderSize ?? 2, 4)))
        return HStack {
            Spacer(minLength: 0)
            Text("This is how your subtitles will look.")
                .font(.custom((s.subBold ?? false) ? "Switzer-Bold" : "Switzer-Semibold", size: max(BP.px(16), CGFloat(s.subFontSize ?? 32))))
                .multilineTextAlignment(.center)
                .foregroundStyle(hexColor(s.subFontColor, .white))
                .shadow(color: outline, radius: 0, x: edge, y: 0)
                .shadow(color: outline, radius: 0, x: -edge, y: 0)
                .shadow(color: outline, radius: 0, x: 0, y: edge)
                .shadow(color: outline, radius: 0, x: 0, y: -edge)
                .shadow(color: style == "shadow" ? Color.black.opacity(0.9) : Color.clear, radius: 5, x: 0, y: 2)
                .padding(.horizontal, style == "box" ? BP.px(10) : 0)
                .padding(.vertical, style == "box" ? BP.px(4) : 0)
                .background(style == "box" ? hexColor(s.subBoxColor, .black).opacity(s.subBoxOpacity ?? 0.6) : Color.clear)
                .opacity(s.subOpacity ?? 1)
            Spacer(minLength: 0)
        }
        .padding(BP.px(28))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.void_))
        .padding(.top, BP.px(8))
    }

    private func update(_ change: [String: AnyJSON]) {
        Task {
            try? await SettingsBridge.shared.patch(change)
            controller?.refreshSubtitleStyle()
        }
    }

    private func loadPresets() async throws -> [Preset] {
        let list: [Preset] = try await HarborEngine.shared.call("subtitles.presets", [])
        return list
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    private func hexColor(_ hex: String?, _ fallback: Color) -> Color {
        var h = (hex ?? "").trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return fallback }
        return Color(hex: v)
    }
}
