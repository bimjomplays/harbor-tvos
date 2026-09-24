import SwiftUI

/// views/manga/manga-detail.tsx + manga-detail/chapter-list.tsx state: the title, every chapter,
/// the language picked (English when there is one), reading progress, read marks and favourite.
@MainActor
final class MangaDetailModel: ObservableObject {
    let mangaId: String
    @Published private(set) var detail: MangaSummary?
    @Published private(set) var chapters: [MangaChapter] = []
    @Published private(set) var langs: [MangaDetailResult.Lang] = []
    @Published var selectedLang = "en" { didSet { range = nil; visibleCount = Self.pageSize } }
    @Published private(set) var extName: String?
    @Published private(set) var pending = true
    @Published private(set) var progress: MangaProgressEntry?
    @Published private(set) var readIds: Set<String> = []
    @Published private(set) var favorite = false
    /// chapter-list: oldest first by default; "newest" reverses.
    @Published var newestFirst = false
    /// chapter-list range pager: one 50-chapter bucket, nil for all.
    @Published var range: Int?
    @Published var visibleCount = MangaDetailModel.pageSize

    nonisolated static let pageSize = 200

    init(mangaId: String) { self.mangaId = mangaId }

    private var pid: String { MangaStore.shared.pid }
    var ref: MangaRef { MangaRef(id: mangaId, title: detail?.title ?? "", cover: detail?.cover) }

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
    var langFiltered: [MangaChapter] { chapters.filter { ($0.language ?? "") == selectedLang } }
    var canRead: Bool { !langFiltered.isEmpty }

    /// chapter-list ascending: by chapter number, a chapter with none by its position.
    var ascending: [MangaChapter] {
        let list = langFiltered
        let nums = Dictionary(list.enumerated().map { ($0.element.id, $0.element.number(fallback: $0.offset)) }, uniquingKeysWith: { a, _ in a })
        var narrowed = list
        if showPager, let range { narrowed = list.filter { Self.bucket(nums[$0.id] ?? 0) == range } }
        return narrowed.sorted { (nums[$0.id] ?? 0) < (nums[$1.id] ?? 0) }
    }

    var ordered: [MangaChapter] { newestFirst ? Array(ascending.reversed()) : ascending }

    /// chapter-list bucketOf: 1-50, 51-100, ...
    static func bucket(_ n: Double) -> Int { Int(floor((ceil(n) - 1) / 50)) }

    /// chapter-list ranges, newest bucket first; shown past 60 chapters with more than one bucket.
    struct PageRange: Identifiable, Hashable { var b: Int; var lo: Int; var hi: Int; var id: Int { b } }
    var ranges: [PageRange] {
        let list = langFiltered
        var maxN = 0.0
        var buckets = Set<Int>()
        for (i, c) in list.enumerated() {
            let n = c.number(fallback: i)
            maxN = max(maxN, ceil(n))
            buckets.insert(Self.bucket(n))
        }
        return buckets.sorted(by: >).map { b in PageRange(b: b, lo: b * 50 + 1, hi: min(b * 50 + 50, Int(maxN))) }
    }
    var showPager: Bool { langFiltered.count > 60 && ranges.count > 1 }

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
        .task { await model.load() }
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
                Button { dismiss() } label: { Label("Back to browse", systemImage: "chevron.left") }
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
        out.append(n == 1 ? "1 chapter" : "\(n) chapters")
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
                    Text(model.detail?.title ?? "Untitled").font(BP.display(40)).foregroundStyle(BP.ink).lineLimit(2)
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
            if let p = model.progress {
                Button {
                    Task { if let l = await model.resumeLaunch(p) { reader = l } }
                } label: { Label(p.resumeLabel, systemImage: "arrow.counterclockwise") }
                    .buttonStyle(BPActionStyle())
            } else {
                Button {
                    let list = model.langFiltered
                    guard !list.isEmpty else { return }
                    reader = MangaReaderLaunch(manga: model.ref, chapters: list, index: 0, startPage: nil)
                } label: { Text("Start from beginning") }
                    .buttonStyle(BPActionStyle())
                    .disabled(!model.canRead)
            }
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
                                Button("\(MangaLanguage.name(l.code)) (\(l.count))") { model.selectedLang = l.code }
                                    .buttonStyle(BPActionStyle(primary: model.selectedLang == l.code))
                            }
                            Rectangle().fill(BP.edge2).frame(width: 1, height: BP.px(26))
                        }
                        Button(model.newestFirst ? "Newest first" : "Oldest first") { model.newestFirst.toggle() }
                            .buttonStyle(BPActionStyle())
                        if model.showPager {
                            Button("All") { model.range = nil }.buttonStyle(BPActionStyle(primary: model.range == nil))
                            ForEach(model.ranges) { r in
                                Button("\(r.lo)–\(r.hi)") { model.range = r.b }.buttonStyle(BPActionStyle(primary: model.range == r.b))
                            }
                        }
                    }
                    .padding(.vertical, BP.px(8))
                }
                .scrollClipDisabled()
                .focusSection()
            }
            if model.langFiltered.isEmpty {
                BPNote(text: model.pending ? "Loading chapters..." : "No chapters available in \(MangaLanguage.name(model.selectedLang)) from this source.")
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
                    }
                    if ordered.count > model.visibleCount {
                        Button("Show \(min(MangaDetailModel.pageSize, ordered.count - model.visibleCount)) more") { model.visibleCount += MangaDetailModel.pageSize }
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
                Text(c.title?.isEmpty == false ? c.title! : (c.chapter.map { "Chapter \($0)" } ?? "Oneshot"))
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
