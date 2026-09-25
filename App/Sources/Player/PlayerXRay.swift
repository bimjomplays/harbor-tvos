import SwiftUI

/// X-Ray (components/player/xray/*, lib/xray/use-xray-cast.ts; settings.xrayEnabled, off by
/// default): while the viewer is paused, the cast of what is playing, each card opening the
/// person page, with "View all" for the Cast / Crew / About browser.
///
/// Upstream shows a small "X-Ray" button while the chrome is up and opens the rail from it; its
/// rail leads with the faces matched on screen (lib/face, on-device ONNX models) and falls back to
/// the cast list. The TV has no face engine, so the rail is that cast list, it opens as the viewer
/// pauses (the button comes back once it is closed), and the browser has no "In scene" tab. Data
/// comes from the engine's `xray.load` (engine/xray.ts).
@MainActor
final class PlayerXRayModel: ObservableObject {
    struct Person: Decodable, Hashable {
        /// TMDB person id (TVDB's fallback cast carries negative ids, as upstream's does).
        var id: Int
        var name: String
        var sub: String?
        var photo: String?
        var initials: String
        var key: String
    }
    struct Fact: Decodable, Hashable { var label: String; var value: String }
    struct Video: Decodable, Hashable { var ytId: String; var name: String; var thumb: String }
    struct About: Decodable {
        var title: String
        var logo: String?
        var tagline: String?
        var overview: String?
        var genres: [String]
        var year: String?
        var runtime: String?
        var rating: String?
        var votes: String?
        var status: String?
        var facts: [Fact]
        var hero: String?
        var videos: [Video]
        var strip: [String]
        var showStrip: Bool
    }
    struct Tab: Decodable, Hashable { var id: String; var label: String }
    struct EmptyLabels: Decodable { var details: String; var cast: String; var crew: String }
    struct Payload: Decodable {
        var needsTmdbKey: Bool
        var hasDetails: Bool
        var rail: [Person]
        var cast: [Person]
        var crew: [Person]
        var about: About?
        var tabs: [Tab]
        var initialTab: String?
        var railStatus: String?
        var empty: EmptyLabels
    }

    @Published private(set) var payload: Payload?
    @Published private(set) var loading = false
    /// (bug pass) The engine call failed (an engine error or an answer that would not decode): the
    /// rail and the browser said "Reading the cast" with a spinner for as long as the pause lasted.
    @Published private(set) var failed = false
    /// The overlay is rebuilt on every pause; the last title's answer shows at once.
    private static var last: (metaId: String, payload: Payload)?

    func load(_ meta: Meta) async {
        if let hit = Self.last, hit.metaId == meta.id { payload = hit.payload; failed = false; return }
        loading = true
        failed = false
        defer { loading = false }
        let p = ProfilesStore.shared.active
        let got: Payload? = try? await HarborEngine.shared.call("xray.load", [meta, p?.id ?? "default", p?.linked ?? true])
        if let got {
            payload = got
            // Only a full answer is kept: a failed TMDB lookup or a missing key must be asked again
            // (the engine caches its own successes for ten minutes) (review 34).
            if got.hasDetails && !got.needsTmdbKey { Self.last = (meta.id, got) }
        } else if payload == nil {
            failed = true
        }
    }
}

struct PlayerXRayOverlay: View {
    let meta: Meta
    /// PlayerScreen's `xrayOpen`: the browser, a person page or a trailer covers the player and owns
    /// the remote (the chrome steps aside while it is true).
    @Binding var open: Bool
    var focus: FocusState<PlayerScreen.FocusTarget?>.Binding

    /// Where Up from the stage lands: the rail's first card, else its "View all", else the X-Ray button.
    static let entry: PlayerScreen.FocusTarget = .chip("xray")

