import SwiftUI

/// calendar/day-modal.tsx: "Releases", the long date, "{n} titles", then one row per release
/// (poster, type tag, rating, name, time with the airing countdown, two lines of overview).
struct CalendarDayView: View {
    let cell: CalendarModel.Cell
    let hideTypeTag: Bool
    let large: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var detail: Meta?
    @State private var now = Date()
    @FocusState private var focus: String?
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            BP.void_.opacity(0.8).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: BP.px(3)) {
                    Text("Releases").textCase(.uppercase).font(BP.sans(9, .bold)).tracking(2.5).foregroundStyle(BP.inkSubtle)
                    Text(cell.items.first?.dateLong ?? cell.iso).font(BP.display(20, .medium)).foregroundStyle(BP.ink)
                    Text(cell.items.count == 1 ? "\(cell.items.count) title" : "\(cell.items.count) titles")
                        .font(BP.sans(12.5)).foregroundStyle(BP.inkMuted)
                }
                .padding(BP.px(20))
                Rectangle().fill(BP.edge).frame(height: 1)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: BP.px(8)) {
                        ForEach(cell.items) { item in
                            Button { detail = item.meta } label: { row(item) }
                                .buttonStyle(BPTileStyle(radius: BP.rMD))
                                .focused($focus, equals: item.id)
                        }
                    }
                    .padding(BP.px(14))
                }
            }
            .frame(width: BP.px(600))
            .frame(maxHeight: BP.px(560))
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.elevated))
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge2, lineWidth: 1))
            .shadow(color: .black.opacity(0.7), radius: 40, y: 24)
        }
        .onExitCommand { dismiss() }
        .onReceive(tick) { now = $0 }
        // (bug pass) Only on arrival: `.task` runs again when a release's title cover closes, and
        // focus jumped from that row back to the first one.
        .task {
            guard !focusPlaced else { return }
            focusPlaced = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focus = cell.items.first?.id }
        }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
    }
    @State private var focusPlaced = false

    private func row(_ item: CalendarModel.Entry) -> some View {
        HStack(alignment: .top, spacing: BP.px(12)) {
            RemoteImage(url: item.poster)
                .frame(width: BP.px(large ? 78 : 52), height: BP.px(large ? 117 : 78))
                .clipShape(RoundedRectangle(cornerRadius: BP.px(6), style: .continuous))
            VStack(alignment: .leading, spacing: BP.px(4)) {
                HStack(spacing: BP.px(8)) {
                    if !hideTypeTag { CalendarTypeTag(item: item, size: 8.5) }
                    if item.rating > 0 {
                        (Text("★ ").foregroundColor(Color(hex: 0xfcd34d)) + Text(String(format: "%.1f", item.rating)).foregroundColor(BP.inkMuted))
                            .font(BP.sans(11))
                    }
                }
                Text(item.name).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(2)
                if let time = item.releaseTime {
                    HStack(spacing: BP.px(4)) {
                        Image(systemName: "clock").foregroundStyle(Color(hex: 0xfda4af))
                        Text(time).foregroundStyle(BP.inkSubtle)
                        if let left = AiringCountdown.suffix(item.releaseAtMs, now: now) {
                            Text("· \(left)").foregroundStyle(BP.accent)
                        }
                    }
                    .font(BP.sans(11, .medium))
                }
                if let o = item.overview, !o.isEmpty {
                    Text(o).font(BP.sans(12)).foregroundStyle(BP.inkMuted).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(BP.px(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.canvas.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
    }
}

/// components/reminders-manager.tsx: every reminder (newest first) with its summary; a row opens
/// the show, the cross removes it ("Reminder removed").
struct RemindersManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ReminderCenter.Row] = []
    @State private var loaded = false
    @State private var note: String?
    @State private var detail: Meta?
    @FocusState private var focus: String?

    var body: some View {
        ZStack(alignment: .trailing) {
            BP.void_.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(10)) {
                Text("Reminders").textCase(.uppercase).font(BP.sans(10, .semibold)).tracking(1.5).foregroundStyle(BP.inkSubtle)
                if loaded && rows.isEmpty {
                    BPNote(text: "No reminders yet. Use the clock on a show's page to get told about new episodes and seasons.")
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: BP.px(6)) {
                        ForEach(rows) { r in
                            HStack(spacing: BP.px(8)) {
                                Button {
                                    detail = Meta(id: r.id, type: r.type == "movie" ? "movie" : "series", name: r.name, poster: r.poster)
                                } label: {
                                    HStack(spacing: BP.px(10)) {
                                        ZStack {
                                            BP.raised
                                            if r.poster != nil { RemoteImage(url: r.poster) } else { Image(systemName: "bell").foregroundStyle(BP.inkSubtle) }
                                        }
                                        .frame(width: BP.px(30), height: BP.px(40))
                                        .clipShape(RoundedRectangle(cornerRadius: BP.px(5), style: .continuous))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(r.name).font(BP.sans(13.5, .medium)).foregroundStyle(BP.ink).lineLimit(1)
                                            Text(r.summary).font(BP.sans(11.5)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                        if r.unseen { Circle().fill(BP.danger).frame(width: BP.px(7), height: BP.px(7)) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, BP.px(4))
                                }
                                .buttonStyle(BPActionStyle())
                                .focused($focus, equals: r.id)
                                Button { Task { await remove(r) } } label: { Image(systemName: "xmark") }
                                    .buttonStyle(BPActionStyle())
                                    .accessibilityLabel("Remove reminder")
                            }
                            .focusSection()
                        }
                    }
                }
                if let note { BPNote(text: note) }
                Spacer(minLength: 0)
                Button("Close") { dismiss() }.buttonStyle(BPActionStyle()).focused($focus, equals: "close")
            }
            .padding(BP.px(24))
            .frame(width: BP.px(480), alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(BP.panel.opacity(0.98))
            .ignoresSafeArea()
        }
        .onExitCommand { dismiss() }
        .task {
            // (bug pass) Once: `.task` runs again when a show's cover closes (onDismiss already
            // re-reads the rows), and focus jumped from that show back to the first row.
            guard !loaded else { return }
            rows = await ReminderCenter.shared.list()
            loaded = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focus = rows.first?.id ?? "close" }
        }
        .fullScreenCover(item: $detail, onDismiss: { Task { rows = await ReminderCenter.shared.list() } }) { m in DetailView(meta: m) }
    }

    private func remove(_ r: ReminderCenter.Row) async {
        let index = rows.firstIndex(of: r) ?? 0
        rows = await ReminderCenter.shared.remove(r.id)
        note = "Reminder removed"
        focus = rows.isEmpty ? "close" : rows[min(index, rows.count - 1)].id
    }
}

/// calendar/config/config-rail.tsx for the Custom source: the result pill, Show (media types),
/// Genres / Where to watch / Origin country / Track people chip groups, the two Trakt sources and
/// Clear all. People are added through CalendarPeopleSearchView (PeopleField: TMDB search).
struct CalendarConfigRailView: View {
    let resultCount: Int
    @Environment(\.dismiss) private var dismiss
    @State private var rail: Rail?
    @State private var open: Set<String> = ["genres"]
    @State private var addingPerson = false

    struct Chip: Decodable, Identifiable, Equatable { var key: String; var label: String; var selected: Bool; var id: String { key } }
    struct RailGroup: Decodable, Identifiable, Equatable { var id: String; var title: String; var count: Int; var summary: String; var chips: [Chip] }
    struct TraktRow: Decodable, Identifiable, Equatable { var key: String; var label: String; var sub: String; var on: Bool; var disabled: Bool; var id: String { key } }
    struct Rail: Decodable, Equatable {
        var activeCount: Int; var summary: String; var traktConnected: Bool; var tmdbKey: Bool
        var mediaTypes: [Chip]; var groups: [RailGroup]; var trakt: [TraktRow]
    }

    private static let chipColumns = [GridItem(.adaptive(minimum: BP.px(118)), spacing: BP.px(6), alignment: .leading)]

    var body: some View {
        ZStack(alignment: .trailing) {
            BP.void_.opacity(0.55).ignoresSafeArea()
            peopleSheet
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(14)) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Filters").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).accessibilityAddTraits(.isHeader)
                            Text(rail?.summary ?? "").font(BP.sans(12)).foregroundStyle(BP.inkMuted).lineLimit(2)
                        }
                        Spacer()
                        // result-pill.tsx
                        Text(resultCount == 1 ? "1 " + T("result") : T("%lld results", resultCount))
                            .font(BP.sans(11.5, .semibold)).foregroundStyle(BP.ink)
                            .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(4))
                            .background(Capsule().fill(BP.glass))
                    }
                    if rail?.tmdbKey == false {
                        BPNote(text: "All upcoming needs a TMDB key", tone: BP.danger)
                    }
                    if let rail {
                        section("SHOW") {
                            HStack(spacing: BP.px(6)) {
                                ForEach(rail.mediaTypes) { c in chip(c) }
                            }
                            .focusSection()
                        }
                        ForEach(rail.groups) { g in groupView(g) }
                        section("TRAKT SOURCES") {
                            VStack(alignment: .leading, spacing: BP.px(6)) {
                                ForEach(rail.trakt) { row in
                                    Button { toggle(row.key) } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(row.label)
                                                Text(row.sub).font(BP.sans(11)).foregroundStyle(BP.inkSubtle)
                                            }
                                            Spacer()
                                            Image(systemName: row.on ? "checkmark.circle.fill" : "circle")
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, BP.px(4))
                                    }
                                    .buttonStyle(BPActionStyle(primary: row.on))
                                    .disabled(row.disabled)
                                }
                            }
                        }
                        HStack(spacing: BP.px(8)) {
                            Text(rail.activeCount > 0 ? "\(rail.activeCount) active" : "No filters").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
                            Spacer()
                            Button("Clear all") { toggle("clear") }.buttonStyle(BPActionStyle()).disabled(rail.activeCount == 0)
                            Button("Close") { dismiss() }.buttonStyle(BPActionStyle(primary: true))
                        }
                        .focusSection()
                    }
                }
                .padding(BP.px(24))
            }
            .frame(width: BP.px(560))
            .frame(maxHeight: .infinity)
            .background(BP.panel.opacity(0.98))
            .ignoresSafeArea()
        }
        .onExitCommand { dismiss() }
        .task { await load() }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            Text(title).font(BP.sans(9.5, .bold)).tracking(2).foregroundStyle(BP.inkSubtle)
            content()
        }
    }

    /// config-group.tsx: header (title, count, summary) toggles the group; Clear empties it.
    private func groupView(_ g: RailGroup) -> some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            HStack(spacing: BP.px(8)) {
                Button {
                    if open.contains(g.id) { _ = open.remove(g.id) } else { _ = open.insert(g.id) }
                } label: {
                    HStack(spacing: BP.px(8)) {
                        Image(systemName: open.contains(g.id) ? "chevron.down" : "chevron.forward")
                        Text(g.title)
                        if g.count > 0 { Text("\(g.count)").foregroundStyle(BP.accent) }
                        if !g.summary.isEmpty && !open.contains(g.id) {
                            Text(g.summary).font(BP.sans(11.5)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(BPActionStyle())
                if g.count > 0 { Button("Clear") { toggle("clear:\(g.id)") }.buttonStyle(BPActionStyle()) }
            }
            if open.contains(g.id) {
                // people-field.tsx: the search that adds a person (TMDB people, 8 results).
                if g.id == "people" {
                    Button { addingPerson = true } label: { Label(T("Search actors, directors…"), systemImage: "person.badge.plus") }
                        .buttonStyle(BPActionStyle())
                }
                if g.chips.isEmpty {
                    if g.id != "people" { BPNote(text: T("Nothing here yet.")) }
                } else {
                    LazyVGrid(columns: Self.chipColumns, alignment: .leading, spacing: BP.px(6)) {
                        ForEach(g.chips) { c in chip(c) }
                    }
                }
            }
        }
        .focusSection()
    }

    private func chip(_ c: Chip) -> some View {
        Button { toggle(c.key) } label: {
            HStack(spacing: BP.px(5)) {
                if c.selected { Image(systemName: c.key.hasPrefix("person:") ? "xmark" : "checkmark") }
                Text(c.label).lineLimit(1)
            }
        }
        .buttonStyle(BPActionStyle(primary: c.selected))
    }

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    private func load() async {
        let p = profile
        rail = try? await HarborEngine.shared.call("calendar.customRail", [p.id, p.linked])
    }

    /// The sheet is mounted from the rail's body (below) so the panel keeps its own focus state.
    fileprivate var peopleSheet: some View {
        Color.clear.frame(width: 0, height: 0).fullScreenCover(isPresented: $addingPerson) {
            CalendarPeopleSearchView(onAdded: { next in rail = next })
        }
    }

    private func toggle(_ key: String) {
        let p = profile
        Task {
            if let next: Rail = try? await HarborEngine.shared.call("calendar.customToggle", [p.id, p.linked, key]) { rail = next }
        }
    }
}

// MARK: - shell pieces (mounted by ShellView; kept here so the shell edit stays one line each)

/// nav-items.tsx CalendarNavIcon: the unseen-reminder count on the Calendar tab ("9+" past nine).
struct CalendarTabBadge: View {
    @ObservedObject private var center = ReminderCenter.shared
    var body: some View {
        if center.unseen > 0 {
            Text(center.unseen > 9 ? "9+" : "\(center.unseen)")
                .font(BP.sans(8, .bold)).foregroundStyle(.white)
                .padding(.horizontal, BP.px(2.5))
                .frame(minWidth: BP.px(13), minHeight: BP.px(13))
                .background(Capsule().fill(BP.danger))
                .offset(x: BP.px(3), y: -BP.px(3))
                .allowsHitTesting(false)
                .accessibilityLabel("\(center.unseen) new reminders")
        }
    }
}

/// App.tsx <RemindersRunner /> + the list toast it raises: starts the engine's runner for the
/// active profile and shows "{name}: {body}" for a few seconds when one fires.
struct ReminderToastHost: View {
    @ObservedObject private var center = ReminderCenter.shared
    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if let text = center.toast {
                HStack(spacing: BP.px(8)) {
                    Image(systemName: "bell.badge.fill").foregroundStyle(BP.accent)
                    Text(text).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(2)
                }
                .padding(.horizontal, BP.px(16)).padding(.vertical, BP.px(9))
                .background(Capsule().fill(BP.panel))
                .overlay(Capsule().stroke(BP.edge2, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
                .padding(.top, BP.barHeight + BP.px(8))
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(5))
                    withAnimation(BP.easeFast) { center.toast = nil }
                }
            }
        }
        .animation(BP.easeFast, value: center.toast)
        .allowsHitTesting(false)
        .task { await center.attach() }
    }
}


