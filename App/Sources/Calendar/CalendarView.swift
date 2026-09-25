import SwiftUI

/// Calendar room (views/calendar.tsx). Upstream's Big Picture has no calendar, so the desktop
/// screen is set in Big Picture's language for the remote: the header (eyebrow "Releases",
/// month stepper, Today, the reminders bell), the chip rows (source switcher, Sub/Dub, week start,
/// poster size, Filters for Custom, the All / Movies / TV / Anime chips and "Watchlist only"), then
/// the month grid. A day with one release opens it; a busier day opens the day view (day-modal.tsx).
struct CalendarView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model = CalendarModel()
    @ObservedObject private var reminders = ReminderCenter.shared
    @State private var detail: Meta?
    @State private var day: CalendarModel.Cell?
    @State private var showReminders = false
    @State private var showRail = false
    @State private var fired: [ReminderCenter.Fired] = []
    @State private var now = Date()
    @State private var mounted = false
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: BP.px(14)) {
                header
                if !fired.isEmpty { firedBanner }
                sourceRow
                optionRow
                content
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(12)).padding(.bottom, BP.hintHeight + BP.px(40))
        }
        .task {
            // calendar.tsx: useEffect(() => clearUnseenReminders(), []). What fired is shown once.
            // (bug pass) Once per visit: `.task` runs again when a title, day or reminders cover
            // closes, and the second take came back empty, so opening a fired reminder's title
            // wiped the banner behind it.
            if !mounted {
                mounted = true
                fired = await reminders.takeUnseen()
            }
            await model.load()
        }
        .onReceive(tick) { now = $0 }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .fullScreenCover(item: $day) { cell in
            CalendarDayView(cell: cell, hideTypeTag: model.data?.hideTypeTag ?? false, large: model.large)
        }
        .fullScreenCover(isPresented: $showReminders) { RemindersManagerView() }
        .fullScreenCover(isPresented: $showRail, onDismiss: { Task { await model.load() } }) {
            CalendarConfigRailView(resultCount: model.data?.total ?? 0)
        }
    }

    // MARK: header (calendar.tsx <header>)

    private var header: some View {
        HStack(alignment: .bottom, spacing: BP.px(8)) {
            VStack(alignment: .leading, spacing: BP.px(4)) {
                Text("Releases").textCase(.uppercase).font(BP.sans(9, .bold)).tracking(3).foregroundStyle(BP.inkSubtle)
                Text("Calendar").font(BP.display(32, .medium)).foregroundStyle(BP.ink)
            }
            Spacer(minLength: BP.px(12))
            Button { model.prev() } label: { Image(systemName: "chevron.backward") }
                .buttonStyle(BPActionStyle()).accessibilityLabel("Previous month")
            Button("Today") { model.today() }.buttonStyle(BPActionStyle())
            HStack(spacing: BP.px(6)) {
                Image(systemName: "calendar").foregroundStyle(BP.inkSubtle)
                Text(monthLabel).foregroundStyle(BP.ink)
            }
            .font(BP.sans(14, .semibold))
            .padding(.horizontal, BP.px(16))
            .frame(minWidth: BP.px(150), minHeight: BP.tabItem)
            .overlay(Capsule().stroke(BP.edge2, lineWidth: 1))
            Button { model.next() } label: { Image(systemName: "chevron.forward") }
                .buttonStyle(BPActionStyle()).accessibilityLabel("Next month")
            Rectangle().fill(BP.edge2).frame(width: 1, height: BP.px(22)).padding(.horizontal, BP.px(4))
            // components/reminders-manager.tsx RemindersManagerButton: bell + count.
            Button { showReminders = true } label: {
                Image(systemName: "bell").overlay(alignment: .topTrailing) {
                    if reminderCount > 0 {
                        Text("\(reminderCount)").font(BP.sans(8, .bold)).foregroundStyle(BP.canvas)
                            .padding(.horizontal, BP.px(3)).frame(minWidth: BP.px(14), minHeight: BP.px(14))
                            .background(Capsule().fill(BP.ink)).offset(x: BP.px(10), y: -BP.px(8))
                    }
                }
            }
            .buttonStyle(BPActionStyle())
            .accessibilityLabel("Reminders")
        }
        .focusSection()
        .task { reminderCount = await reminders.list().count }
        .onChange(of: showReminders) { _, open in
            if !open { Task { reminderCount = await reminders.list().count } }
        }
    }
    @State private var reminderCount = 0

    private var monthLabel: String {
        if let d = model.data, d.year == model.year, d.month == model.month { return d.monthLabel }
        var c = DateComponents(); c.year = model.year; c.month = model.month + 1; c.day = 1
        guard let date = Calendar.current.date(from: c) else { return "" }
        // While the month loads: Harbor's UI language, like the engine's t(MONTH_NAMES) label.
        return date.formatted(.dateTime.month(.wide).year().locale(L10n.locale))
    }

    // tvOS: lib/reminders-runner.tsx fired these while the viewer was elsewhere (the toast may have
    // been covered by playback); opening the calendar lists them once, as it clears the badge.
    private var firedBanner: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            Text("Reminders").textCase(.uppercase).font(BP.sans(9, .bold)).tracking(2.5).foregroundStyle(BP.inkSubtle)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BP.px(8)) {
                    ForEach(fired) { f in
                        Button {
                            detail = Meta(id: f.id, type: "series", name: f.name, poster: f.poster)
                        } label: {
                            HStack(spacing: BP.px(10)) {
                                Image(systemName: "bell.badge").foregroundStyle(BP.accent)
                                Text(f.name).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                Text(f.body).font(BP.sans(12.5)).foregroundStyle(BP.inkMuted).lineLimit(1)
                            }
                        }
                        .buttonStyle(BPActionStyle())
                    }
                    Button("Dismiss") { withAnimation(BP.easeFast) { fired = [] } }.buttonStyle(BPActionStyle())
                }
            }
        }
        .padding(BP.px(14))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.accent.opacity(0.3), lineWidth: 1))
        .focusSection()
    }

    // MARK: chip rows (calendar.tsx <nav>)

    /// source-switcher.tsx: one pill per visible source.
    private var sourceRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BP.px(6)) {
                ForEach(model.data?.sources ?? []) { s in
                    Button { model.set(source: s.id) } label: { Label(s.label, systemImage: s.icon) }
                        .buttonStyle(BPActionStyle(primary: model.data?.source == s.id)).bpSelected(model.data?.source == s.id)
                        .accessibilityHint(s.hint)
                }
            }
        }
        .focusSection()
    }

    private var optionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BP.px(6)) {
                if let d = model.data {
                    if d.animeDubToggle {
                        Button("Sub") { model.set(animeDub: false) }.buttonStyle(BPActionStyle(primary: !d.animeDub))
                        Button("Dub") { model.set(animeDub: true) }.buttonStyle(BPActionStyle(primary: d.animeDub))
                        divider
                    }
                    Button("Start week on Monday") { model.toggleWeekStart() }.buttonStyle(BPActionStyle(primary: d.weekStartsMonday))
                    // CALENDAR_POSTER_SIZES
                    Button("Default") { model.set(posterSize: "default") }.buttonStyle(BPActionStyle(primary: d.posterSize != "large"))
                    Button("Large") { model.set(posterSize: "large") }.buttonStyle(BPActionStyle(primary: d.posterSize == "large")).bpSelected(d.posterSize == "large")
                    if let custom = d.custom {
                        Button { showRail = true } label: {
                            HStack(spacing: BP.px(6)) {
                                Image(systemName: "slider.horizontal.3")
                                Text("Filters")
                                if custom.activeCount > 0 {
                                    Text("\(custom.activeCount)").font(BP.sans(11, .bold)).foregroundStyle(BP.accent)
                                        .padding(.horizontal, BP.px(5)).background(Capsule().fill(BP.accent.opacity(0.18)))
                                }
                            }
                        }
                        .buttonStyle(BPActionStyle())
                        Text(custom.summary).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                    }
                    if !d.filters.isEmpty {
                        divider
                        ForEach(d.filters) { f in
                            Button { model.set(filter: f.id) } label: {
                                HStack(spacing: BP.px(6)) {
                                    Text(f.label)
                                    Text("\(f.count)").font(BP.sans(11)).opacity(0.65)
                                }
                            }
                            .buttonStyle(BPActionStyle(primary: d.filter == f.id)).bpSelected(d.filter == f.id)
                        }
                    }
                    if d.watchlistToggle {
                        Button { model.toggleWatchlist() } label: {
                            Label("Watchlist only", systemImage: d.watchlistOnly ? "star.fill" : "star")
                        }
                        .buttonStyle(BPActionStyle(primary: d.watchlistOnly))
                        .disabled(!d.signedIn)
                        if !d.signedIn {
                            Text("Sign in to filter by your library").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
                        }
                    }
                }
            }
        }
        .focusSection()
    }

    private var divider: some View { Rectangle().fill(BP.edge2).frame(width: 1, height: BP.px(22)).padding(.horizontal, BP.px(4)) }

    // MARK: body (calendar.tsx `body`)

    @ViewBuilder private var content: some View {
        if let d = model.data {
            switch d.status {
            case "not-signed-in":
                CalendarEmptyShell(heading: "Sign in to see your library calendar",
                                   bodyText: "My Library shows upcoming episodes from the shows you've saved on Stremio. Sign in to wire it up.",
                                   action: ("Sign in", { app.room = .settings }))
            case "no-key":
                CalendarEmptyShell(heading: "All upcoming needs a TMDB key",
                                   bodyText: "TMDB powers the firehose of every release this month. The free tier covers it. About 60 seconds to set up. Switch to My Library if you'd rather only see what you've saved.",
                                   action: ("Open settings", { app.room = .settings }))
            case "error":
                VStack(spacing: BP.px(8)) {
                    Text("Couldn't load the calendar").font(BP.sans(14, .semibold)).foregroundStyle(Color(hex: 0xffe4e6))
                    Text(d.error ?? "Failed to load").font(BP.sans(12.5)).foregroundStyle(Color(hex: 0xffe4e6).opacity(0.85))
                }
                .frame(maxWidth: .infinity).padding(.vertical, BP.px(40))
                .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(Color(hex: 0xfb7185).opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).strokeBorder(Color(hex: 0xfda4af).opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [6, 4])))
            case "empty" where !model.loading:
                CalendarEmptyShell(heading: d.emptyHeading, bodyText: d.emptyBody, action: nil)
            default:
                if model.loading && d.total == 0 { CalendarSkeleton(weekdays: d.weekdays) } else { grid(d) }
            }
        } else {
            CalendarSkeleton(weekdays: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].map { T($0) })
        }
    }

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: BP.px(6)), count: 7)

    /// month-grid.tsx: weekday heads, then 42 day cells; two chips per cell and "+n more".
    private func grid(_ d: CalendarModel.Month) -> some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            LazyVGrid(columns: Self.columns, spacing: BP.px(6)) {
                ForEach(Array(d.weekdays.enumerated()), id: \.offset) { _, w in
                    Text(w.uppercased()).font(BP.sans(9, .bold)).tracking(1.8).foregroundStyle(BP.inkSubtle)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, BP.px(6))
                }
            }
            LazyVGrid(columns: Self.columns, spacing: BP.px(6)) {
                ForEach(d.cells) { cell in
                    if cell.inMonth {
                        Button { open(cell) } label: { CalendarDayCell(cell: cell, hideTypeTag: d.hideTypeTag, large: model.large, now: now) }
                            .buttonStyle(BPTileStyle(radius: BP.rSM))
                            .accessibilityIdentifier("calendar-day-\(cell.iso)")
                    } else {
                        CalendarDayCell(cell: cell, hideTypeTag: d.hideTypeTag, large: model.large, now: now)
                    }
                }
            }
            .focusSection()
        }
    }

    /// calendar-chip.tsx onOpen → openMeta(calendarToMeta(item)); "+n more" → the day modal.
    private func open(_ cell: CalendarModel.Cell) {
        if cell.items.count == 1, let only = cell.items.first { detail = only.meta }
        else if cell.items.count > 1 { day = cell }
    }
}

