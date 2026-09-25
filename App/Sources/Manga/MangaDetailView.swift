import SwiftUI

/// views/manga/manga-detail.tsx + manga-detail/chapter-list.tsx state: the title, every chapter,
/// the language picked (English when there is one), reading progress, read marks and favourite.
@MainActor
final class MangaDetailModel: ObservableObject {
    let mangaId: String
    @Published private(set) var detail: MangaSummary?
    @Published private(set) var chapters: [MangaChapter] = [] { didSet { derived = nil } }
    @Published private(set) var langs: [MangaDetailResult.Lang] = []
    @Published var selectedLang = "en" { didSet { derived = nil; range = nil; visibleCount = Self.pageSize } }
    @Published private(set) var extName: String?
    @Published private(set) var pending = true
    @Published private(set) var progress: MangaProgressEntry?
    @Published private(set) var readIds: Set<String> = []
    @Published private(set) var favorite = false
    /// chapter-list: oldest first by default; "newest" reverses.
    @Published var newestFirst = false { didSet { derived = nil } }
    /// chapter-list range pager: one 50-chapter bucket, nil for all.
    @Published var range: Int? { didSet { derived = nil } }
    @Published var visibleCount = MangaDetailModel.pageSize

    /// (perf/memory pass) The chapter list's derived arrays, built once per change of chapters,
    /// language, order or range. They were computed properties the page read about ten times per
    /// body pass (each re-filtering every chapter, parsing every chapter number and sorting twice),
    /// and the body runs on every focus move in the list: thousands of chapters on a long series.
    private struct Derived {
        var langFiltered: [MangaChapter]
        var ranges: [PageRange]
        var showPager: Bool
        var ascending: [MangaChapter]
        var ordered: [MangaChapter]
    }
    private var derived: Derived?

    nonisolated static let pageSize = 200

    init(mangaId: String) { self.mangaId = mangaId }

    private var pid: String { MangaStore.shared.pid }
    var ref: MangaRef { MangaRef(id: mangaId, title: detail?.title ?? "", cover: detail?.cover) }

    /// (bug pass 3) The detail answered once. The page's `.task` runs again whenever a cover over it
    /// closes (the reader), and a full reload there re-fetched every chapter chunk and put the
    /// language back to the default: a viewer reading the Japanese chapters came back to English.
    private var loadedOnce = false

    /// The first load of this page; later appearances keep what the viewer picked (Try again reloads).
    func loadIfNeeded() async {
        guard !loadedOnce else { return }
        await load()
    }

    func load() async {
        pending = true
        // Opened from Search or an anime page: the servers' image auth may not be known yet.
        if MangaStore.shared.state == nil { await MangaStore.shared.refresh() }
        if let r: MangaDetailResult = try? await HarborEngine.shared.call("manga.detail", [mangaId]) {
            detail = r.detail
            chapters = r.chapters
            langs = r.langs
            extName = r.extName
            if selectedLang != r.defaultLang { selectedLang = r.defaultLang }
            loadedOnce = r.detail != nil || !r.chapters.isEmpty
        }
        pending = false
        await refreshMarks()
    }

    func refreshMarks() async {
        progress = try? await HarborEngine.shared.call("manga.progressFor", [pid, mangaId, detail?.title])
        readIds = Set((try? await HarborEngine.shared.call("manga.readChapters", [pid, mangaId]) as [String]) ?? [])
        favorite = (try? await HarborEngine.shared.call("manga.isFavorite", [pid, mangaId])) ?? false
    }

    func toggleFavorite() async {
        guard detail != nil else { return }
        favorite = await MangaStore.shared.toggleFavorite(ref)
    }

    /// The chapters in the picked language (manga-detail langFiltered).
    var langFiltered: [MangaChapter] { derivedLists.langFiltered }
    var canRead: Bool { !langFiltered.isEmpty }

    /// chapter-list ascending: by chapter number, a chapter with none by its position.
    var ascending: [MangaChapter] { derivedLists.ascending }

    var ordered: [MangaChapter] { derivedLists.ordered }

    /// chapter-list bucketOf: 1-50, 51-100, ...
    static func bucket(_ n: Double) -> Int { Int(floor((ceil(n) - 1) / 50)) }

    /// chapter-list ranges, newest bucket first; shown past 60 chapters with more than one bucket.
    struct PageRange: Identifiable, Hashable { var b: Int; var lo: Int; var hi: Int; var id: Int { b } }
    var ranges: [PageRange] { derivedLists.ranges }
    var showPager: Bool { derivedLists.showPager }

