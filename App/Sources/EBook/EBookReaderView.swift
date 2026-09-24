import SwiftUI
import UIKit

/// The TV eBook reader (views/ebook/harbor-reader.tsx in its "book" mode). The remote replaces
/// the mouse and keys:
/// - Left / Right turn pages (swapped for right-to-left text); past a chapter's last page Right
///   opens the next chapter, and before its first page Left goes back to the previous one.
/// - Play/Pause reads aloud from the page (or pauses and resumes the voice).
/// - Select opens the reader bar: chapters, bookmarks, reading settings, read aloud, close.
/// - Back closes a panel, then the bar, then the reader.
@MainActor
struct EBookReaderView: View {
    @StateObject private var model: EBookReaderModel
    let onExit: () -> Void

    @State private var menuOpen = false
    @State private var panel: Panel?
    @State private var counterVisible = true
    @State private var counterTask: Task<Void, Never>?
    @FocusState private var focus: Focus?
    private enum Focus: Hashable { case surface, bar(String), item(String) }
    private enum Panel: String { case chapters, bookmarks, settings }

    private static let screen = CGSize(width: 1920, height: 1080)
    private static let cardInsetY = BP.px(40)
    private static let textInsetX = BP.px(40)
    private static let textInsetY = BP.px(34)

    init(launch: EBookReaderLaunch, onExit: @escaping () -> Void) {
        _model = StateObject(wrappedValue: EBookReaderModel(launch: launch))
        self.onExit = onExit
    }

    private var paper: EBookReaderPrefs.Paper { model.prefs.paper }

    /// The text area inside the page card, from the column width the prefs choose.
    private var textSize: CGSize {
        CGSize(width: model.columnWidth - Self.textInsetX * 2,
               height: Self.screen.height - Self.cardInsetY * 2 - Self.textInsetY * 2 - BP.px(26))
    }

