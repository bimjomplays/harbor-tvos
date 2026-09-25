import SwiftUI

/// Harbor Voyages (components/voyage/*). Upstream opens it as a modal from the desktop Discover
/// page's banner (voyage-banner.tsx, `data-tv-skip`, so Big Picture never reaches it); the TV opens
/// it full screen from the same banner, placed on the Discover room. The chooser picks a theme and
/// a length, the route is built one heading at a time ("Choose 1 of 3"), then sailed in order.
/// Films open on the title page and start playing; the voyage stays underneath and refreshes its
/// progress on the way back (upstream closes the modal instead: a TV has no window behind it).
/// Not ported: voyage-launch.tsx (a lottie-web boat animation before the first film) and
/// voyage-prefetch.tsx (the desktop picker cache); see engine/voyage.ts.
struct VoyageView: View {
    @StateObject private var model = VoyageModel()
    @Environment(\.dismiss) private var dismiss
    @State private var playing: PlayTarget?
    @FocusState private var focus: String?
    struct PlayTarget: Identifiable { var meta: Meta; var autoPlay: Bool; var id: String { meta.id } }

    private var accent: Color { model.active.flatMap { Color(oklch: $0.accent) } ?? BP.accent }

    var body: some View {
        ZStack(alignment: .top) {
            BPAmbientBackground()
            // voyage-modal.tsx: the voyage's accent washes the top of the panel.
            if model.active != nil {
                LinearGradient(colors: [accent.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: BP.px(220)).frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(22)) {
                    header
                    if let a = model.active {
                        route(a)
                    } else if model.snapshot != nil {
                        chooser
                    } else {
                        ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity).padding(.top, BP.px(120))
                    }
                }
                .frame(maxWidth: BP.px(900), alignment: .leading)
                .padding(.horizontal, BP.gutter)
                .padding(.top, BP.px(44)).padding(.bottom, BP.px(60))
                .frame(maxWidth: .infinity)
            }
        }
        .ignoresSafeArea()
        .onExitCommand { dismiss() }
        .task {
            await model.load()
            settleFocus()
        }
        .onChange(of: model.active?.headings.map(\.id) ?? []) { _, ids in
            // The headings changed under the viewer (a pick, a reroll, the TMDB refinement).
            // (The pick itself settles focus as soon as it shows, before the refinement lands; review 33.)
            if let f = focus, f.hasPrefix("heading-"), !ids.contains(String(f.dropFirst(8))) { settleFocus() }
        }
        .fullScreenCover(item: $playing, onDismiss: { Task { await model.refresh(); settleFocus() } }) { t in
            DetailView(meta: t.meta, autoPlay: t.autoPlay)
        }
    }

    // MARK: header (voyage-modal.tsx: streak chip, close)

    private var header: some View {
        HStack(alignment: .center, spacing: BP.px(10)) {
            if let s = model.snapshot?.streak, s > 1 {
                HStack(alignment: .firstTextBaseline, spacing: BP.px(5)) {
                    Image(systemName: "flame.fill").font(.system(size: BP.px(13), weight: .semibold)).foregroundStyle(BP.accent).accessibilityHidden(true)
                    Text(verbatim: "\(s)").font(BP.sans(12, .semibold)).monospacedDigit().foregroundStyle(BP.inkMuted)
                    Text(T("day streak")).font(BP.sans(12, .semibold)).foregroundStyle(BP.inkSubtle)
                }
                .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(5))
                .background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(BP.glass))
            }
            Spacer()
            Button { dismiss() } label: { Label(T("Close"), systemImage: "xmark") }
                .buttonStyle(BPActionStyle())
                .focused($focus, equals: "close")
        }
        .focusSection()
    }

    // MARK: chooser (voyage-chooser.tsx)

    private var chooser: some View {
        VStack(alignment: .leading, spacing: BP.px(22)) {
            HStack(alignment: .bottom, spacing: BP.px(16)) {
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    eyebrow(T("New voyage"), BP.accent)
                    Text(T("Where to today?")).font(BP.display(26)).foregroundStyle(BP.ink)
                    Text(T("Pick a direction. You steer from there, one film at a time.")).font(BP.sans(13.5)).foregroundStyle(BP.inkMuted)
                }
                Spacer(minLength: BP.px(16))
                VStack(alignment: .trailing, spacing: BP.px(6)) {
                    Text(T("How many films?")).font(BP.sans(11)).foregroundStyle(BP.inkSubtle)
                    HStack(spacing: BP.px(4)) {
                        ForEach([3, 5, 7], id: \.self) { n in
                            Button { model.length = n } label: { Text(verbatim: "\(n)") }
                                .buttonStyle(VoyageSegmentStyle(selected: model.length == n))
                                .focused($focus, equals: "len-\(n)")
                        }
                    }
                    .padding(BP.px(4))
                    .background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(BP.canvas))
                    .focusSection()
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BP.px(14)), count: 3), spacing: BP.px(14)) {
                ForEach(model.themes) { theme in
                    // (discover/onboarding pass 2) Only a route that charted moves the ring: a theme that
                    // would not (offline, a thin pool) threw it from the tile just pressed, next to its
                    // error line, to the first theme.
                    Button { Task { await model.start(theme); if model.active != nil { settleFocus() } } } label: {
                        VoyageThemeTile(theme: theme, busy: model.busy == theme.id)
                    }
                    .buttonStyle(BPTileStyle(radius: BP.rSM))
                    .focused($focus, equals: "theme-\(theme.id)")
                    .accessibilityIdentifier("voyage-theme-\(theme.id)")
                }
            }
            .focusSection()
            if let e = model.error {
                Text(T(e)).font(BP.sans(12.5)).foregroundStyle(BP.danger)
            }
        }
    }

    // MARK: route (voyage-route.tsx)

    @ViewBuilder
    private func route(_ a: VoyageModel.Active) -> some View {
        VStack(alignment: .leading, spacing: BP.px(24)) {
            VStack(alignment: .leading, spacing: BP.px(4)) {
                eyebrow(T(a.sailing ? "On a voyage" : "Building your voyage"), accent)
                Text(a.themeLabel).font(BP.display(24)).foregroundStyle(BP.ink)
            }
            VoyageRouteRail(active: a, accent: accent, focus: $focus, onPlay: a.sailing ? { (m: Meta) in play(m) } : nil)
            if a.sailing {
                if let next = a.next { sailing(a, next) } else { complete(a) }
            } else if a.ready {
                ready
            } else if a.stuck {
                exhausted(a)
            } else {
                picker(a)
            }
        }
    }

    // voyage-picker.tsx: three headings, the focused one's port card beside them.
    private func picker(_ a: VoyageModel.Active) -> some View {
        let focused: Meta? = focus.flatMap { f in f.hasPrefix("heading-") ? a.headings.first(where: { "heading-\($0.id)" == f }) : nil }
        return VStack(alignment: .leading, spacing: BP.px(14)) {
            HStack(alignment: .firstTextBaseline, spacing: BP.px(8)) {
                Text(a.picked == 0 ? T("Choose your starting film") : T("Pick film %lld of %lld", a.picked + 1, a.targetLength))
                    .font(BP.sans(13, .semibold)).foregroundStyle(BP.ink)
                Text(T("Choose 1 of 3")).font(BP.sans(11)).foregroundStyle(BP.inkSubtle)
            }
            HStack(alignment: .top, spacing: BP.px(24)) {
                HStack(alignment: .top, spacing: BP.px(14)) {
                    ForEach(Array(a.headings.enumerated()), id: \.element.id) { i, m in
                        Button { Task { await model.choose(m); settleFocus(); await model.settle(m) } } label: {
                            BPTileView(meta: m, shape: .poster, focused: focus == "heading-\(m.id)")
                        }
                        .buttonStyle(BPTileStyle())
                        .focused($focus, equals: "heading-\(m.id)")
                        .accessibilityIdentifier("voyage-heading-\(i)")
                    }
                }
                .focusSection()
                if let m = focused ?? a.headings.first {
                    VoyagePortCard(meta: m, credits: model.credits[m.id], loaded: model.credits.keys.contains(m.id) || model.creditsFailed.contains(m.id))
                        .task(id: m.id) { await model.loadCredits(m) }
                }
            }
            HStack(spacing: BP.px(10)) {
                Button { Task { await model.end(); settleFocus() } } label: { Label(T("Start over"), systemImage: "flag") }
                    .buttonStyle(BPActionStyle())
                Spacer()
                if a.picked > 0 {
                    Button { Task { await model.undo(); settleFocus() } } label: { Label(T("Undo"), systemImage: "arrow.uturn.backward") }
                        .buttonStyle(BPActionStyle())
                }
                Button { Task { await model.reroll(); settleFocus() } } label: { Label(T("Show me 3 others"), systemImage: "dice") }
                    .buttonStyle(BPActionStyle())
                    .focused($focus, equals: "reroll")
            }
            .focusSection()
        }
    }

    // voyage-ready.tsx
    private var ready: some View {
        panel(dashed: false) {
            Image(systemName: "play.fill").font(.system(size: BP.px(22), weight: .semibold)).foregroundStyle(accent)
                .frame(width: BP.px(56), height: BP.px(56))
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(accent.opacity(0.12)))
                .accessibilityHidden(true)
            Text(T("Your voyage is ready")).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
            HStack(spacing: BP.px(10)) {
                Button { Task { await sail() } } label: { Label(T("Start voyage"), systemImage: "play.fill") }
                    .buttonStyle(BPActionStyle(primary: true))
                    .focused($focus, equals: "start-voyage")
                Button { Task { await model.end(); settleFocus() } } label: { Label(T("Start over"), systemImage: "flag") }
                    .buttonStyle(BPActionStyle())
            }
            .padding(.top, BP.px(4))
            .focusSection()
        }
    }

    // voyage-panels.tsx ExhaustedPanel
    private func exhausted(_ a: VoyageModel.Active) -> some View {
        panel(dashed: true) {
            Text(T(a.picked > 0 ? "No more films to add. Start with what you picked." : "You've sailed these waters dry."))
                .font(BP.sans(13.5)).foregroundStyle(BP.inkMuted).multilineTextAlignment(.center)
            HStack(spacing: BP.px(10)) {
                if a.picked > 0 {
                    Button { Task { await sail() } } label: { Label(T("Start with these %lld", a.picked), systemImage: "play.fill") }
                        .buttonStyle(BPActionStyle(primary: true))
                        .focused($focus, equals: "start-these")
                }
                Button { Task { await model.end(); settleFocus() } } label: { Text(T("Wrap up here")) }
                    .buttonStyle(BPActionStyle())
                    .focused($focus, equals: "wrap-up")
            }
            .focusSection()
        }
    }

    // voyage-panels.tsx CompletePanel
    private func complete(_ a: VoyageModel.Active) -> some View {
        panel(dashed: true) {
            Image(systemName: "film").font(.system(size: BP.px(24), weight: .semibold)).foregroundStyle(BP.accent)
                .frame(width: BP.px(56), height: BP.px(56))
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.accent.opacity(0.12)))
                .accessibilityHidden(true)
            Text(T("Voyage complete")).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
            Text(verbatim: "\(T("You saw the whole run through.")) \(a.slots.count) \(T("films, start to finish. Start another whenever you like."))")
                .font(BP.sans(13)).foregroundStyle(BP.inkSubtle).multilineTextAlignment(.center).frame(maxWidth: BP.px(420))
            Button { Task { await model.end(); settleFocus() } } label: { Text(T("Start another")) }
                .buttonStyle(BPActionStyle(primary: true))
                .focused($focus, equals: "start-another")
                .padding(.top, BP.px(4))
        }
    }

    // voyage-sailing.tsx: the next film, its place in the route, Play.
    private func sailing(_ a: VoyageModel.Active, _ next: Meta) -> some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            eyebrow(T("Up next"), BP.inkSubtle)
            HStack(alignment: .center, spacing: BP.px(16)) {
                RemoteImage(url: next.poster ?? next.background)
                    .frame(width: BP.px(58), height: BP.px(86))
                    .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).stroke(BP.edge, lineWidth: 1))
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    eyebrow(T("Film %lld of %lld", a.nextPosition, a.slots.count), accent)
                    Text(next.name).font(BP.display(19)).foregroundStyle(BP.ink).lineLimit(2)
                    let facts = [next.releaseInfo, next.runtime].compactMap { $0 }.filter { !$0.isEmpty }
                    if !facts.isEmpty {
                        Text(facts.joined(separator: "  ")).font(BP.sans(12)).monospacedDigit().foregroundStyle(BP.inkSubtle)
                    }
                }
                Spacer(minLength: BP.px(12))
                Button { play(next) } label: { Label(T("Play"), systemImage: "play.fill") }
                    .buttonStyle(BPActionStyle(primary: true))
                    .focused($focus, equals: "play-next")
                    .accessibilityIdentifier("voyage-play-next")
            }
            .padding(BP.px(12))
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.canvas.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge, lineWidth: 1))
            .focusSection()
            HStack(spacing: BP.px(10)) {
                Button { Task { await model.end(); settleFocus() } } label: { Label(T("End voyage"), systemImage: "flag") }
                    .buttonStyle(BPActionStyle())
                Spacer()
                Text(T("Your queue is saved until you clear it.")).font(BP.sans(11.5)).foregroundStyle(BP.inkSubtle)
            }
            .focusSection()
        }
    }

    // MARK: parts

    private func eyebrow(_ text: String, _ color: Color) -> some View {
        Text(text).font(BP.sans(11, .semibold)).textCase(.uppercase).tracking(BP.px(2)).foregroundStyle(color)
    }

    private func panel<C: View>(dashed: Bool, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: BP.px(12)) { content() }
            .padding(.horizontal, BP.px(24)).padding(.vertical, BP.px(36))
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.canvas.opacity(dashed ? 0.3 : 0.4)))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous)
                .stroke(BP.edge2, style: StrokeStyle(lineWidth: 1, dash: dashed ? [BP.px(5), BP.px(4)] : [])))
    }

    /// voyage-route.tsx play(): a movie opens on its title page and starts (openPicker autoPlay +
    /// resume); anything else opens its title page.
    private func play(_ meta: Meta) {
        playing = PlayTarget(meta: meta, autoPlay: meta.type == "movie")
    }

    /// voyage-route.tsx sail(): launch, then play the first film (the lottie launch is skipped).
    private func sail() async {
        let first = await model.launch()
        settleFocus()
        if let first { play(first) }
    }

    /// Lands focus on the panel's main control after the state moved on.
    private func settleFocus() {
        let target: String?
        if let a = model.active {
            if a.sailing { target = a.next != nil ? "play-next" : "start-another" }
            else if a.ready { target = "start-voyage" }
            else if a.stuck { target = a.picked > 0 ? "start-these" : "wrap-up" }
            else { target = a.headings.first.map { "heading-\($0.id)" } ?? "reroll" }
        } else {
            target = model.themes.first.map { "theme-\($0.id)" }
        }
        guard let target else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            focus = target
        }
    }
}