/// empty-states.tsx EmptyShell: dashed card, calendar glyph, heading, body, optional action.
struct CalendarEmptyShell: View {
    let heading: String
    let bodyText: String
    let action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: BP.px(10)) {
            Image(systemName: "calendar").font(.system(size: BP.px(26), weight: .light)).foregroundStyle(BP.inkSubtle)
            Text(T(heading)).font(BP.sans(16, .semibold)).foregroundStyle(BP.ink).multilineTextAlignment(.center)
            Text(T(bodyText)).font(BP.sans(13)).foregroundStyle(BP.inkMuted).multilineTextAlignment(.center)
                .frame(maxWidth: BP.px(460)).fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(T(action.0)) { action.1() }.buttonStyle(BPActionStyle(primary: true)).padding(.top, BP.px(4))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BP.px(44)).padding(.horizontal, BP.px(24))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.canvas.opacity(0.3)))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).strokeBorder(BP.edge2, style: StrokeStyle(lineWidth: 1, dash: [6, 4])))
        .focusSection()
    }
}

/// One month-grid.tsx cell: the day number and count, then up to two calendar-chip.tsx chips.
struct CalendarDayCell: View {
    let cell: CalendarModel.Cell
    let hideTypeTag: Bool
    let large: Bool
    let now: Date
    private let cap = 2

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(4)) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(cell.day)").font(BP.sans(11.5, .semibold))
                    .foregroundStyle(cell.isToday ? BP.ink : (cell.inMonth ? BP.inkMuted : BP.inkSubtle))
                Spacer(minLength: 0)
                if !cell.items.isEmpty {
                    Text("\(cell.items.count)").font(BP.sans(9.5, .semibold)).foregroundStyle(BP.inkSubtle)
                }
            }
            ForEach(cell.items.prefix(cap)) { item in
                CalendarChip(item: item, hideTypeTag: hideTypeTag, large: large, now: now)
            }
            if cell.items.count > cap {
                Text("+\(cell.items.count - cap) more").font(BP.sans(9.5)).foregroundStyle(BP.inkSubtle)
            }
            Spacer(minLength: 0)
        }
        .padding(BP.px(6))
        .frame(maxWidth: .infinity, minHeight: BP.px(large ? 124 : 104), alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous)
            .fill(cell.inMonth ? (cell.isToday ? BP.elevated.opacity(0.4) : BP.elevated.opacity(0.15)) : BP.canvas.opacity(0.3)))
        .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous)
            .stroke(cell.isToday ? BP.ink.opacity(0.6) : BP.edge.opacity(cell.inMonth ? 1 : 0.4), lineWidth: 1))
        .opacity(cell.inMonth ? 1 : 0.5)
    }
}