/// calendar/config/people-field.tsx on the TV: type a name (or on the phone), TMDB people after
/// 220 ms, Select adds the person (config-rail.tsx addPerson, role "any"); already tracked people
/// are shown but disabled, as upstream.
struct CalendarPeopleSearchView: View {
    let onAdded: (CalendarConfigRailView.Rail) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var result: Found?
    @State private var busy = false

    struct Person: Decodable, Identifiable { var id: Int; var name: String; var profile: String?; var knownFor: String; var tracked: Bool }
    struct Found: Decodable { var needsKey: Bool; var people: [Person] }
    private struct Pick: Encodable { var id: Int; var name: String; var profile: String? }

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }

    var body: some View {
        ZStack {
            BP.void_.opacity(0.94).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(14)) {
                Text(T("Track people")).font(BP.display(30)).foregroundStyle(BP.ink)
                BPField(label: T("Track people"), placeholder: T("Search actors, directors…"), text: $query, phone: true)
                    .frame(maxWidth: BP.px(720))
                if result?.needsKey == true {
                    BPNote(text: T("Add a TMDB key in settings first"), tone: BP.danger)
                } else if busy {
                    ProgressView().tint(BP.inkMuted)
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: BP.px(8)) {
                        ForEach(result?.people ?? []) { person in
                            Button { add(person) } label: {
                                HStack(spacing: BP.px(12)) {
                                    RemoteImage(url: person.profile).frame(width: BP.px(44), height: BP.px(44)).clipShape(Circle())
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(person.name).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                        if !person.knownFor.isEmpty { Text(person.knownFor).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1) }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: person.tracked ? "checkmark" : "plus").foregroundStyle(BP.inkMuted)
                                }
                                .padding(.horizontal, BP.px(12)).padding(.vertical, BP.px(8))
                                .frame(width: BP.px(720), alignment: .leading)
                            }
                            .buttonStyle(BPTileStyle(radius: BP.rMD))
                            .disabled(person.tracked)
                        }
                    }
                    .padding(.vertical, BP.px(6))
                }
                .scrollClipDisabled()
                Button(T("Close")) { dismiss() }.buttonStyle(BPActionStyle())
            }
            .padding(BP.gutter).padding(.top, BP.px(40))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onExitCommand { dismiss() }
        .task(id: query) {
            // people-field.tsx: 220 ms after the last keystroke.
            try? await Task.sleep(for: .milliseconds(220))
            if Task.isCancelled { return }
            busy = true
            let p = profile
            let found: Found? = try? await HarborEngine.shared.call("calendar.customPeopleSearch", [p.id, p.linked, query])
            if !Task.isCancelled { result = found }
            busy = false
        }
    }

    private func add(_ person: Person) {
        let p = profile
        Task {
            if let next: CalendarConfigRailView.Rail = try? await HarborEngine.shared.call("calendar.customAddPerson", [p.id, p.linked, Pick(id: person.id, name: person.name, profile: person.profile)] as [any Encodable]) {
                onAdded(next)
            }
            dismiss()
        }
    }
}