/// voyage-chooser.tsx LengthPicker segment: the chosen length on ink, the rest muted.
struct VoyageSegmentStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .font(BP.sans(12.5, .semibold)).monospacedDigit()
                .foregroundStyle(selected ? BP.canvas : (focused ? BP.ink : BP.inkMuted))
                .frame(width: BP.px(40), height: BP.px(32))
                .background(RoundedRectangle(cornerRadius: BP.px(6), style: .continuous).fill(selected ? BP.ink : (focused ? BP.on : .clear)))
                .modifier(BPFocusModifier(focused: focused, pressed: configuration.isPressed, radius: BP.px(6), lift: 1.04))
                .animation(BP.easeFast, value: selected)
        }
    }
}

/// voyage-chooser.tsx ThemeTile: the theme's palette, its backdrop under a canvas veil, the accent
/// keel along the bottom, the genre (or "Wildcard"), the label and the tagline.
struct VoyageThemeTile: View {
    let theme: VoyageModel.Theme
    let busy: Bool
    @Environment(\.isFocused) private var focused

    var body: some View {
        let from = Color(oklch: theme.from) ?? BP.panel2
        let to = Color(oklch: theme.to) ?? BP.void_
        let accent = Color(oklch: theme.accent) ?? BP.accent
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [from, to], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let bg = theme.backdrop {
                RemoteImage(url: bg)
                BP.canvas.opacity(focused ? 0.28 : 0.45)
            }
            LinearGradient(stops: [.init(color: BP.canvas.opacity(0.92), location: 0), .init(color: BP.canvas.opacity(0.66), location: 0.4),
                                   .init(color: BP.canvas.opacity(0.32), location: 0.66), .init(color: .clear, location: 0.88)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [BP.canvas, .clear], startPoint: .bottom, endPoint: .center)
            VStack(alignment: .leading, spacing: BP.px(2)) {
                Text(theme.genre ?? "Wildcard").font(BP.sans(10, .semibold)).textCase(.uppercase).tracking(BP.px(1.8)).foregroundStyle(accent)
                Text(theme.label).font(BP.display(16)).foregroundStyle(BP.ink).lineLimit(1)
                Text(theme.tagline).font(BP.sans(12)).foregroundStyle(BP.inkMuted).lineLimit(1)
            }
            .padding(.horizontal, BP.px(16)).padding(.bottom, BP.px(14))
            accent.frame(height: BP.px(2)).frame(maxHeight: .infinity, alignment: .bottom)
            if busy {
                BP.canvas.opacity(0.5)
                ProgressView().tint(BP.ink).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: BP.px(132))
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge, lineWidth: 1))
    }
}

