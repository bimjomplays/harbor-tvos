import SwiftUI

/// (S4) view.ts PlayerSrc.subtitlePreselect: what the subtitle step chose before playback. `off`
/// is "No subtitles"; otherwise the result's URL, language and title (bp-subtitle-step start():
/// `title: r.title || languageName(r.lang)`). The player hands it to the engine's track plan
/// (TrackMemory.preselect → player.trackPlan), which puts it on in place of the automatic choice
/// and the remembered subtitle, as use-track-autoload's preselect effect does.
struct SubtitlePreselect: Codable, Equatable {
    var off: Bool
    var url: String? = nil
    var lang: String? = nil
    var title: String? = nil
}

/// (S4) bp-subtitle-step.tsx BpSubtitleStep: "Choose subtitles" between the stream pick and the
/// player, shown by the picker when settings.subtitlePreselect is on (use-bp-stream-play
/// openPlayerGated). The list is use-subtitle-choices' online search for the picked stream
/// (engine subtitles.choices), grouped by language, the best match selected once it loads (else
/// "No subtitles"). "Start playback" hands the selection over, "Skip, let Harbor choose" opens the
/// player with no preselect (the automatic choice), Back and Menu return to the stream list.
struct SubtitleStepView: View {
    let meta: Meta
    let episode: AnyJSON?
    /// The PlayerSrc fields use-subtitle-choices reads: src.imdbId / imdbIdVerified, the stream's
    /// PlayerStreamRef (nil for a home-server copy) and the resolved file name.
    let imdbId: String?
    let imdbVerified: Bool
    let streamRef: AnyJSON?
    let filename: String?
    /// onStart(finalSrc): the choice, or nil for the src unchanged (Skip, or nothing selected yet).
    let onStart: (SubtitlePreselect?) -> Void
    let onCancel: () -> Void

    struct Choice: Decodable, Identifiable, Equatable {
        var id: String
        var url: String
        var lang: String
        var langKey: String
        var label: String
        var detail: String
        var flag: String?
    }
    struct LangGroup: Decodable, Equatable {
        var langKey: String
        var langDisplay: String
        var count: Int
    }
    struct Choices: Decodable {
        var error: Bool
        var results: [Choice]
        var groups: [LangGroup]
        var bestId: String?
    }
    /// engine SubtitleStepSrc.
    private struct Src: Encodable {
        var meta: Meta
        var episode: AnyJSON?
        var imdbId: String?
        var imdbIdVerified: Bool
        var streamRef: AnyJSON?
        var filename: String?
    }

    @State private var loading = true
    @State private var failed = false
    @State private var results: [Choice] = []
    @State private var groups: [LangGroup] = []
    @State private var bestId: String?
    /// bp-subtitle-step Selection: nil until the search answers, then "off" or a result id.
    @State private var selected: String?
    @State private var activeLang = "all"
    @FocusState private var focus: String?

    private static let offId = "off"

    var body: some View {
        ZStack(alignment: .topLeading) {
            BP.void_
            VStack(alignment: .leading, spacing: 0) {
                header
                langChips
                list
                actions
            }
        }
        .ignoresSafeArea()
        .onAppear {
            // BpTrackRow "No subtitles" carries data-bp-autofocus; the step seeds it silently.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { focus = "row:" + Self.offId }
        }
        // pushBpBack(() => { onCancel(); return true; }).
        .onExitCommand { onCancel() }
        .task { await load() }
    }

    // MARK: header