    private var derivedLists: Derived {
        if let held = derived { return held }
        let list: [MangaChapter] = chapters.filter { ($0.language ?? "") == selectedLang }
        // ranges
        var maxN = 0.0
        var buckets = Set<Int>()
        for (i, c) in list.enumerated() {
            let n = c.number(fallback: i)
            maxN = max(maxN, ceil(n))
            buckets.insert(Self.bucket(n))
        }
        let ranges: [PageRange] = buckets.sorted(by: >).map { b in PageRange(b: b, lo: b * 50 + 1, hi: min(b * 50 + 50, Int(maxN))) }
        let pager: Bool = list.count > 60 && ranges.count > 1
        // ascending
        let nums = Dictionary(list.enumerated().map { ($0.element.id, $0.element.number(fallback: $0.offset)) }, uniquingKeysWith: { a, _ in a })
        var narrowed = list
        if pager, let range { narrowed = list.filter { Self.bucket(nums[$0.id] ?? 0) == range } }
        let ascending: [MangaChapter] = narrowed.sorted { (nums[$0.id] ?? 0) < (nums[$1.id] ?? 0) }
        let ordered: [MangaChapter] = newestFirst ? Array(ascending.reversed()) : ascending
        let made = Derived(langFiltered: list, ranges: ranges, showPager: pager, ascending: ascending, ordered: ordered)
        derived = made
        return made
    }

    func isRead(_ c: MangaChapter) -> Bool { c.serverRead == true || readIds.contains(c.id) }

    /// manga-detail handleResume: the saved chapter in the picked language's list, else the
    /// owning source's copy (views/manga.tsx resume).
    func resumeLaunch(_ entry: MangaProgressEntry) async -> MangaReaderLaunch? {
        let pool = langFiltered.isEmpty ? chapters : langFiltered
        let i: Int = (try? await HarborEngine.shared.call("manga.matchChapter", [entry, pool])) ?? -1
        if i >= 0 { return MangaReaderLaunch(manga: ref, chapters: pool, index: i, startPage: nil) }
        return await MangaStore.shared.resume(entry)
    }
}

/// The manga detail page (manga-detail.tsx): cover, title, facts, Read latest / Resume, favourite,
/// synopsis, then the chapter list with its language, order and range pickers.
@MainActor
struct MangaDetailView: View {
    @StateObject private var model: MangaDetailModel
    @State private var reader: MangaReaderLaunch?
    @State private var expanded = false
    /// The Resume button's lookup is in flight.
    @State private var resuming = false
    @FocusState private var chapterFocus: String?
    @Environment(\.dismiss) private var dismiss

