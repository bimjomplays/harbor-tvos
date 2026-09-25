import SwiftUI

/// views/manga/manga-reader.tsx state without the DOM: the chapter's pages, the page in view,
/// reading order across chapters (one copy per chapter group), paging (use-reader-paging.ts),
/// progress and completion (use-reader-progress.ts) and the reader prefs.
@MainActor
final class MangaReaderModel: ObservableObject {
    let manga: MangaRef
    let chapters: [MangaChapter]
    @Published private(set) var index: Int
    @Published private(set) var pages: [MangaPage] = []
    @Published private(set) var loading = true
    @Published private(set) var failed = false
    /// The page in view. In the paged modes it can equal `total`: the chapter-complete card.
    @Published var currentPage = 0 { didSet { if oldValue != currentPage { pageChanged() } } }
    /// Long strip: the bottom of the chapter is on screen (use-reader-progress isCompleteNow).
    @Published var atEnd = false { didSet { if atEnd && !oldValue { noteProgress() } } }
    @Published private(set) var prefs = MangaReaderPrefs()
    /// reader-utils detectWebtoon: a tall strip reads as long whatever the chosen mode.
    @Published private(set) var autoLong = false
    /// Page aspect (height / width) once a page has loaded; 1.4 until then (measureAspect).
    @Published var aspects: [Int: Double] = [:]
    /// Long strip: the page to bring into view once laid out (resume), consumed by the view.
    @Published var pendingSeek: Int?
    /// Bumped on every page turn so the page counter can show for a moment.
    @Published private(set) var turn = 0

    private var order: [Int] = []
    private var keys: [String] = []
    private var didSeek = false
    private var settled = false
    private let requestedStart: Int?
    private var completedKey: String?
    private var completedState = false
    private var saveTask: Task<Void, Never>?
    private var pendingSave: (() async -> Void)?
    private var loadSeq = 0
    private var prefetchTask: Task<Void, Never>?
    let pid: String

    init(launch: MangaReaderLaunch) {
        manga = launch.manga
        chapters = launch.chapters
        index = max(0, min(launch.chapters.count - 1, launch.index))
        requestedStart = launch.startPage
        pid = MangaStore.shared.pid
    }

    var chapter: MangaChapter? { chapters.indices.contains(index) ? chapters[index] : nil }
    var total: Int { pages.count }
    /// long | paged | double (MangaReaderPrefs.tvMode), long while a webtoon strip is detected.
    var mode: String { autoLong ? "long" : prefs.tvMode }
    var paged: Bool { mode != "long" }
    var double: Bool { mode == "double" }
    var step: Int { double ? 2 : 1 }
    var lastStart: Int { double ? max(0, total - (total % 2 == 0 ? 2 : 1)) : max(0, total - 1) }
    var complete: Bool { paged && total > 0 && currentPage >= total }
    var rtl: Bool { prefs.rtl }

    // manga-reader.tsx reading order: the chapter's position among the collapsed chapters.
    private var orderPos: Int {
        guard chapters.indices.contains(index), keys.indices.contains(index) else { return order.firstIndex(of: index) ?? -1 }
        let key = keys[index]
        if let pos = order.firstIndex(where: { keys.indices.contains($0) && keys[$0] == key }) { return pos }
        return order.firstIndex(of: index) ?? -1
    }
    var prevIndex: Int? { let p = orderPos; return p > 0 ? order[p - 1] : nil }
    var nextIndex: Int? {
        let p = orderPos
        if p >= 0 && p < order.count - 1 { return order[p + 1] }
        if p == -1, let first = order.first { return first }
        return nil
    }
    var atLastChapter: Bool { let p = orderPos; return p == -1 || p == order.count - 1 }

    // MARK: loading

    func start() async {
        if let p: MangaReaderPrefs = try? await HarborEngine.shared.call("manga.prefs") { prefs = p }
        struct Order: Decodable { var order: [Int]; var keys: [String] }
        if let o: Order = try? await HarborEngine.shared.call("manga.readerOrder", [chapters, index]) {
            order = o.order
            keys = o.keys
        } else {
            order = Array(chapters.indices)
        }
        await load()
    }

    func reload() { Task { await load() } }