    /// `${meta.name} · S{imdbSeason ?? season}E{imdbEpisode ?? episode}` for an episode.
    private var context: String {
        guard let s = episode?["imdbSeason"]?.number ?? episode?["season"]?.number,
              let e = episode?["imdbEpisode"]?.number ?? episode?["episode"]?.number,
              s.isFinite, e.isFinite else { return meta.name }
        return meta.name + " · S" + String(clampedInt(s)) + "E" + String(clampedInt(e))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: BP.px(5)) {
            HStack(spacing: BP.px(12)) {
                Image(systemName: "captions.bubble").font(.system(size: BP.px(26), weight: .semibold)).accessibilityHidden(true)
                Text(verbatim: T("Choose subtitles"))
            }
            .font(BP.display(30, .semibold)).foregroundStyle(BP.ink)
            Text(verbatim: context + " · " + (loading ? T("Finding subtitles…") : T("%lld tracks", results.count)))
                .font(BP.sans(16, .medium)).foregroundStyle(BP.inkSubtle).lineLimit(1)
        }
        .padding(.horizontal, BP.gutter)
        .padding(.top, BP.px(40))
    }

    // MARK: language chips

    private var langChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BP.px(10)) {
                chip(T("All languages"), count: results.count, key: "all")
                ForEach(groups, id: \.langKey) { g in
                    chip(g.langDisplay, count: g.count, key: g.langKey)
                }
            }
            .padding(.horizontal, BP.gutter)
            .padding(.vertical, BP.px(18))
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private func chip(_ label: String, count: Int, key: String) -> some View {
        let on: Bool = activeLang == key
        return Button {
            BPSound.shared.click()
            activeLang = key
        } label: {
            // "{label} {count}", as bp-subtitle-step prints it.
            Text(verbatim: label + " " + String(count))
        }
        .buttonStyle(BPActionStyle(primary: on))
        .bpSelected(on)
        .focused($focus, equals: "lang:" + key)
    }

    // MARK: rows

    private var visible: [Choice] {
        activeLang == "all" ? results : results.filter { $0.langKey == activeLang }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: BP.px(10)) {
                trackRow(id: Self.offId, label: T("No subtitles"), detail: nil, best: false, flag: nil, offRow: true)
                if loading {
                    HStack(spacing: BP.px(12)) {
                        ProgressView().tint(BP.inkSubtle)
                        Text(verbatim: T("Finding subtitles…"))
                    }
                    .font(BP.sans(16, .medium)).foregroundStyle(BP.inkSubtle)
                    .padding(.horizontal, BP.px(6))
                } else if results.isEmpty {
                    Text(verbatim: failed
                         ? T("Couldn't load subtitles. You can start anyway and add one later in the player.")
                         : T("No subtitles found. Start anyway, Harbor keeps looking while you watch."))
                        .font(BP.sans(16, .medium)).foregroundStyle(BP.inkSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, BP.px(6))
                }
                ForEach(visible) { r in
                    trackRow(id: r.id, label: r.label, detail: r.detail, best: r.id == bestId, flag: r.flag, offRow: false)
                }
            }
            .padding(.horizontal, BP.gutter)
            .padding(.vertical, BP.px(8))
        }
        .frame(maxHeight: .infinity)
        .focusSection()
    }

    /// BpTrackRow: the round icon (a check when selected, else the flag or "captions off"), the
    /// label with the "Best match" pill, and the detail line.
    private func trackRow(id: String, label: String, detail: String?, best: Bool, flag: String?, offRow: Bool) -> some View {
        let isOn: Bool = selected == id
        return Button {
            BPSound.shared.click()
            selected = id
        } label: {
            HStack(spacing: BP.px(18)) {
                ZStack {
                    Circle().fill(BP.panel2)
                    if isOn {
                        Image(systemName: "checkmark").font(.system(size: BP.px(20), weight: .heavy))
                    } else if offRow {
                        Image(systemName: "captions.bubble.fill").font(.system(size: BP.px(19), weight: .semibold)).opacity(0.45)
                    } else if let flag, !flag.isEmpty {
                        Text(verbatim: flag).font(.system(size: BP.px(24)))
                    } else {
                        Image(systemName: "captions.bubble").font(.system(size: BP.px(19), weight: .semibold))
                    }
                }
                .frame(width: BP.px(52), height: BP.px(52))
                .foregroundStyle(BP.ink)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    HStack(spacing: BP.px(10)) {
                        Text(verbatim: label).font(BP.sans(18, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                        if best {
                            Text(verbatim: T("Best match"))
                                .font(BP.sans(11.5, .bold)).textCase(.uppercase).tracking(1.4).foregroundStyle(BP.ink)
                                .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(3))
                                .background(Capsule().fill(BP.glass))
                                .fixedSize()
                        }
                    }
                    if let detail, !detail.isEmpty {
                        Text(verbatim: detail).font(BP.sans(14, .medium)).foregroundStyle(BP.ink).opacity(0.65).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, BP.px(20)).padding(.vertical, BP.px(14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(isOn ? BP.glass : BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(isOn ? Color.clear : BP.edge, lineWidth: 1))
        }
        .buttonStyle(BPTileStyle(radius: BP.rMD))
        .bpSelected(isOn)
        .focused($focus, equals: "row:" + id)
    }

    // MARK: actions

    private var actions: some View {
        HStack(spacing: BP.px(14)) {
            Button {
                BPSound.shared.close()
                onCancel()
            } label: {
                Text(verbatim: T("Back"))
            }
            .buttonStyle(BPActionStyle())
            .focused($focus, equals: "back")
            Button {
                BPSound.shared.click()
                onStart(nil)
            } label: {
                Text(verbatim: T("Skip, let Harbor choose"))
            }
            .buttonStyle(BPActionStyle())
            .focused($focus, equals: "skip")
            Button {
                BPSound.shared.click()
                start()
            } label: {
                HStack(spacing: BP.px(9)) {
                    Image(systemName: "play.fill").font(.system(size: BP.px(16), weight: .bold)).accessibilityHidden(true)
                    Text(verbatim: T("Start playback"))
                }
            }
            .buttonStyle(BPActionStyle(primary: true))
            .focused($focus, equals: "start")
        }
        .padding(.horizontal, BP.gutter)
        .padding(.top, BP.px(16))
        .padding(.bottom, BP.px(44))
        // The whole width, so Down from any row lands in the button row.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    /// bp-subtitle-step start(): "off", the selected result, or the src unchanged.
    private func start() {
        if selected == Self.offId {
            onStart(SubtitlePreselect(off: true))
            return
        }
        if let id = selected, let r = results.first(where: { $0.id == id }) {
            onStart(SubtitlePreselect(off: false, url: r.url, lang: r.lang, title: r.label))
            return
        }
        onStart(nil)
    }

    // MARK: load (use-subtitle-choices)

    private func load() async {
        let p = ProfilesStore.shared.active
        let authKey: String? = p.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
        let src = Src(meta: meta, episode: episode, imdbId: imdbId, imdbIdVerified: imdbVerified, streamRef: streamRef, filename: filename)
        let args: [any Encodable] = [p?.id ?? "default", p?.linked ?? true, authKey, src]
        let out: Choices? = try? await HarborEngine.shared.call("subtitles.choices", args)
        guard !Task.isCancelled else { return }
        // One row per result id (the list's identity and its focus key).
        var seen: Set<String> = []
        let unique: [Choice] = (out?.results ?? []).filter { seen.insert($0.id).inserted }
        results = unique
        groups = out?.groups ?? []
        bestId = out?.bestId
        failed = out?.error ?? true
        loading = false
        // The init effect: the best match is selected and its language shown, else "No subtitles".
        if let best = bestId, let r = unique.first(where: { $0.id == best }) {
            selected = best
            activeLang = r.langKey
        } else {
            selected = Self.offId
        }
    }
}
