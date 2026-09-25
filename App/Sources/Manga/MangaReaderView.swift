import SwiftUI

/// The TV manga reader (views/manga/manga-reader.tsx). The remote replaces the mouse and keys:
/// - Left / Right turn pages; in the paged modes they follow the reading direction (right to left
///   by default, as upstream's arrow keys do). A zoomed page pans first and turns at its edge.
/// - Up / Down scroll the long strip (webtoon mode) by most of a screen, and pan a page that is
///   taller than the screen. Past the end of a strip, Down opens the next chapter.
/// - Play/Pause steps the zoom (1×, 1.5×, 2×); Select opens the reader bar (chapters, reading
///   mode, direction, fit, zoom, background, auto next chapter); Back closes the bar, then the reader.
@MainActor
struct MangaReaderView: View {
    @StateObject private var model: MangaReaderModel
    let onExit: () -> Void

    @State private var menuOpen = false
    @State private var scrollY: CGFloat = 0
    @State private var panX: CGFloat = 0
    @State private var panY: CGFloat = 0
    @State private var counterVisible = true
    @FocusState private var focus: Focus?
    private enum Focus: Hashable { case surface, bar(String) }

    private static let screen = CGSize(width: 1920, height: 1080)
    private static let endCardHeight: CGFloat = 420
    private static let defaultAspect = 1.4

    init(launch: MangaReaderLaunch, onExit: @escaping () -> Void) {
        _model = StateObject(wrappedValue: MangaReaderModel(launch: launch))
        self.onExit = onExit
    }