/// calendar-chip.tsx: small poster, name, type tag, release time and the airing countdown.
struct CalendarChip: View {
    let item: CalendarModel.Entry
    let hideTypeTag: Bool
    let large: Bool
    let now: Date

    var body: some View {
        HStack(spacing: BP.px(5)) {
            RemoteImage(url: item.poster)
                .frame(width: BP.px(large ? 17 : 12), height: BP.px(large ? 25 : 17))
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: BP.px(4)) {
                    Text(item.name).font(BP.sans(9.5, .medium)).foregroundStyle(BP.ink).lineLimit(1)
                    if !hideTypeTag {
                        Spacer(minLength: 0)
                        CalendarTypeTag(item: item, size: 7)
                    }
                }
                if let time = item.releaseTime {
                    Text([time, AiringCountdown.suffix(item.releaseAtMs, now: now)].compactMap { $0 }.joined(separator: " · "))
                        .font(BP.sans(8.5, .medium)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                }
            }
        }
        .padding(BP.px(3)).padding(.trailing, BP.px(3))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BP.px(5), style: .continuous).fill(BP.canvas.opacity(0.5)))
    }
}

struct CalendarTypeTag: View {
    let item: CalendarModel.Entry
    var size: CGFloat = 8
    var body: some View {
        Text(item.tag.uppercased()).font(BP.sans(size, .bold)).tracking(1)
            .foregroundStyle(item.tagColor)
            .padding(.horizontal, BP.px(3)).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(item.tagColor.opacity(0.2)))
            .fixedSize()
    }
}