    init(mangaId: String) { _model = StateObject(wrappedValue: MangaDetailModel(mangaId: mangaId)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            if model.detail == nil && model.chapters.isEmpty {
                if model.pending {
                    ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    errorView
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: BP.px(28)) {
                        hero
                        chapterSection
                        Color.clear.frame(height: BP.px(40))
                    }
                    .padding(.horizontal, BP.gutter)
                    .padding(.top, BP.px(70))
                }
            }
        }
        .ignoresSafeArea()
        .task { await model.loadIfNeeded() }
        .fullScreenCover(item: $reader, onDismiss: { Task { await model.refreshMarks() } }) { l in
            MangaReaderView(launch: l) { reader = nil }
        }
    }

    private var backdrop: some View {
        ZStack {
            BP.void_
            if let cover = model.detail?.cover {
                RemoteImage(url: cover).blur(radius: 40).scaleEffect(1.18).opacity(0.45)
                    .frame(maxWidth: .infinity, maxHeight: BP.px(560)).clipped()
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            LinearGradient(colors: [BP.void_.opacity(0.35), BP.void_.opacity(0.85), BP.void_], startPoint: .top, endPoint: .init(x: 0.5, y: 0.62))
            LinearGradient(colors: [BP.void_.opacity(0.9), .clear], startPoint: .leading, endPoint: .init(x: 0.7, y: 0.5))
        }
        .ignoresSafeArea()
    }

    /// manga-detail MangaDetailError.
    private var errorView: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            Text("This title would not open").font(BP.display(30)).foregroundStyle(BP.ink)
            BPNote(text: "The source returned a bad response for this manga. It may be temporary, or the title may have moved. Try another source, or head back and pick something else.")
                .frame(maxWidth: BP.px(620), alignment: .leading)
            HStack(spacing: BP.px(10)) {
                Button { Task { await model.load() } } label: { Label("Try again", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(BPActionStyle(primary: true))
                Button { dismiss() } label: { Label("Back to browse", systemImage: "chevron.backward") }
                    .buttonStyle(BPActionStyle())
            }
        }
        .padding(.horizontal, BP.gutter).padding(.top, BP.px(220))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var pills: [String] {
        var out: [String] = []
        if let y = model.detail?.year { out.append(String(Int(y))) }
        if let s = model.detail?.statusLabel { out.append(s) }
        let n = model.chapters.count
        out.append(n == 1 ? T("%lld chapter", n) : T("%lld chapters", n))
        return out
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: BP.px(26)) {
            RemoteImage(url: model.detail?.cover)
                .frame(width: BP.px(170), height: BP.px(255))
                .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            VStack(alignment: .leading, spacing: BP.px(12)) {
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    Text(model.detail?.title ?? T("Untitled")).font(BP.display(40)).foregroundStyle(BP.ink).lineLimit(2)
                    if let alt = model.detail?.altTitle, !alt.isEmpty { Text(alt).font(BP.sans(15)).foregroundStyle(BP.inkMuted).lineLimit(1) }
                    if let a = model.detail?.author, !a.isEmpty { Text("by \(a)").font(BP.sans(14)).foregroundStyle(BP.inkMuted) }
                }
                HStack(spacing: BP.px(8)) {
                    if let ext = model.extName { pill(ext, strong: true) }
                    ForEach(pills, id: \.self) { p in pill(p, dot: p == model.detail?.statusLabel) }
                }
                actions
                if let d = model.detail?.description, !d.isEmpty {
                    Button { expanded.toggle() } label: {
                        Text(d).font(BP.sans(14)).foregroundStyle(BP.inkMuted).lineSpacing(3)
                            .lineLimit(expanded ? nil : 4).multilineTextAlignment(.leading)
                            .frame(maxWidth: BP.px(760), alignment: .leading)
                    }
                    .buttonStyle(MangaTextStyle())
                }
            }
        }
    }

    private func pill(_ text: String, strong: Bool = false, dot: Bool = false) -> some View {
        HStack(spacing: BP.px(6)) {
            if dot { Circle().fill(text.lowercased().contains("ongoing") ? BP.live : BP.inkSubtle).frame(width: BP.px(7), height: BP.px(7)) }
            Text(text)
        }
        .font(BP.sans(12.5, strong ? .semibold : .regular)).foregroundStyle(strong ? BP.ink : BP.inkMuted)
        .padding(.horizontal, BP.px(11)).padding(.vertical, BP.px(5))
        .background(Capsule().fill(BP.elevated.opacity(0.6)))
        .overlay(Capsule().stroke(BP.edge, lineWidth: 1))
    }

    private var actions: some View {
        HStack(spacing: BP.px(10)) {
            // manga-detail "Read latest": the last chapter of the picked language, in source order.
            Button {
                let list = model.langFiltered
                guard !list.isEmpty else { return }
                reader = MangaReaderLaunch(manga: model.ref, chapters: list, index: list.count - 1, startPage: nil)
            } label: { Label("Read latest", systemImage: "book") }
                .buttonStyle(BPActionStyle(primary: true))
                .disabled(!model.canRead)
            // (device-flow pass) One button for Resume / Start from beginning: reading from "Start from
            // beginning" saves progress, and swapping in a separate Resume button on the way back left
            // the remote's focus with nothing to return to.
            Button {
                if let p = model.progress {
                    // (kids/music pass 2) One resume at a time, and a late one never replaces a reader
                    // already up: the saved chapter's lookup can go to the network (MangaStore.resume
                    // when it is not in this list), so a double press opened the reader twice (the
                    // second swapped in over the first) and Read latest pressed meanwhile was replaced.
                    guard !resuming else { return }
                    resuming = true
                    Task {
                        let l = await model.resumeLaunch(p)
                        resuming = false
                        if let l, reader == nil { reader = l }
                    }
                } else {
                    let list = model.langFiltered
                    guard !list.isEmpty else { return }
                    reader = MangaReaderLaunch(manga: model.ref, chapters: list, index: 0, startPage: nil)
                }
            } label: {
                if let p = model.progress {
                    Label(p.resumeLabel, systemImage: "arrow.counterclockwise")
                } else {
                    Text("Start from beginning")
                }
            }
            .buttonStyle(BPActionStyle(busy: resuming))
            .disabled(model.progress == nil && !model.canRead)
            Button { Task { await model.toggleFavorite() } } label: {
                Image(systemName: model.favorite ? "heart.fill" : "heart")
            }
            .buttonStyle(BPActionStyle(primary: model.favorite))
            .accessibilityLabel(model.favorite ? "Remove favorite" : "Add favorite")
            .disabled(model.detail == nil)
        }
        .focusSection()
    }

    // MARK: chapters (manga-detail/chapter-list.tsx)

    private var chapterSection: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            HStack(spacing: BP.px(12)) {
                Text("Chapters").font(BP.sans(22, .bold)).foregroundStyle(BP.ink)
                Text("\(model.langFiltered.count)").font(BP.sans(15, .semibold)).foregroundStyle(BP.inkSubtle)
                if model.pending { Text("checking other sources").font(BP.sans(12)).foregroundStyle(BP.inkSubtle) }
                Spacer()
            }
            if model.langs.count > 1 || !model.langFiltered.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BP.px(8)) {
                        if model.langs.count > 1 {
                            ForEach(model.langs) { l in
                                Button(MangaLanguage.name(l.code) + " (\(l.count))") { model.selectedLang = l.code }
                                    .buttonStyle(BPActionStyle(primary: model.selectedLang == l.code)).bpSelected(model.selectedLang == l.code)
                            }
                            Rectangle().fill(BP.edge2).frame(width: 1, height: BP.px(26))
                        }
                        Button(model.newestFirst ? "Newest first" : "Oldest first") { model.newestFirst.toggle() }
                            .buttonStyle(BPActionStyle())
                        if model.showPager {
                            Button("All") { model.range = nil }.buttonStyle(BPActionStyle(primary: model.range == nil)).bpSelected(model.range == nil)
                            ForEach(model.ranges) { r in
                                Button("\(r.lo)–\(r.hi)") { model.range = r.b }.buttonStyle(BPActionStyle(primary: model.range == r.b)).bpSelected(model.range == r.b)
                            }
                        }
                    }
                    .padding(.vertical, BP.px(8))
                }
                .scrollClipDisabled()
                .focusSection()
            }
            if model.langFiltered.isEmpty {
                BPNote(text: model.pending ? "Loading chapters..." : T("No chapters available in %@ from this source.", MangaLanguage.name(model.selectedLang)))
            } else {
                let ordered = model.ordered
                let ascending = model.ascending
                LazyVStack(alignment: .leading, spacing: BP.px(8)) {
                    ForEach(ordered.prefix(model.visibleCount)) { c in
                        Button {
                            let i = ascending.firstIndex(where: { $0.id == c.id }) ?? 0
                            reader = MangaReaderLaunch(manga: model.ref, chapters: ascending, index: i, startPage: nil)
                        } label: { chapterRow(c) }
                            .buttonStyle(BPTileStyle(radius: BP.rSM))
                            .focused($chapterFocus, equals: c.id)
                    }
                    if ordered.count > model.visibleCount {
                        Button("Show \(min(MangaDetailModel.pageSize, ordered.count - model.visibleCount)) more") {
                            // (device-flow pass) The ring moves to the first chapter revealed: on the last
                            // batch the button goes away under the remote and focus jumped off the list.
                            let first: String? = ordered.indices.contains(model.visibleCount) ? ordered[model.visibleCount].id : nil
                            model.visibleCount += MangaDetailModel.pageSize
                            if let first { DispatchQueue.main.async { chapterFocus = first } }
                        }
                        .buttonStyle(BPActionStyle())
                    }
                }
                .focusSection()
            }
        }
    }

    private func chapterRow(_ c: MangaChapter) -> some View {
        let current = model.progress?.chapterId == c.id
        let group: String? = c.displayGroup.isEmpty ? nil : c.displayGroup
        let meta = [group, c.relativeDate].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: BP.px(14)) {
            VStack(alignment: .leading, spacing: BP.px(3)) {
                HStack(spacing: BP.px(8)) {
                    Text(c.shortLabel).font(BP.sans(15, .bold)).foregroundStyle(current ? BP.accent : BP.ink)
                    if !current && model.isRead(c) {
                        Label("Read", systemImage: "checkmark").font(BP.sans(11, .semibold)).foregroundStyle(BP.inkSubtle)
                    }
                }
                Text(c.title?.isEmpty == false ? c.title! : (c.chapter.map { T("Chapter %@", $0) } ?? T("Oneshot")))
                    .font(BP.sans(13)).foregroundStyle(BP.inkMuted).lineLimit(1)
                if current, let p = model.progress, p.upNext != true, p.totalPages > 0 {
                    HStack(spacing: BP.px(8)) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(BP.edge2)
                                Capsule().fill(BP.accent).frame(width: g.size.width * p.fraction)
                            }
                        }
                        .frame(width: BP.px(120), height: BP.px(3))
                        Text("\(Int(p.page))/\(Int(p.totalPages))").font(BP.sans(11, .semibold)).monospacedDigit().foregroundStyle(BP.inkSubtle)
                    }
                }
            }
            Spacer(minLength: BP.px(10))
            if !meta.isEmpty { Text(meta).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).lineLimit(1) }
            if c.downloaded == true { Image(systemName: "server.rack").font(.system(size: BP.px(13))).foregroundStyle(BP.inkSubtle) }
            Image(systemName: "book").font(.system(size: BP.px(15))).foregroundStyle(BP.inkSubtle)
        }
        .padding(.horizontal, BP.px(16)).padding(.vertical, BP.px(11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(current ? BP.accent.opacity(0.08) : BP.panel.opacity(0.85)))
    }
}

/// A focusable block of text (the synopsis): brightens on focus, Select expands it.
struct MangaTextStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .padding(BP.px(8))
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(focused ? BP.glass : .clear))
                .animation(BP.easeFast, value: focused)
        }
    }
}