    private func load() async {
        guard let ch = chapter else { failed = true; loading = false; return }
        loadSeq += 1
        let seq = loadSeq
        flushSave()
        prefetchTask?.cancel()
        prefetchTask = nil
        loading = true
        failed = false
        settled = false
        pages = []
        aspects = [:]
        autoLong = false
        atEnd = false
        pendingSeek = nil
        currentPage = 0
        do {
            let list: [MangaPage] = try await HarborEngine.shared.call("manga.pages", [ch.id])
            guard seq == loadSeq else { return }
            guard !list.isEmpty else { failed = true; loading = false; return }
            // Only the chapter the reader opened on seeks (didSeek); later chapters start at the top.
            let firstLoad = !didSeek
            didSeek = true
            var resumeTo: Int?
            if firstLoad {
                let r: Int? = try? await HarborEngine.shared.call("manga.startPage", [pid, manga, ch, requestedStart])
                resumeTo = r
            }
            guard seq == loadSeq else { return }
            pages = list
            loading = false
            if let r = resumeTo {
                let sp = max(0, min(list.count - 1, r))
                if paged { currentPage = double ? sp - (sp % 2) : sp } else { currentPage = sp; pendingSeek = sp }
            }
            settled = true
            noteProgress()
            prefetch()
            Task {
                let tall = await MangaPageCache.shared.detectWebtoon(list)
                if seq == self.loadSeq, tall != self.autoLong {
                    self.autoLong = tall
                    if tall { self.pendingSeek = min(self.currentPage, max(0, self.total - 1)) }
                }
            }
        } catch {
            guard seq == loadSeq else { return }
            failed = true
            loading = false
        }
    }

    func changeIndex(_ i: Int) {
        guard chapters.indices.contains(i), i != index || failed else { return }
        index = i
        // (bug pass 3) Loading from this moment: until load() ran, the old chapter's pages were still
        // up, so a second quick Right / Down at the end marked the new chapter complete (with the old
        // page count) and skipped straight past it.
        loading = true
        Task { await load() }
    }

    /// The page width the long strip and prefetch decode for (reader-prefs longStyle, 880 × zoom).
    var longWidth: CGFloat { min(1920, 880 * CGFloat(prefs.zoom)) }

    private static let screen = CGSize(width: 1920, height: 1080)
    private static let defaultAspect = 1.4

    /// reader-prefs pageStyle / doublePageStyle at a 1920 × 1080 screen: the size a paged page is
    /// drawn at. The view and the prefetch both use it, so a warmed page is the decode the view asks for.
    func pageSize(_ i: Int, double: Bool) -> CGSize {
        let z = CGFloat(prefs.zoom)
        let a = CGFloat(aspects[i] ?? Self.defaultAspect)
        let W = double ? Self.screen.width / 2 : Self.screen.width
        switch prefs.fit {
        case "height":
            var h = Self.screen.height * (double ? 0.92 : 0.94) * z
            var w = h / a
            if w > W && z <= 1 { w = W; h = w * a }
            return CGSize(width: w, height: h)
        case "original":
            let w = W * z
            return CGSize(width: w, height: w * a)
        default:
            let w = min(W * max(1, z), (double ? 440 : 880) * z)
            return CGSize(width: w, height: w * a)
        }
    }