/// calendar-skeleton.tsx: the grid's outline with placeholder chips while the month loads.
struct CalendarSkeleton: View {
    let weekdays: [String]
    private static let chips = [2, 0, 1, 3, 0, 1, 0, 2, 1, 0, 0, 2, 1, 3, 0, 1, 0, 2, 0, 1, 2, 0, 1, 0, 3, 1, 0, 2, 0, 1, 0, 2, 1, 0, 1, 0, 2, 0, 1, 3, 0, 1]
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: BP.px(6)), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            LazyVGrid(columns: Self.columns, spacing: BP.px(6)) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, w in
                    Text(w.uppercased()).font(BP.sans(9, .bold)).tracking(1.8).foregroundStyle(BP.inkSubtle)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, BP.px(6))
                }
            }
            LazyVGrid(columns: Self.columns, spacing: BP.px(6)) {
                ForEach(0..<42, id: \.self) { i in
                    VStack(alignment: .leading, spacing: BP.px(4)) {
                        RoundedRectangle(cornerRadius: 3).fill(BP.glass).frame(width: BP.px(14), height: BP.px(9))
                        ForEach(0..<min(Self.chips[i], 2), id: \.self) { _ in
                            RoundedRectangle(cornerRadius: BP.px(5)).fill(BP.glass).frame(height: BP.px(22))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(BP.px(6))
                    .frame(maxWidth: .infinity, minHeight: BP.px(104), alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.elevated.opacity(0.15)))
                    .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge, lineWidth: 1))
                }
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading")
    }
}