    var body: some View {
        ZStack {
            model.prefs.background.ignoresSafeArea()
            if model.loading {
                ProgressView().tint(BP.inkMuted)
            } else if model.failed {
                failedCard
            } else if model.paged {
                pagedStage
            } else {
                longStage
            }
            // The invisible surface holds focus while the bar is down so remote presses reach us.
            Button { openMenu() } label: { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .disabled(menuOpen || model.failed)
                .focused($focus, equals: .surface)
                .onMoveCommand(perform: move)
                // The page is the only focus stop: VoiceOver names the book instead of an empty button.
                .accessibilityLabel(Text(verbatim: model.manga.title))
            if counterVisible || menuOpen, !model.loading, !model.failed, model.total > 0 { pageCounter }
            if menuOpen { readerBar.transition(.opacity) }
        }
        .ignoresSafeArea()
        .onPlayPauseCommand { cycleZoom() }
        .onExitCommand {
            if menuOpen { closeMenu() } else { closeReader() }
        }
        .task {
            focus = .surface
            await model.start()
        }
        .onChange(of: model.turn) { _, _ in showCounter() }
        .onChange(of: model.currentPage) { _, _ in resetPan() }
        .onChange(of: model.prefs) { old, new in
            resetPan()
            // A new zoom re-lays the strip out: keep the page being read at the top.
            if !model.paged, old.zoom != new.zoom { scrollY = min(maxScroll, tops[safe: model.currentPage] ?? 0); syncLongPage() }
        }
        .onChange(of: model.index) { _, _ in scrollY = 0; resetPan() }
        .onChange(of: model.pendingSeek) { _, sp in
            guard let sp, !model.paged else { return }
            scrollY = min(maxScroll, tops[safe: sp] ?? 0)
            model.pendingSeek = nil
            syncLongPage()
        }
        .animation(BP.easeFast, value: menuOpen)
    }

    // MARK: remote

    private func move(_ dir: MoveCommandDirection) {
        guard !model.loading, !model.failed else { return }
        if model.paged { movePaged(dir) } else { moveLong(dir) }
    }

    private func movePaged(_ dir: MoveCommandDirection) {
        let size = pagedContentSize
        let maxX = max(0, size.width - Self.screen.width)
        let maxY = max(0, size.height - Self.screen.height)
        let stepX = Self.screen.width * 0.6
        let stepY = Self.screen.height * 0.6
        switch dir {
        case .down:
            if panY < maxY - 1 { withAnimation(.easeOut(duration: 0.22)) { panY = min(maxY, panY + stepY) } }
            else { model.next() }
        case .up:
            if panY > 1 { withAnimation(.easeOut(duration: 0.22)) { panY = max(0, panY - stepY) } }
        case .right:
            if maxX > 0, panX < maxX - 1 { withAnimation(.easeOut(duration: 0.22)) { panX = min(maxX, panX + stepX) } }
            else if model.rtl { model.prev() } else { model.next() }
        case .left:
            if maxX > 0, panX > 1 { withAnimation(.easeOut(duration: 0.22)) { panX = max(0, panX - stepX) } }
            else if model.rtl { model.next() } else { model.prev() }
        @unknown default: break
        }
    }

    private func moveLong(_ dir: MoveCommandDirection) {
        let stepY = Self.screen.height * 0.75
        let cur = model.currentPage
        switch dir {
        case .down:
            if scrollY < maxScroll - 1 { scroll(to: scrollY + stepY) } else { model.nextChapter() }
        case .up:
            scroll(to: scrollY - stepY)
        case .right:
            // use-reader-paging nextPage in the long strip: the next page's top, then the end.
            if scrollY >= maxScroll - 1 { model.nextChapter() }
            else if cur < model.total - 1, let t = tops[safe: cur + 1] { scroll(to: t) }
            else { scroll(to: maxScroll) }
        case .left:
            if cur > 0, let t = tops[safe: cur - 1] { scroll(to: t) } else { scroll(to: 0) }
        @unknown default: break
        }
    }

    private func scroll(to y: CGFloat) {
        withAnimation(.easeOut(duration: 0.25)) { scrollY = max(0, min(maxScroll, y)) }
        syncLongPage()
    }

    /// The page crossing the middle of the screen is the one being read; the strip's end is
    /// reached once the last pixel is on screen.
    private func syncLongPage() {
        guard model.total > 0 else { return }
        let mid = scrollY + Self.screen.height / 2
        var page = 0
        for (i, t) in tops.enumerated() where t <= mid { page = i }
        let end = scrollY >= maxScroll - 2
        if model.currentPage != page { model.currentPage = page }
        if model.atEnd != end { model.atEnd = end }
    }

    private func resetPan() {
        panY = 0
        let maxX = max(0, pagedContentSize.width - Self.screen.width)
        // Right-to-left pages start reading at their right edge.
        panX = model.rtl ? maxX : 0
    }

    private func cycleZoom() {
        let steps = [1.0, 1.5, 2.0]
        let z = model.prefs.zoom
        let nextZoom = steps.first(where: { $0 > z + 0.01 }) ?? steps[0]
        model.zoomBy(nextZoom - z)
        showCounter()
    }

    private func openMenu() {
        menuOpen = true
        DispatchQueue.main.async { focus = .bar(model.nextIndex != nil ? "next" : "mode") }
    }

    private func closeMenu() {
        menuOpen = false
        DispatchQueue.main.async { focus = .surface }
    }

    private func closeReader() {
        model.close()
        onExit()
    }

    @State private var counterTask: Task<Void, Never>?
    private func showCounter() {
        counterVisible = true
        counterTask?.cancel()
        counterTask = Task {
            try? await Task.sleep(for: .milliseconds(2600))
            guard !Task.isCancelled else { return }
            withAnimation(BP.easeFast) { counterVisible = false }
        }
    }

    // MARK: paged / double

    private func aspect(_ i: Int) -> CGFloat { CGFloat(model.aspects[i] ?? Self.defaultAspect) }

    /// reader-prefs pageStyle / doublePageStyle at a 1920 × 1080 screen (the model's, which the
    /// prefetch decodes for too).
    private func pageSize(_ i: Int, double: Bool) -> CGSize { model.pageSize(i, double: double) }

    private var spread: [Int] {
        guard !model.complete else { return [] }
        let p = min(model.currentPage, max(0, model.total - 1))
        let list = model.double ? [p, p + 1].filter { $0 < model.total } : [p]
        return model.rtl && model.double ? list.reversed() : list
    }

    private var pagedContentSize: CGSize {
        let sizes = spread.map { pageSize($0, double: model.double) }
        let gap: CGFloat = sizes.count > 1 ? 8 : 0
        return CGSize(width: sizes.reduce(0) { $0 + $1.width } + gap, height: sizes.map(\.height).max() ?? 0)
    }

    private var pagedStage: some View {
        let size = pagedContentSize
        let ox = size.width <= Self.screen.width ? (Self.screen.width - size.width) / 2 : -panX
        let oy = size.height <= Self.screen.height ? (Self.screen.height - size.height) / 2 : -panY
        return ZStack(alignment: .topLeading) {
            if model.complete {
                completeCard.frame(width: Self.screen.width, height: Self.screen.height)
            } else {
                HStack(alignment: .center, spacing: 8) {
                    ForEach(spread, id: \.self) { i in
                        let s = pageSize(i, double: model.double)
                        MangaPageImage(page: model.pages[i], width: s.width) { a in
                            if model.aspects[i] != a { model.aspects[i] = a }
                        }
                        .frame(width: s.width, height: s.height)
                    }
                }
                .frame(width: size.width, height: size.height)
                .offset(x: ox, y: oy)
            }
        }
        .frame(width: Self.screen.width, height: Self.screen.height, alignment: .topLeading)
        .clipped()
    }

    // MARK: long strip

    private var longWidth: CGFloat { model.longWidth }

    private var heights: [CGFloat] { (0..<model.total).map { longWidth * aspect($0) } }

    private var tops: [CGFloat] {
        var out: [CGFloat] = []
        var y: CGFloat = 0
        for h in heights { out.append(y); y += h }
        return out
    }

    private var stripHeight: CGFloat { heights.reduce(0, +) }
    private var maxScroll: CGFloat { max(0, stripHeight + Self.endCardHeight - Self.screen.height) }

    /// Only the pages near the viewport exist (and hold decoded images); the rest are arithmetic.
    private var visiblePages: [Int] {
        let t = tops, h = heights
        let lo = scrollY - Self.screen.height, hi = scrollY + Self.screen.height * 2
        return (0..<model.total).filter { t[$0] < hi && t[$0] + h[$0] > lo }
    }

    private var longStage: some View {
        let t = tops, h = heights
        return ZStack(alignment: .top) {
            ForEach(visiblePages, id: \.self) { i in
                MangaPageImage(page: model.pages[i], width: longWidth) { a in longAspect(i, a) }
                    .frame(width: longWidth, height: h[i])
                    .offset(y: t[i] - scrollY)
            }
            completeCard
                .frame(width: Self.screen.width, height: Self.endCardHeight)
                .offset(y: stripHeight - scrollY)
        }
        .frame(width: Self.screen.width, height: Self.screen.height, alignment: .top)
        .clipped()
    }

    /// A page above the one being read changed height: keep the reading position still.
    private func longAspect(_ i: Int, _ a: Double) {
        let old = longWidth * aspect(i)
        guard model.aspects[i] != a else { return }
        model.aspects[i] = a
        let delta = longWidth * CGFloat(a) - old
        if i < model.currentPage { scrollY = max(0, min(maxScroll, scrollY + delta)) }
        syncLongPage()
    }

    // MARK: cards and bar

    /// reader-states ReaderComplete, told for the remote.
    private var completeCard: some View {
        VStack(spacing: BP.px(10)) {
            Text(model.atLastChapter ? "All caught up" : "Chapter complete")
                .font(BP.sans(13, .bold)).textCase(.uppercase).tracking(1.4).foregroundStyle(BP.accent)
            if model.atLastChapter {
                Text("You have reached the latest chapter available.").font(BP.sans(17, .semibold)).foregroundStyle(BP.ink)
                Text("Back to details").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
            } else if let n = model.nextIndex {
                Text(model.chapters[n].label).font(BP.display(26)).foregroundStyle(BP.ink)
                Text(model.paged ? "Press \(model.rtl ? "◀" : "▶") for the next chapter" : "Press ▼ for the next chapter")
                    .font(BP.sans(14)).foregroundStyle(BP.inkMuted)
            }
        }
        .padding(.horizontal, BP.px(28)).padding(.vertical, BP.px(22))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
    }

    private var failedCard: some View {
        VStack(spacing: BP.px(12)) {
            Text("This chapter could not be loaded from this source.").font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
            BPNote(text: "The source did not return any pages. Try again, or go back and pick another chapter.")
            HStack(spacing: BP.px(10)) {
                Button("Retry") { model.reload() }.buttonStyle(BPActionStyle(primary: true))
                Button("Back") { closeReader() }.buttonStyle(BPActionStyle())
            }
        }
        .padding(BP.px(28))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
        .zIndex(2)
    }

    /// reader-progress-meter: "p / N" in the corner for a moment after each turn.
    private var pageCounter: some View {
        let shown = model.complete ? model.total : min(model.currentPage + 1, model.total)
        return HStack(spacing: BP.px(8)) {
            Text(model.chapter?.label ?? "").lineLimit(1)
            Text("\(shown) / \(model.total)").monospacedDigit().foregroundStyle(BP.inkMuted)
            if model.prefs.zoom != 1 { Text("\(model.prefs.zoom, specifier: "%.1f")×").foregroundStyle(BP.inkMuted) }
        }
        .font(BP.sans(13, .semibold)).foregroundStyle(BP.ink)
        .padding(.horizontal, BP.px(12)).padding(.vertical, BP.px(6))
        .background(Capsule().fill(BP.void_.opacity(0.78)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(BP.px(28))
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private static let modes: [(String, String)] = [("long", "Long strip"), ("paged", "Single"), ("double", "Double")]
    private static let fits: [(String, String)] = [("width", "Fit width"), ("height", "Fit height"), ("original", "Original")]
    private static let bgs: [(String, String)] = [("dark", "Dark"), ("gray", "Dim"), ("light", "Light")]

    private func nextOf(_ list: [(String, String)], _ v: String) -> String {
        let i = list.firstIndex(where: { $0.0 == v }) ?? -1
        return list[(i + 1) % list.count].0
    }
    private func labelOf(_ list: [(String, String)], _ v: String) -> String { list.first(where: { $0.0 == v })?.1 ?? v }

    /// reader-bar + reader-settings, as one row of remote-friendly buttons.
    private var readerBar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: BP.px(4)) {
                Text(model.manga.title).font(BP.sans(19, .bold)).foregroundStyle(BP.ink).lineLimit(1).accessibilityAddTraits(.isHeader)
                Text(barSubtitle)
                    .font(BP.sans(14)).foregroundStyle(BP.inkMuted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BP.gutter).padding(.top, BP.px(36)).padding(.bottom, BP.px(60))
            .background(LinearGradient(colors: [BP.void_.opacity(0.92), .clear], startPoint: .top, endPoint: .bottom))
            Spacer()
            VStack(alignment: .leading, spacing: BP.px(12)) {
                HStack(spacing: BP.px(8)) {
                    barButton("prev", "Previous chapter", icon: "backward.end.fill", enabled: model.prevIndex != nil) { model.previousChapter(); closeMenu() }
                    barButton("next", "Next chapter", icon: "forward.end.fill", enabled: model.nextIndex != nil) { model.nextChapter(); closeMenu() }
                    barButton("mode", T("Reading mode") + ": " + T(model.autoLong ? "Long strip" : labelOf(Self.modes, model.prefs.tvMode)), icon: "rectangle.split.3x1") {
                        model.patch(["mode": .string(nextOf(Self.modes, model.prefs.tvMode))])
                    }
                    barButton("dir", model.prefs.rtl ? "Right to left" : "Left to right", icon: "arrow.left.arrow.right") {
                        model.patch(["rtl": .bool(!model.prefs.rtl)])
                    }
                    barButton("fit", labelOf(Self.fits, model.prefs.fit), icon: "arrow.up.left.and.arrow.down.right") {
                        model.patch(["fit": .string(nextOf(Self.fits, model.prefs.fit))])
                    }
                }
                HStack(spacing: BP.px(8)) {
                    barButton("zoomOut", "Zoom out", icon: "minus.magnifyingglass", enabled: model.prefs.zoom > 0.5) { model.zoomBy(-0.25) }
                    barButton("zoomIn", "Zoom in", icon: "plus.magnifyingglass", enabled: model.prefs.zoom < 3) { model.zoomBy(0.25) }
                    barButton("bg", T("Brightness") + ": " + T(labelOf(Self.bgs, model.prefs.bg)), icon: "sun.max") {
                        model.patch(["bg": .string(nextOf(Self.bgs, model.prefs.bg))])
                    }
                    barButton("auto", T("Auto next chapter") + ": " + T(model.prefs.autoNextChapter ? "On" : "Off"), icon: "arrow.turn.down.right", active: model.prefs.autoNextChapter) {
                        model.patch(["autoNextChapter": .bool(!model.prefs.autoNextChapter)])
                    }
                    barButton("close", "Close reader", icon: "xmark") { closeReader() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BP.gutter).padding(.top, BP.px(60)).padding(.bottom, BP.px(36))
            .background(LinearGradient(colors: [.clear, BP.void_.opacity(0.94)], startPoint: .top, endPoint: .bottom))
            .focusSection()
        }
    }

    /// "Chapter 12 · The chapter's own title" (the title only when it says something new).
    private var barSubtitle: String {
        guard let ch = model.chapter else { return "" }
        var parts = [ch.label]
        if let t = ch.title, !t.isEmpty, t != ch.label { parts.append(t) }
        return parts.joined(separator: " · ")
    }

    private func barButton(_ id: String, _ label: String, icon: String, enabled: Bool = true, active: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) { Label(T(label), systemImage: icon) }
            .buttonStyle(BPActionStyle(primary: active))
            .disabled(!enabled)
            .focused($focus, equals: .bar(id))
    }
}

fileprivate extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