    /// (bug pass 3) Warm the next few pages (paged: the next spread or two; long: just below the
    /// fold) at the width each is drawn at. The prefetch used to decode paged pages for a full
    /// 1920-wide screen (2400 px, ~32 MB each at the 8 MP cap) while the view asked for 880 × 1.5:
    /// a different cache key, so every warmed page was decoded twice and the unused copies filled
    /// the page cache. A newer turn, a chapter change or closing the reader cancels the warm-up.
    func prefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        guard total > 0 else { return }
        let from = min(total, currentPage + 1)
        let to = min(total, from + (double ? 4 : 3))
        guard from < to else { return }
        let jobs: [(page: MangaPage, width: CGFloat)] = (from..<to).map { i in
            (pages[i], paged ? pageSize(i, double: double).width : longWidth)
        }
        prefetchTask = Task.detached(priority: .utility) { await MangaPageCache.shared.prefetch(jobs) }
    }

    // MARK: paging (use-reader-paging.ts, paged modes)

    func next() {
        guard !loading, !failed, total > 0 else { return }
        if currentPage >= total {
            if let n = nextIndex { changeIndex(n) }
        } else if currentPage >= lastStart {
            endReached()
            if prefs.autoNextChapter, let n = nextIndex { changeIndex(n) } else { currentPage = total }
        } else {
            currentPage += step
        }
    }

    func prev() {
        guard !loading, !failed, total > 0 else { return }
        if currentPage <= 0 {
            if let p = prevIndex { changeIndex(p) }
        } else if currentPage >= total {
            currentPage = lastStart
        } else {
            currentPage = max(0, currentPage - step)
        }
    }

    /// Long strip past its end, or Next chapter on the complete card.
    func nextChapter() { if let n = nextIndex { changeIndex(n) } }
    func previousChapter() { if let p = prevIndex { changeIndex(p) } }

    // MARK: progress (use-reader-progress.ts)

    private func pageChanged() {
        turn += 1
        prefetch()
        noteProgress()
    }

    private func isCompleteNow() -> Bool {
        guard !loading, !failed, total > 0 else { return false }
        if paged { return currentPage >= total }
        return currentPage >= total - 1 && atEnd
    }

    /// fireCompleted: the chapter counts as finished once, the moment it becomes complete.
    @discardableResult private func fireCompleted() -> Bool {
        guard let ch = chapter else { return false }
        let key = "\(manga.id)|\(ch.id)"
        if completedKey != key { completedKey = key; completedState = false }
        let done = isCompleteNow()
        let was = completedState
        completedState = done
        if done && !was { markComplete() }
        return done && !was
    }

    /// use-reader-paging onEndReached: the last spread was turned.
    private func endReached() {
        guard let ch = chapter else { return }
        let key = "\(manga.id)|\(ch.id)"
        if completedKey != key { completedKey = key; completedState = false }
        if !completedState { completedState = true; markComplete() }
    }

    private func markComplete() {
        let args: [any Encodable] = [pid, manga, chapters, index, nextIndex, total]
        pendingSave = nil
        saveTask?.cancel()
        Task { let _: Bool? = try? await HarborEngine.shared.call("manga.markComplete", args) }
    }

    /// The 700 ms debounced save of the page in view (skipped once the chapter completed).
    func noteProgress() {
        guard settled, !loading, !failed, total > 0, let ch = chapter, !manga.title.isEmpty else { return }
        fireCompleted()
        let key = "\(manga.id)|\(ch.id)"
        if completedKey == key && completedState { return }
        let page = min(currentPage + 1, total)
        let args: [any Encodable] = [pid, manga, ch, page, total, Optional<Double>.none]
        let save: () async -> Void = { let _: Bool? = try? await HarborEngine.shared.call("manga.recordPage", args) }
        pendingSave = save
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.pendingSave = nil
            await save()
        }
    }

    /// A save still waiting on its debounce is written now (chapter change, reader closed).
    private func flushSave() {
        saveTask?.cancel()
        if let save = pendingSave {
            pendingSave = nil
            Task { await save() }
        }
    }

    func close() {
        flushSave()
        prefetchTask?.cancel()
        prefetchTask = nil
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            let _: Bool? = try? await HarborEngine.shared.call("manga.closeReader")
            await MangaPageCache.shared.purge()
            await MangaStore.shared.refreshLists()
        }
    }

    // MARK: prefs (manga-reader patchPrefs / zoomBy)

    func patch(_ change: [String: AnyJSON]) {
        Task {
            if let p: MangaReaderPrefs = try? await HarborEngine.shared.call("manga.savePrefs", [AnyJSON.object(change)]) {
                let wasPaged = paged
                prefs = p
                if wasPaged != paged, total > 0 {
                    let at = min(currentPage, total - 1)
                    if paged { currentPage = double ? at - (at % 2) : at } else { pendingSeek = at }
                } else if double, currentPage < total, currentPage % 2 == 1 {
                    currentPage -= 1
                }
            }
        }
    }

    func zoomBy(_ delta: Double) {
        patch(["zoom": .number(((prefs.zoom + delta) * 100).rounded() / 100)])
    }
}