    @StateObject private var model = PlayerXRayModel()
    /// xray-overlay.tsx view "closed": the rail's ✕ leaves the X-Ray button until the next pause.
    @State private var railClosed = false
    @State private var browsing = false
    @State private var tab = ""
    @State private var person: PlayerXRayModel.Person?
    @State private var trailer: PlayerXRayModel.Video?
    /// xray-about.tsx hero: the still the strip picked.
    @State private var hero: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let person {
                // xray-overlay.tsx CastModal initialPerson, drawn in the player (never a cover over it).
                PersonView(personId: person.id, name: person.name, onClose: { closePerson() })
                    .transition(.opacity)
            } else if let trailer {
                // xray-overlay.tsx TrailerOverlay (the player is already paused here).
                TrailerView(ytId: trailer.ytId, title: model.payload?.about?.title ?? meta.name, clipName: trailer.name) { closeTrailer() }
                    .onExitCommand { closeTrailer() }
                    .transition(.opacity)
            } else if browsing {
                browser.transition(.opacity)
            } else if railClosed {
                xrayButton.transition(.opacity)
            } else {
                rail.transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(BP.easeFast, value: browsing)
        .animation(BP.easeFast, value: railClosed)
        .task(id: meta.id) { await model.load(meta) }
        // "View all" pressed before the cast arrived: the browser opens on the first tab once it has one.
        .onReceive(model.$payload) { p in if browsing, tab.isEmpty, let t = p?.initialTab { tab = t } }
        .onDisappear {
            // Playing again (or the chrome going down) takes X-Ray away: the remote goes back to the stage.
            open = false
            if focusInXRay { focus.wrappedValue = .surface }
        }
    }

    private var focusInXRay: Bool {
        switch focus.wrappedValue {
        case .chip(let id)?: return id.hasPrefix("xray")
        case nil: return true
        default: return false
        }
    }

