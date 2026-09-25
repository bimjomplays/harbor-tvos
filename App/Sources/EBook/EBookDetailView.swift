import SwiftUI

/// What the reader opens on: the book, its parsed EPUB, the chapters (upstream ids) and where.
struct EBookReaderLaunch: Identifiable {
    let id = UUID()
    var book: EBook
    var epub: EPUBBook
    var chapters: [EBookChapter]
    /// The EPUB path each chapter reads (parallel to `chapters`).
    var paths: [String]
    var index: Int
}

/// views/ebook.tsx EBookDetails state: the book (cached copy first, then the provider's or the
/// metadata catalog's detail), the source copies it can be read from, the chosen source's
/// chapters, and the shelf / favourite flags.
@MainActor
final class EBookDetailModel: ObservableObject {
    @Published private(set) var ebook: EBook?
    @Published private(set) var loadFailed = false
    @Published private(set) var sourceOptions: [EBook] = []
    @Published var sourceRoute: String? { didSet { if sourceRoute != oldValue { loadChapters() } } }
    @Published private(set) var resolvingSource = false
    /// nil while loading.
    @Published private(set) var chapters: [EBookChapter]?
    @Published private(set) var chapterNote: String?
    @Published private(set) var onShelf = false
    @Published private(set) var favorite = false
    @Published private(set) var resume: EBookResume?
    @Published private(set) var authorBooks: [EBook] = []
    @Published private(set) var recommendations: [EBook] = []
    @Published private(set) var recommendationsFailed = false

    private(set) var epub: EPUBBook?
    private(set) var paths: [String] = []
    private var chapterSeq = 0
    let id: String
    let candidates: [EBook]
    var pid: String { EBookStore.shared.pid }

    init(id: String, candidates: [EBook]) {
        self.id = id
        self.candidates = candidates
    }

    private var started = false

    func load() async {
        // (bug pass) Once per page: `.task` runs again whenever the reader or a nested detail cover
        // closes, which re-fetched the detail, re-resolved the sources and reloaded both rails over
        // the network after every read. The reader's onDismiss already refreshes the flags and the
        // resume.
        guard !started else { return }
        started = true
        // views/ebook.tsx: the list's copy shows at once while the detail loads.
        let cached = candidates.first { $0.id == id || ($0.books ?? []).contains { $0.id == id } }
            ?? (EBookStore.shared.favorites + EBookStore.shared.shelf).first { $0.id == id }
        if let cached { ebook = cached }
        if let d: EBook = try? await HarborEngine.shared.call("ebook.detail", [id]) {
            if var current = ebook, let books = current.books, !books.isEmpty {
                // Keep the grouped copies; swap in the detail for its own entry.
                current.books = books.map { $0.id == d.id ? d : $0 }
                ebook = current.id == d.id ? mergedDetail(d, books: current.books) : current
            } else {
                ebook = d
            }
        }
        guard let book = ebook else { loadFailed = true; return }
        await refreshFlags()
        await resolveSources(book)
        async let more: [EBook] = (try? await HarborEngine.shared.call("ebook.moreByAuthor", [book])) ?? []
        struct Rec: Decodable { var items: [EBook]; var failed: Bool }
        async let rec: Rec? = try? await HarborEngine.shared.call("ebook.recommended", [book])
        authorBooks = await more
        let r = await rec
        recommendations = r?.items ?? []
        recommendationsFailed = r?.failed ?? true
    }

    private func mergedDetail(_ d: EBook, books: [EBook]?) -> EBook {
        var out = d
        out.books = books
        return out
    }

    func retryRecommendations() async {
        guard let book = ebook else { return }
        struct Rec: Decodable { var items: [EBook]; var failed: Bool }
        let r: Rec? = try? await HarborEngine.shared.call("ebook.recommended", [book])
        recommendations = r?.items ?? []
        recommendationsFailed = r?.failed ?? true
    }

    func refreshFlags() async {
        struct Flags: Decodable { var shelf: Bool; var favorite: Bool }
        if let f: Flags = try? await HarborEngine.shared.call("ebook.flags", [id]) {
            onShelf = f.shelf
            favorite = f.favorite
        }
        resume = try? await HarborEngine.shared.call("ebook.resume", [pid, ebook?.id ?? id])
    }

    /// EBookDetails source resolution; the first matching copy is read unless one was chosen.
    private func resolveSources(_ book: EBook) async {
        let existing = book.sourceBooks
        sourceOptions = existing
        resolvingSource = existing.isEmpty
        if sourceRoute == nil, let first = existing.first { sourceRoute = first.id }
        let found: [EBook] = (try? await HarborEngine.shared.call("ebook.resolveSources", [book, candidates])) ?? existing
        sourceOptions = found
        if let current = sourceRoute, found.contains(where: { $0.id == current }) {
            // keep it
        } else {
            sourceRoute = found.first?.id
        }
        resolvingSource = false
        if sourceRoute == nil { chapters = nil }
    }