    var body: some View {
        ZStack {
            Color(hex: paper.desk).ignoresSafeArea()
            pageCard
                .brightness((model.prefs.brightness - 100) / 100 * 0.6)
            // The invisible surface holds focus while the bar is down so remote presses reach us.
            Button { openMenu() } label: { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .disabled(menuOpen || panel != nil)
                .focused($focus, equals: .surface)
                .onMoveCommand(perform: move)
            if menuOpen { readerBar.transition(.opacity) }
            if let panel { panelView(panel).transition(.move(edge: .trailing).combined(with: .opacity)) }
        }
        .ignoresSafeArea()
        .onPlayPauseCommand { model.toggleNarration() }
        .onExitCommand {
            if panel != nil { closePanel() } else if menuOpen { closeMenu() } else { closeReader() }
        }
        .task {
            focus = .surface
            await model.start(pageSize: textSize)
        }
        .onChange(of: model.prefs.width) { _, _ in model.resize(textSize) }
        .onChange(of: model.page) { _, _ in showCounter() }
        .animation(BP.easeFast, value: menuOpen)
        .animation(BP.easeFast, value: panel)
    }

    // MARK: page

    private var pageCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.chapter.title.isEmpty ? model.book.title : model.chapter.title)
                    .lineLimit(1)
                Spacer()
                Text(model.book.title).lineLimit(1)
            }
            .font(BP.sans(11, .medium)).foregroundStyle(Color(hex: paper.muted))
            .frame(height: BP.px(26))
            ZStack {
                if model.loading {
                    ProgressView().tint(Color(hex: paper.muted))
                } else if let failed = model.failed {
                    VStack(spacing: BP.px(12)) {
                        Text(T(failed)).font(BP.sans(17, .semibold)).foregroundStyle(Color(hex: paper.ink))
                        Button("Close reader") { closeReader() }.buttonStyle(BPActionStyle())
                    }
                } else {
                    EBookPageCanvas(pages: model.pages, page: model.page, paint: model.paint)
                }
            }
            .frame(width: textSize.width, height: textSize.height)
        }
        .padding(.horizontal, Self.textInsetX)
        .padding(.vertical, Self.textInsetY)
        .frame(width: model.columnWidth)
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(Color(hex: paper.page)))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
        .overlay(alignment: .bottom) {
            if counterVisible || menuOpen || model.speaking { counter.offset(y: BP.px(30)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, Self.cardInsetY)
    }

    /// "page / pages · chapter", plus the voice while reading aloud.
    private var counter: some View {
        HStack(spacing: BP.px(10)) {
            if model.pageCount > 0 {
                Text(verbatim: "\(model.page + 1) / \(model.pageCount)").monospacedDigit()
            }
            Text(T("%@ of %@", String(model.index + 1), String(model.chapters.count))).foregroundStyle(Color(hex: paper.muted))
            if model.speaking {
                Image(systemName: model.narrationPaused ? "pause.fill" : "speaker.wave.2.fill")
                Text(model.voiceLabel).foregroundStyle(Color(hex: paper.muted))
            }
            if let note = model.narrationNotice { Text(T(note)).foregroundStyle(Color(hex: paper.muted)) }
        }
        .font(BP.sans(12, .semibold)).foregroundStyle(Color(hex: paper.ink))
        .padding(.horizontal, BP.px(12)).padding(.vertical, BP.px(5))
        .background(Capsule().fill(Color(hex: paper.desk).opacity(0.85)))
        .allowsHitTesting(false)
    }

    private func showCounter() {
        counterVisible = true
        counterTask?.cancel()
        counterTask = Task {
            try? await Task.sleep(for: .milliseconds(2600))
            guard !Task.isCancelled else { return }
            withAnimation(BP.easeFast) { counterVisible = false }
        }
    }

    // MARK: remote

    private func move(_ dir: MoveCommandDirection) {
        switch dir {
        case .right: if model.rtl { model.previousPage() } else { model.nextPage() }
        case .left: if model.rtl { model.nextPage() } else { model.previousPage() }
        case .down: model.nextPage()
        case .up: model.previousPage()
        @unknown default: break
        }
    }

    private func openMenu() {
        menuOpen = true
        DispatchQueue.main.async { focus = .bar("chapters") }
    }

    private func closeMenu() {
        menuOpen = false
        DispatchQueue.main.async { focus = .surface }
    }

    private func openPanel(_ p: Panel) {
        panel = p
        menuOpen = false
        DispatchQueue.main.async {
            switch p {
            case .chapters: focus = .item("ch-\(model.index)")
            case .bookmarks: focus = .item(model.bookmarks.first.map { "bm-\($0.id)" } ?? "bm-add")
            case .settings: focus = .item("paper-\(model.prefs.background)")
            }
        }
    }

    private func closePanel() {
        panel = nil
        DispatchQueue.main.async { focus = .surface }
    }

    private func closeReader() {
        model.close()
        onExit()
    }

    // MARK: bar

    private var readerBar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: BP.px(4)) {
                Text(model.book.title).font(BP.sans(19, .bold)).foregroundStyle(BP.ink).lineLimit(1)
                Text(model.chapter.label == model.chapter.title ? model.chapter.title : "\(model.chapter.label) · \(model.chapter.title)")
                    .font(BP.sans(14)).foregroundStyle(BP.inkMuted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BP.gutter).padding(.top, BP.px(36)).padding(.bottom, BP.px(60))
            .background(LinearGradient(colors: [BP.void_.opacity(0.92), .clear], startPoint: .top, endPoint: .bottom))
            Spacer()
            HStack(spacing: BP.px(8)) {
                barButton("prev", "Previous chapter", icon: "backward.end.fill", enabled: model.hasPrevious) { model.goToChapter(model.index - 1, line: 0); closeMenu() }
                barButton("next", "Next chapter", icon: "forward.end.fill", enabled: model.hasNext) { model.goToChapter(model.index + 1, line: 0); closeMenu() }
                barButton("chapters", "Chapters", icon: "list.bullet") { openPanel(.chapters) }
                barButton("mark", "Bookmark current passage", icon: "bookmark") { model.addBookmark(); openPanel(.bookmarks) }
                barButton("bookmarks", "Bookmarks", icon: "bookmark.fill") { openPanel(.bookmarks) }
                barButton("speak", narrationLabel, icon: model.speaking && !model.narrationPaused ? "pause.fill" : "speaker.wave.2.fill", active: model.speaking) {
                    model.toggleNarration()
                }
                if model.speaking {
                    barButton("stop", "Stop", icon: "stop.fill") { model.stopSpeech() }
                }
                barButton("settings", "Reader settings", icon: "textformat.size") { openPanel(.settings) }
                barButton("close", "Close reader", icon: "xmark") { closeReader() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BP.gutter).padding(.top, BP.px(60)).padding(.bottom, BP.px(36))
            .background(LinearGradient(colors: [.clear, BP.void_.opacity(0.94)], startPoint: .top, endPoint: .bottom))
            .focusSection()
        }
    }

    private var narrationLabel: String {
        if !model.speaking { return "Read aloud" }
        return model.narrationPaused ? "Resume narration" : "Pause narration"
    }

    private func barButton(_ id: String, _ label: String, icon: String, enabled: Bool = true, active: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) { Label(T(label), systemImage: icon) }
            .buttonStyle(BPActionStyle(primary: active))
            .disabled(!enabled)
            .focused($focus, equals: .bar(id))
    }

    // MARK: panels

    private func panelView(_ p: Panel) -> some View {
        HStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: BP.px(14)) {
                Text(p == .chapters ? T("Chapters") : p == .bookmarks ? T("Bookmarks") : T("Reading settings"))
                    .font(BP.sans(20, .bold)).foregroundStyle(BP.ink)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: BP.px(8)) {
                        switch p {
                        case .chapters: chaptersPanel
                        case .bookmarks: bookmarksPanel
                        case .settings: settingsPanel
                        }
                    }
                    .padding(.vertical, BP.px(10)).padding(.horizontal, BP.px(6))
                }
                .scrollClipDisabled()
            }
            .padding(BP.px(28))
            .frame(width: BP.px(460))
            .frame(maxHeight: .infinity, alignment: .top)
            .background(BP.panel.opacity(0.98))
            .focusSection()
        }
    }

    @ViewBuilder private var chaptersPanel: some View {
        Text(T("%@ chapters", String(model.chapters.count))).font(BP.sans(13)).foregroundStyle(BP.inkMuted)
        ForEach(Array(model.chapters.enumerated()), id: \.element.id) { i, ch in
            Button {
                model.goToChapter(i, line: i == model.index ? nil : 0)
                closePanel()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ch.title.isEmpty ? T("Chapter %@", String(i + 1)) : ch.title).font(BP.sans(15, .semibold)).lineLimit(2)
                    Text(ch.chapter.map { T("Chapter %@", $0) } ?? T("Position %@", String(i + 1))).font(BP.sans(12)).opacity(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(BPActionStyle(primary: i == model.index))
            .focused($focus, equals: .item("ch-\(i)"))
        }
    }

    @ViewBuilder private var bookmarksPanel: some View {
        Button { model.addBookmark() } label: { Label(T("Bookmark current passage"), systemImage: "bookmark") }
            .buttonStyle(BPActionStyle(primary: true))
            .focused($focus, equals: .item("bm-add"))
        if model.bookmarks.isEmpty {
            BPNote(text: "No saved passages yet.")
        }
        ForEach(model.bookmarks) { bm in
            HStack(spacing: BP.px(8)) {
                Button {
                    model.open(bm)
                    closePanel()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(bm.chapterLabel ?? bm.chapterTitle) · \(T("Line %@", String(bm.line + 1)))").font(BP.sans(12, .semibold)).opacity(0.75)
                        Text(bm.preview).font(BP.sans(14)).lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(BPActionStyle())
                .focused($focus, equals: .item("bm-\(bm.id)"))
                Button { model.removeBookmark(bm.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(BPActionStyle())
                    .accessibilityLabel("Delete bookmark")
            }
        }
    }

    private static let backgrounds: [(String, String)] = [("dark", "Dark"), ("dim", "Dim"), ("light", "Light")]
    private static let fonts: [(String, String)] = [("literary", "Literary"), ("arabic", "Arabic"), ("classic", "Classic")]
    private static let directions: [(String, String)] = [("auto", "Auto"), ("ltr", "LTR"), ("rtl", "RTL")]

    @ViewBuilder private var settingsPanel: some View {
        settingLabel("Paper")
        HStack(spacing: BP.px(6)) {
            ForEach(Self.backgrounds, id: \.0) { v in
                choice("paper-\(v.0)", v.1, on: model.prefs.background == v.0) { model.patch(["background": .string(v.0)]) }
            }
        }
        settingLabel("Type")
        HStack(spacing: BP.px(6)) {
            ForEach(Self.fonts, id: \.0) { v in
                choice("font-\(v.0)", v.1, on: model.prefs.font == v.0) { model.patch(["font": .string(v.0)]) }
            }
        }
        // harbor-reader "Reading adjustments": the four ranges with upstream's bounds and steps.
        stepper("Text size", value: model.prefs.fontSize, format: "%.0f", step: 1, range: 15...34, key: "fontSize")
        stepper("Line height", value: model.prefs.lineHeight, format: "%.2f", step: 0.05, range: 1.25...2.4, key: "lineHeight")
        stepper("Page width", value: model.prefs.width, format: "%.0f", step: 20, range: 520...1080, key: "width")
        stepper("Brightness", value: model.prefs.brightness, format: "%.0f%%", step: 5, range: 55...120, key: "brightness")
        settingLabel("Direction")
        HStack(spacing: BP.px(6)) {
            ForEach(Self.directions, id: \.0) { v in
                choice("dir-\(v.0)", v.1, on: model.prefs.direction == v.0) { model.patch(["direction": .string(v.0)]) }
            }
        }
        settingLabel("Voice")
        BPNote(text: "Read aloud uses this device's voice for the language you pick.", tone: BP.inkSubtle)
        ForEach(EBookReaderModel.voices, id: \.id) { v in
            Button { model.patch(["narrationVoice": .string(v.id)]) } label: {
                HStack {
                    Text(verbatim: v.label).font(BP.sans(14, .semibold))
                    Spacer()
                    Text(verbatim: v.tone).font(BP.sans(12)).opacity(0.7)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(BPActionStyle(primary: model.prefs.narrationVoice == v.id))
            .focused($focus, equals: .item("voice-\(v.id)"))
        }
    }

    private func settingLabel(_ s: String) -> some View {
        Text(T(s)).font(BP.sans(12, .bold)).textCase(.uppercase).tracking(1.2).foregroundStyle(BP.inkSubtle).padding(.top, BP.px(8))
    }

    private func choice(_ id: String, _ label: String, on: Bool, run: @escaping () -> Void) -> some View {
        Button(T(label), action: run)
            .buttonStyle(BPActionStyle(primary: on))
            .focused($focus, equals: .item(id))
    }

    private func stepper(_ label: String, value: Double, format: String, step: Double, range: ClosedRange<Double>, key: String) -> some View {
        HStack(spacing: BP.px(8)) {
            Text(T(label)).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
            Spacer()
            Button { set(key, value - step, range) } label: { Image(systemName: "minus") }
                .buttonStyle(BPActionStyle())
                .disabled(value <= range.lowerBound + 0.0001)
                .focused($focus, equals: .item("\(key)-minus"))
            Text(String(format: format, value)).font(BP.sans(14, .semibold)).monospacedDigit().foregroundStyle(BP.ink)
                .frame(minWidth: BP.px(56))
            Button { set(key, value + step, range) } label: { Image(systemName: "plus") }
                .buttonStyle(BPActionStyle())
                .disabled(value >= range.upperBound - 0.0001)
                .focused($focus, equals: .item("\(key)-plus"))
        }
        .padding(.top, BP.px(4))
    }

    private func set(_ key: String, _ v: Double, _ range: ClosedRange<Double>) {
        let clamped = min(range.upperBound, max(range.lowerBound, (v * 100).rounded() / 100))
        model.patch([key: .number(clamped)])
    }
}

/// Draws one page of an EBookPages layout: the glyphs of that page's text container.
struct EBookPageCanvas: UIViewRepresentable {
    let pages: EBookPages?
    let page: Int
    /// Changes whenever the page must be drawn again without a new layout (narration highlight).
    let paint: Int

    func makeUIView(context: Context) -> EBookPageUIView {
        let v = EBookPageUIView()
        v.isOpaque = false
        v.backgroundColor = .clear
        v.contentMode = .redraw
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: EBookPageUIView, context: Context) {
        v.pages = pages
        v.page = page
        v.setNeedsDisplay()
    }
}

final class EBookPageUIView: UIView {
    var pages: EBookPages?
    var page = 0

    override func draw(_ rect: CGRect) {
        guard let pages = pages, pages.containers.indices.contains(page) else { return }
        let glyphs = pages.layout.glyphRange(for: pages.containers[page])
        guard glyphs.length > 0 else { return }
        pages.layout.drawBackground(forGlyphRange: glyphs, at: .zero)
        pages.layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }
}