/// route-rail.tsx: "Your queue" and the counter over one poster slot per stop, joined by lines lit
/// up to the current stop; while sailing a slot plays its film.
struct VoyageRouteRail: View {
    let active: VoyageModel.Active
    let accent: Color
    var focus: FocusState<String?>.Binding
    let onPlay: ((Meta) -> Void)?
    private let slotW = BP.px(58)

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            HStack(alignment: .firstTextBaseline) {
                Text(T("Your queue")).font(BP.sans(10.5, .semibold)).textCase(.uppercase).tracking(BP.px(2)).foregroundStyle(BP.inkSubtle)
                Spacer()
                Text(active.sailing ? T("%lld of %lld watched", active.watched, active.slots.count)
                                    : T("%lld of %lld picked", active.picked, active.targetLength))
                    .font(BP.sans(12, .semibold)).monospacedDigit().foregroundStyle(BP.inkMuted)
            }
            HStack(spacing: BP.px(8)) {
                ForEach(active.slots, id: \.index) { slot in
                    slotView(slot)
                    if slot.index < active.slots.count - 1 {
                        Capsule().fill(slot.index < active.current ? accent : BP.edge)
                            .frame(height: BP.px(2)).frame(maxWidth: .infinity)
                    }
                }
            }
            .focusSection()
        }
    }

    @ViewBuilder
    private func slotView(_ slot: VoyageModel.Slot) -> some View {
        if let m = slot.meta, let onPlay {
            Button { onPlay(m) } label: { poster(slot, m) }
                .buttonStyle(BPTileStyle())
                .focused(focus, equals: "slot-\(slot.index)")
                .accessibilityLabel(Text(verbatim: "\(T("Play")) \(m.name)"))
                // The slot's tick and bar: "Watched", or "{n}% watched".
                .accessibilityValue(Text(verbatim: slotValue(slot)))
        } else if let m = slot.meta {
            poster(slot, m)
        } else {
            Text(verbatim: "\(slot.index + 1)").font(BP.sans(11, .semibold)).monospacedDigit().foregroundStyle(BP.inkSubtle)
                .frame(width: slotW, height: slotW * 1.5)
                .background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(BP.panel))
                .overlay(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).stroke(BP.edge.opacity(0.4), lineWidth: 1))
        }
    }

    private func slotValue(_ slot: VoyageModel.Slot) -> String {
        if slot.done { return T("Watched") }
        let pct = Int((slot.progress * 100).rounded())
        return pct >= 1 && pct <= 99 ? T("%lld%% watched", pct) : ""
    }

    private func poster(_ slot: VoyageModel.Slot, _ m: Meta) -> some View {
        ZStack(alignment: .topTrailing) {
            RemoteImage(url: m.poster ?? m.background)
                .overlay(Color.black.opacity(slot.done ? 0.45 : 0))
            if slot.done {
                Image(systemName: "checkmark").font(.system(size: BP.px(9), weight: .bold)).foregroundStyle(BP.ink)
                    .frame(width: BP.px(16), height: BP.px(16)).background(Circle().fill(BP.canvas.opacity(0.85)))
                    .padding(BP.px(4))
            }
            if slot.progress > 0 {
                ZStack(alignment: .leading) {
                    BP.canvas.opacity(0.7)
                    accent.frame(width: slotW * CGFloat(min(1, slot.progress)))
                }
                .frame(height: BP.px(3)).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(width: slotW, height: slotW * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous)
            .stroke(slot.current ? accent : BP.edge, lineWidth: slot.current ? 2 : 1))
    }
}