    /// The chosen source's chapters. On the TV only Gutendex copies open: the EPUB is fetched and
    /// parsed natively, and the engine names the chapters as gutendexProvider.chapters does.
    private func loadChapters() {
        chapterSeq += 1
        let seq = chapterSeq
        chapters = nil
        chapterNote = nil
        epub = nil
        paths = []
        guard let route = sourceRoute else { return }
        Task {
            struct Where: Decodable { var bookId: String; var url: String }
            guard let at: Where = try? await HarborEngine.shared.call("ebook.epub", [route]) else {
                guard seq == chapterSeq else { return }
                chapters = []
                chapterNote = "This source can't be read on Apple TV yet. Project Gutenberg books can."
                return
            }
            do {
                let book = try await EPUBLibrary.shared.book(key: route, url: at.url)
                guard seq == chapterSeq else { return }
                struct Entry: Encodable { var path: String; var title: String }
                let list = book.chapters.map { Entry(path: $0.path, title: $0.title) }
                let named: [EBookChapter] = (try? await HarborEngine.shared.call("ebook.chapters", [at.bookId, list])) ?? []
                guard seq == chapterSeq else { return }
                epub = book
                paths = book.chapters.map(\.path)
                chapters = named.count == paths.count ? named : []
                if chapters?.isEmpty == true { chapterNote = "This source returned no chapters for this title." }
            } catch {
                guard seq == chapterSeq else { return }
                chapters = []
                chapterNote = "This chapter could not be loaded."
            }
        }
    }

    /// The reader launch for a chapter (EBookDetails readChapter).
    func launch(_ chapter: EBookChapter) -> EBookReaderLaunch? {
        guard let book = ebook, let epub = epub, let list = chapters, let i = list.firstIndex(where: { $0.id == chapter.id }) else { return nil }
        return EBookReaderLaunch(book: book, epub: epub, chapters: list, paths: paths, index: i)
    }

    /// EBookDetails autoRead: the resume's chapter, else the first by position.
    func resumeLaunch() -> EBookReaderLaunch? {
        guard let list = chapters, !list.isEmpty else { return nil }
        let target = list.first { $0.id == resume?.chapterId }
            ?? list.min { ($0.position ?? .greatestFiniteMagnitude) < ($1.position ?? .greatestFiniteMagnitude) }
        return target.flatMap(launch)
    }

    func toggleShelf() async {
        guard let book = ebook else { return }
        onShelf = await EBookStore.shared.toggleShelf(book)
    }

    func toggleFavorite() async {
        guard let book = ebook else { return }
        favorite = await EBookStore.shared.toggleFavorite(book)
    }
}

/// The eBook detail page (views/ebook.tsx EBookDetails) for the remote: cover, title, authors,
/// facts and genres; Start / Continue Reading, Bookmark (the shelf), favourite and the source
/// picker; the description; the chapters; More by the author and Recommended eBooks.
@MainActor
struct EBookDetailView: View {
    @StateObject private var model: EBookDetailModel
    @State private var reader: EBookReaderLaunch?
    @State private var descriptionExpanded = false
    @State private var sourcePicker = false
    @State private var nested: EBookOpen?
    @State private var autoRead: Bool
    @Environment(\.dismiss) private var dismiss