    private func focusSoon(_ target: PlayerScreen.FocusTarget) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { focus.wrappedValue = target }
    }

    private func showBrowser() {
        tab = model.payload?.initialTab ?? ""
        hero = nil
        browsing = true
        open = true
        focusSoon(.chip("xray-tab:\(tab)"))
    }

    private func closeBrowser() {
        browsing = false
        open = false
        focusSoon(Self.entry)
    }

    private func openPerson(_ p: PlayerXRayModel.Person) {
        person = p
        open = true
    }

    private func closePerson() {
        let key = person?.key
        person = nil
        open = browsing
        if let key { focusSoon(browsing || railIndex(of: key) != 0 ? PlayerScreen.FocusTarget.chip("xray-p:\(key)") : Self.entry) }
    }

    private func closeTrailer() {
        let id = trailer?.ytId
        trailer = nil
        open = browsing
        if let id { focusSoon(.chip("xray-v:\(id)")) }
    }

    private func railIndex(of key: String) -> Int? { model.payload?.rail.firstIndex { $0.key == key } }

    // MARK: rail (xray-rail.tsx)

    private var rail: some View {
        let people = model.payload?.rail ?? []
        return VStack(alignment: .leading, spacing: BP.px(8)) {
            HStack(spacing: BP.px(10)) {
                Label("X-Ray", systemImage: "faceid")
                    .font(BP.sans(11, .bold)).tracking(BP.px(11) * 0.22).textCase(.uppercase)
                    .foregroundStyle(BP.ink)
                Button { showBrowser() } label: { Label("View all", systemImage: "chevron.forward") }
                    .buttonStyle(BPActionStyle())
                    .focused(focus, equals: people.isEmpty ? Self.entry : PlayerScreen.FocusTarget.chip("xray-all"))
                Button { railClosed = true; focusSoon(Self.entry) } label: { Label("Close", systemImage: "xmark") }
                    .buttonStyle(BPActionStyle())
                    .focused(focus, equals: .chip("xray-close"))
            }
            .focusSection()
            if people.isEmpty {
                HStack(spacing: BP.px(8)) {
                    if model.failed && model.payload == nil {
                        // engine/xray.ts assemble's own copy for a title with nobody listed.
                        Text(T("No cast information for this title.")).font(BP.sans(12.5)).foregroundStyle(BP.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if model.loading || model.payload == nil {
                        ProgressView().tint(BP.inkMuted)
                        Text("Reading the cast").font(BP.sans(12.5)).foregroundStyle(BP.inkMuted)
                    } else if let status = model.payload?.railStatus {
                        Circle().fill(BP.accent).frame(width: BP.px(6), height: BP.px(6))
                        Text(verbatim: status).font(BP.sans(12.5)).foregroundStyle(BP.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, BP.px(6))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: BP.px(4)) {
                        ForEach(Array(people.enumerated()), id: \.element.key) { i, p in
                            railCard(p).focused(focus, equals: i == 0 ? Self.entry : PlayerScreen.FocusTarget.chip("xray-p:\(p.key)"))
                        }
                    }
                    .padding(.vertical, BP.px(8)).padding(.horizontal, BP.px(10))
                }
                .frame(maxHeight: BP.px(270))
                .focusSection()
            }
        }
        .frame(width: BP.px(300), alignment: .leading)
        .padding(.leading, BP.gutter).padding(.top, BP.px(36)).padding(.bottom, BP.px(16)).padding(.trailing, BP.px(40))
        .background(
            LinearGradient(colors: [BP.void_.opacity(0.8), BP.void_.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()
        )
    }

    /// xray-actor-card.tsx XrayRailCard: photo, name, character.
    private func railCard(_ p: PlayerXRayModel.Person) -> some View {
        Button { openPerson(p) } label: {
            HStack(spacing: BP.px(12)) {
                photo(p, radius: BP.px(11)).frame(width: BP.px(48), height: BP.px(48))
                VStack(alignment: .leading, spacing: BP.px(2)) {
                    Text(verbatim: p.name).font(BP.sans(13.5, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                    if let sub = p.sub { Text(verbatim: sub).font(BP.sans(12)).foregroundStyle(BP.inkMuted).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(BP.px(6))
            .frame(width: BP.px(270), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.void_.opacity(0.35)))
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM))
    }

    /// xray-overlay.tsx closed view: the "X-Ray" button (shown while the chrome is up).
    private var xrayButton: some View {
        Button { railClosed = false; focusSoon(Self.entry) } label: { Label("X-Ray", systemImage: "faceid") }
            .buttonStyle(BPActionStyle())
            .focused(focus, equals: Self.entry)
            .padding(.leading, BP.gutter).padding(.top, BP.px(36))
    }

    /// xray-actor-card.tsx Photo: the headshot, else the initials.
    private func photo(_ p: PlayerXRayModel.Person, radius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(BP.ink.opacity(0.06))
            Text(verbatim: p.initials).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkSubtle)
            if let url = p.photo { RemoteImage(url: url) }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(BP.ink.opacity(0.12), lineWidth: 1))
    }

    // MARK: browser (xray-browser.tsx)

    private var browser: some View {
        let data = model.payload
        return ZStack(alignment: .topLeading) {
            BP.void_.opacity(0.92).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(20)) {
                HStack(spacing: BP.px(14)) {
                    Label("X-Ray", systemImage: "faceid")
                        .font(BP.sans(12, .bold)).tracking(BP.px(12) * 0.24).textCase(.uppercase)
                        .foregroundStyle(BP.ink)
                    if data?.hasDetails == true {
                        ForEach(data?.tabs ?? [], id: \.id) { t in
                            Button { tab = t.id } label: { Text(verbatim: t.label) }
                                .buttonStyle(BPActionStyle(primary: tab == t.id))
                                .focused(focus, equals: .chip("xray-tab:\(t.id)"))
                        }
                    }
                    Spacer()
                    Button { closeBrowser() } label: { Label("Close", systemImage: "xmark") }
                        .buttonStyle(BPActionStyle())
                        .focused(focus, equals: .chip(data?.hasDetails == true && !(data?.tabs.isEmpty ?? true) ? "xray-close" : "xray-tab:\(tab)"))
                }
                .focusSection()
                Group {
                    if let data, data.hasDetails {
                        switch tab {
                        case "about": if let a = data.about { about(a) }
                        case "crew": grid(data.crew, empty: data.empty.crew)
                        default: grid(data.cast, empty: data.empty.cast)
                        }
                    } else if data == nil && model.failed {
                        emptyNote(T("No cast information for this title."))
                    } else if data == nil {
                        ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity, minHeight: BP.px(220))
                    } else {
                        emptyNote(data?.empty.details ?? "")
                    }
                }
                .focusSection()
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.px(40))
        }
        .onExitCommand { closeBrowser() }
    }

    private func emptyNote(_ label: String) -> some View {
        Text(verbatim: label).font(BP.sans(14)).foregroundStyle(BP.inkMuted).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: BP.px(220))
    }

    private static let gridColumns = Array(repeating: GridItem(.flexible(), spacing: BP.px(20), alignment: .top), count: 7)

    /// xray-browser.tsx Grid of XrayTile.
    @ViewBuilder
    private func grid(_ people: [PlayerXRayModel.Person], empty: String) -> some View {
        if people.isEmpty {
            emptyNote(empty)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: BP.px(28)) {
                    ForEach(people, id: \.key) { p in
                        Button { openPerson(p) } label: {
                            VStack(alignment: .leading, spacing: BP.px(8)) {
                                photo(p, radius: BP.px(16)).aspectRatio(1, contentMode: .fit)
                                Text(verbatim: p.name).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                Text(verbatim: p.sub ?? " ").font(BP.sans(12.5)).foregroundStyle(BP.inkMuted).lineLimit(1)
                            }
                        }
                        .buttonStyle(BPTileStyle(radius: BP.px(16)))
                        .focused(focus, equals: .chip("xray-p:\(p.key)"))
                    }
                }
                .padding(.vertical, BP.px(16)).padding(.horizontal, BP.px(6))
                .padding(.bottom, BP.px(40))
            }
        }
    }

    // MARK: about (xray-about.tsx)

    private func about(_ a: PlayerXRayModel.About) -> some View {
        let shown = hero ?? a.hero
        return HStack(alignment: .top, spacing: BP.px(32)) {
            VStack(alignment: .leading, spacing: BP.px(12)) {
                ZStack(alignment: .bottomLeading) {
                    if let shown { RemoteImage(url: shown) } else { BP.ink.opacity(0.04) }
                    LinearGradient(colors: [.clear, BP.void_.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                    if let logo = a.logo {
                        RemoteImage(url: logo, contentMode: .fit)
                            .frame(maxWidth: BP.px(260), maxHeight: BP.px(52), alignment: .bottomLeading)
                            .padding(BP.px(18))
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: BP.px(16), style: .continuous))
                if a.showStrip {
                    HStack(spacing: BP.px(8)) {
                        ForEach(a.videos, id: \.ytId) { v in
                            Button { trailer = v; open = true } label: {
                                ZStack {
                                    RemoteImage(url: v.thumb)
                                    Image(systemName: "play.circle.fill").font(.system(size: BP.px(20))).foregroundStyle(.white)
                                }
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: BP.px(8), style: .continuous))
                            }
                            .buttonStyle(BPTileStyle(radius: BP.px(8)))
                            .focused(focus, equals: .chip("xray-v:\(v.ytId)"))
                        }
                        ForEach(a.strip, id: \.self) { b in
                            Button { hero = b } label: {
                                RemoteImage(url: b)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: BP.px(8), style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: BP.px(8), style: .continuous).stroke(b == shown ? BP.accent : .clear, lineWidth: 2))
                            }
                            .buttonStyle(BPTileStyle(radius: BP.px(8)))
                        }
                    }
                    .focusSection()
                }
            }
            // lg:grid-cols-[1.55fr_1fr]: the stills take about three fifths of the width.
            .frame(width: BP.px(580))

            VStack(alignment: .leading, spacing: BP.px(12)) {
                Text(verbatim: a.title).font(BP.display(22)).foregroundStyle(BP.ink)
                if let line = Self.metaLine(a) {
                    Text(verbatim: line).font(BP.sans(13, .medium)).foregroundStyle(BP.inkMuted)
                }
                if !a.genres.isEmpty {
                    HStack(spacing: BP.px(6)) {
                        ForEach(a.genres.prefix(6), id: \.self) { g in
                            Text(verbatim: g).font(BP.sans(11.5, .medium)).foregroundStyle(BP.inkMuted)
                                .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(3))
                                .background(Capsule().fill(BP.ink.opacity(0.08)))
                        }
                    }
                }
                if let tagline = a.tagline { Text(verbatim: tagline).font(BP.sans(14)).italic().foregroundStyle(BP.inkMuted) }
                if let overview = a.overview {
                    Text(verbatim: overview).font(BP.sans(14)).foregroundStyle(BP.ink.opacity(0.8)).lineSpacing(4).lineLimit(8)
                }
                if !a.facts.isEmpty {
                    Divider().overlay(BP.edge)
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: BP.px(12)) {
                        ForEach(a.facts, id: \.self) { f in
                            VStack(alignment: .leading, spacing: BP.px(2)) {
                                Text(verbatim: f.label).font(BP.sans(10.5, .semibold)).textCase(.uppercase).foregroundStyle(BP.inkSubtle)
                                Text(verbatim: f.value).font(BP.sans(13)).foregroundStyle(BP.ink.opacity(0.85)).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// xray-about.tsx meta row: IMDb rating with the vote count, year, runtime, status.
    private static func metaLine(_ a: PlayerXRayModel.About) -> String? {
        var parts: [String] = []
        if let r = a.rating { parts.append(a.votes.map { "IMDb \(r) (\($0))" } ?? "IMDb \(r)") }
        for v in [a.year, a.runtime, a.status] { if let v, !v.isEmpty { parts.append(v) } }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}