/// port-hover-card.tsx on the TV: the focused heading's card beside the three (a hover card has
/// nothing to hover on a remote): facts, IMDb rating, synopsis, director, cast faces.
struct VoyagePortCard: View {
    let meta: Meta
    /// nil until the credits are asked; .some(nil) when none were found.
    let credits: VoyageModel.Credits??
    let loaded: Bool

    var body: some View {
        let facts = ([meta.releaseInfo, meta.runtime] + (meta.genres ?? []).prefix(2).map { Optional($0) })
            .compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let found: VoyageModel.Credits? = credits.flatMap { $0 }
        let faces = Array((found?.cast ?? []).prefix(6))
        let extra = max(0, (found?.cast.count ?? 0) - 6)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: BP.px(8)) {
                Text(meta.name).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(2)
                HStack(spacing: BP.px(8)) {
                    if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(BP.sans(11.5)).monospacedDigit().foregroundStyle(BP.inkSubtle).lineLimit(1) }
                    if let r = meta.imdbRating, !r.isEmpty {
                        Text(verbatim: "IMDb \(r)").font(BP.sans(11.5, .semibold)).foregroundStyle(BP.inkMuted)
                    }
                }
                if let d = meta.description, !d.isEmpty {
                    Text(d).font(BP.sans(12.5)).foregroundStyle(BP.inkMuted).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
                if let dir = found?.director {
                    Text(T("Directed by %@", dir)).font(BP.sans(11.5)).foregroundStyle(BP.inkSubtle)
                }
                if !loaded || !faces.isEmpty {
                    HStack(spacing: BP.px(10)) {
                        HStack(spacing: -BP.px(8)) {
                            if !loaded {
                                ForEach(0..<4, id: \.self) { _ in Circle().fill(BP.raised).frame(width: BP.px(32), height: BP.px(32)) }
                            } else {
                                ForEach(faces) { p in face(p) }
                                if extra > 0 {
                                    Text(verbatim: "+\(extra)").font(BP.sans(10.5, .semibold)).monospacedDigit().foregroundStyle(BP.inkMuted)
                                        .frame(width: BP.px(32), height: BP.px(32)).background(Circle().fill(BP.raised))
                                }
                            }
                        }
                        if loaded {
                            Text(faces.prefix(3).map(\.name).joined(separator: ", ")).font(BP.sans(11.5)).foregroundStyle(BP.inkMuted).lineLimit(1)
                        }
                    }
                    .padding(.top, BP.px(4))
                }
            }
            .padding(BP.px(16))
            Rectangle().fill(BP.edge).frame(height: 1)
            Text(T("Click to choose")).font(BP.sans(10.5, .medium)).textCase(.uppercase).tracking(BP.px(1.4)).foregroundStyle(BP.inkSubtle)
                .padding(.horizontal, BP.px(16)).padding(.vertical, BP.px(8))
        }
        .frame(width: BP.px(300), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.elevated))
        .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge2, lineWidth: 1))
        .animation(BP.easeFast, value: meta.id)
    }

    private func face(_ p: VoyageModel.Credits.Person) -> some View {
        ZStack {
            Circle().fill(BP.raised)
            if let url = p.profile {
                RemoteImage(url: url).clipShape(Circle())
            } else {
                Text(verbatim: p.name.split(separator: " ").compactMap(\.first).prefix(2).map { String($0) }.joined().uppercased())
                    .font(BP.sans(10.5, .semibold)).foregroundStyle(BP.inkSubtle)
            }
        }
        .frame(width: BP.px(32), height: BP.px(32))
        .overlay(Circle().stroke(BP.elevated, lineWidth: 2))
    }
}