    init(open: EBookOpen, candidates: [EBook] = []) {
        _model = StateObject(wrappedValue: EBookDetailModel(id: open.id, candidates: candidates))
        _autoRead = State(initialValue: open.autoRead)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            if let book = model.ebook {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: BP.px(34)) {
                        header(book)
                        chapterSection
                        if !model.authorBooks.isEmpty, let author = book.authors.first {
                            rail("ebook-author", T("More by %@", author), "Other titles from the same author", model.authorBooks)
                        }
                        if model.recommendationsFailed {
                            VStack(alignment: .leading, spacing: BP.px(8)) {
                                Text("Recommended eBooks").font(BP.sans(18, .semibold)).foregroundStyle(BP.ink)
                                BPNote(text: "Recommendations are temporarily unavailable.")
                                Button("Retry") { Task { await model.retryRecommendations() } }.buttonStyle(BPActionStyle())
                            }
                            .padding(.horizontal, BP.gutter)
                            .focusSection()
                        } else if !model.recommendations.isEmpty {
                            rail("ebook-recommended", "Recommended eBooks", "Same-genre picks from your installed sources", model.recommendations)
                        }
                        Color.clear.frame(height: BP.px(60))
                    }
                    .padding(.top, BP.px(70))
                }
            } else if model.loadFailed {
                VStack(alignment: .leading, spacing: BP.px(14)) {
                    Text("This eBook could not be loaded.").font(BP.sans(19, .semibold)).foregroundStyle(BP.ink)
                    Button("Back") { dismiss() }.buttonStyle(BPActionStyle())
                }
                .padding(BP.gutter).padding(.top, BP.px(120))
            } else {
                VStack(spacing: BP.px(12)) {
                    ProgressView().tint(BP.inkMuted)
                    Text("Loading eBook…").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .task { await model.load() }
        .onChange(of: model.chapters) { _, list in
            // EBookDetails autoRead (Continue your bookmarks): straight into the reader once
            // the chapters are known; the intent is used up either way.
            guard autoRead, let list else { return }
            autoRead = false
            if !list.isEmpty, let l = model.resumeLaunch() { reader = l }
        }
        .fullScreenCover(item: $reader, onDismiss: { Task { await model.refreshFlags(); await EBookStore.shared.refreshLists() } }) { l in
            EBookReaderView(launch: l) { reader = nil }
        }
        .fullScreenCover(item: $nested) { o in EBookDetailView(open: o) }
        .confirmationDialog("Source", isPresented: $sourcePicker) {
            ForEach(model.sourceOptions) { s in
                Button(s.providerName ?? s.title) { model.sourceRoute = s.id }
            }
        }
    }

    private var backdrop: some View {
        ZStack {
            BP.void_
            if let art = model.ebook?.banner ?? model.ebook?.cover {
                RemoteImage(url: art).blur(radius: model.ebook?.banner == nil ? 28 : 0).scaleEffect(1.18).opacity(0.45)
                    .frame(maxWidth: .infinity).frame(height: BP.px(560)).clipped()
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            LinearGradient(colors: [BP.void_.opacity(0.3), BP.void_.opacity(0.85), BP.void_], startPoint: .top, endPoint: .init(x: 0.5, y: 0.6))
        }
        .ignoresSafeArea()
    }

    private func header(_ book: EBook) -> some View {
        HStack(alignment: .top, spacing: BP.px(28)) {
            ZStack(alignment: .topTrailing) {
                RemoteImage(url: book.cover)
                    .frame(width: BP.px(208), height: BP.px(312))
                    .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
                    .shadow(color: .black.opacity(0.6), radius: 24, y: 14)
                if let status = readStatus { EBookReadMark(status: status).padding(BP.px(8)) }
            }
            VStack(alignment: .leading, spacing: BP.px(12)) {
                VStack(alignment: .leading, spacing: BP.px(6)) {
                    Text(book.title).font(BP.display(40)).foregroundStyle(BP.ink).lineLimit(3)
                    if let alt = book.altTitle, alt != book.title {
                        Text(alt.replacingOccurrences(of: "|", with: " · ")).font(BP.sans(15)).foregroundStyle(BP.inkMuted).lineLimit(1)
                    }
                    if !book.authors.isEmpty {
                        Text(T("by %@", book.authors.joined(separator: ", "))).font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                    }
                }
                let facts = factList(book)
                if !facts.isEmpty || !book.genres.isEmpty {
                    HStack(spacing: BP.px(8)) {
                        ForEach(facts + Array(book.genres.prefix(4)), id: \.self) { f in
                            Text(f).font(BP.sans(12)).foregroundStyle(BP.inkMuted).lineLimit(1)
                                .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(4))
                                .background(Capsule().fill(BP.panel2))
                        }
                    }
                }
                actions(book)
                if !book.description.isEmpty || model.ebook != nil {
                    Button { descriptionExpanded.toggle() } label: {
                        Text(book.description.isEmpty ? T("No description is available for this eBook.") : book.description)
                            .font(BP.sans(15)).foregroundStyle(BP.inkMuted).lineLimit(descriptionExpanded ? nil : 4)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: BP.px(760), alignment: .leading)
                            .padding(BP.px(8))
                    }
                    .buttonStyle(BPTileStyle(radius: BP.rSM))
                    .disabled(book.description.isEmpty)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BP.gutter)
        .focusSection()
    }

    private func factList(_ book: EBook) -> [String] {
        var out: [String] = []
        if let y = book.year { out.append(String(Int(y))) }
        if let s = book.status, !s.isEmpty { out.append(s.prefix(1).uppercased() + s.dropFirst().lowercased()) }
        if let v = book.volumes, v > 0 { out.append(T("%lld volumes", Int(v))) }
        if let c = model.chapters?.count, c > 0 { out.append(T("%lld chapters", c)) } else if let c = book.chapters, c > 0 { out.append(T("%lld chapters", Int(c))) }
        return out
    }

    /// useEBookReadStatus from the resume the detail holds.
    private var readStatus: String? {
        guard let r = model.resume else { return nil }
        if let i = r.chapterIndex, let t = r.totalChapters, i == t - 1, (r.chapterProgress ?? 0) >= 100 { return "read" }
        return (r.chapterProgress ?? 0) > 0 || (r.bookProgress ?? 0) > 0 ? "partial" : nil
    }

    private func actions(_ book: EBook) -> some View {
        HStack(spacing: BP.px(10)) {
            // ebook-wheel-menu "Start Reading" / "Continue Reading".
            let ready = model.chapters?.isEmpty == false
            Button {
                if let l = model.resumeLaunch() { reader = l }
            } label: {
                Label(model.resume != nil ? "Continue Reading" : "Start Reading", systemImage: "book.fill")
            }
            // (device-flow pass) Dimmed, not disabled, while the chapters load: a disabled first button
            // sent the page's first focus to Bookmark, so an early Select put the book on the shelf.
            .buttonStyle(BPActionStyle(primary: true, busy: !ready))
            Button { Task { await model.toggleShelf() } } label: {
                Label(model.onShelf ? "Bookmarked" : "Bookmark", systemImage: model.onShelf ? "books.vertical.fill" : "bookmark")
            }
            .buttonStyle(BPActionStyle())
            Button { Task { await model.toggleFavorite() } } label: {
                Image(systemName: model.favorite ? "heart.fill" : "heart")
                    .foregroundStyle(model.favorite ? BP.accent : BP.ink)
            }
            .buttonStyle(BPActionStyle())
            .accessibilityLabel(model.favorite ? "Remove favorite" : "Add favorite")
            if model.sourceOptions.count > 1, let route = model.sourceRoute {
                let name = model.sourceOptions.first { $0.id == route }?.providerName ?? T("Source")
                Button { sourcePicker = true } label: { Label(name, systemImage: "books.vertical") }
                    .buttonStyle(BPActionStyle())
            }
        }
    }

    // MARK: chapters

    @ViewBuilder private var chapterSection: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Text("Chapters").font(BP.sans(22, .semibold)).foregroundStyle(BP.ink)
            if model.resolvingSource || (model.sourceRoute != nil && model.chapters == nil) {
                HStack(spacing: BP.px(10)) {
                    ProgressView().tint(BP.inkMuted)
                    Text(model.resolvingSource ? "Looking for this book in your sources…" : "Loading chapters...").font(BP.sans(15)).foregroundStyle(BP.inkMuted)
                }
            } else if model.sourceRoute == nil {
                BPNote(text: "Not available in your sources yet")
            } else if let note = model.chapterNote {
                BPNote(text: note)
            } else if let list = model.chapters {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: BP.px(12)) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, ch in
                            Button {
                                if let l = model.launch(ch) { reader = l }
                            } label: { chapterCard(ch, index: i) }
                            .buttonStyle(BPTileStyle(radius: BP.rSM))
                        }
                    }
                    .padding(.vertical, BP.px(12))
                }
                .scrollClipDisabled()
            }
        }
        .padding(.horizontal, BP.gutter)
        .focusSection()
    }

    private func chapterCard(_ ch: EBookChapter, index: Int) -> some View {
        let reading = model.resume?.chapterId == ch.id
        return VStack(alignment: .leading, spacing: BP.px(6)) {
            Text(ch.chapter.map { T("Ch. %@", $0) } ?? T("Position %@", String(index + 1)))
                .font(BP.sans(11, .bold)).textCase(.uppercase).tracking(1).foregroundStyle(reading ? BP.accent : BP.inkSubtle)
            Text(ch.title.isEmpty ? T("Chapter") : ch.title).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
            if reading, let p = model.resume?.chapterProgress {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(BP.edge2)
                        Capsule().fill(BP.accent).frame(width: g.size.width * max(0, min(1, p / 100)))
                    }
                }
                .frame(height: BP.px(3))
            }
        }
        .padding(BP.px(12))
        .frame(width: BP.px(220), height: BP.px(120), alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(reading ? BP.panel2 : BP.panel))
    }

    private func rail(_ key: String, _ title: String, _ subtitle: String, _ books: [EBook]) -> some View {
        VStack(alignment: .leading, spacing: BP.px(2)) {
            BPRowView(row: BrowseRow(key: key, title: T(title), metas: books.map(\.meta)),
                      onFocus: { _ in },
                      onSelect: { m in nested = EBookOpen(id: m.id) })
            Text(T(subtitle)).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).padding(.horizontal, BP.gutter)
        }
    }
}
