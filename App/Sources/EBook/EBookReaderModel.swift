import SwiftUI
import UIKit
import AVFoundation

/// One chapter set in type and cut into screen pages with TextKit (the TV's stand-in for
/// harbor-reader's "book" mode and book-pages.ts): the layout manager draws each page's glyphs,
/// and the paragraph starts map pages to upstream's paragraph lines and back.
final class EBookPages: @unchecked Sendable {
    let storage: NSTextStorage
    let layout: NSLayoutManager
    let containers: [NSTextContainer]
    /// Character range of each page.
    let ranges: [NSRange]
    /// Character offset where each paragraph (line) starts.
    let paragraphStarts: [Int]
    let paragraphRanges: [NSRange]
    let pageSize: CGSize

    init(storage: NSTextStorage, layout: NSLayoutManager, containers: [NSTextContainer], ranges: [NSRange], paragraphRanges: [NSRange], pageSize: CGSize) {
        self.storage = storage
        self.layout = layout
        self.containers = containers
        self.ranges = ranges
        self.paragraphRanges = paragraphRanges
        self.paragraphStarts = paragraphRanges.map(\.location)
        self.pageSize = pageSize
    }

    var count: Int { ranges.count }

    /// book-pages pageForParagraph: the page the paragraph starts on.
    func page(forLine line: Int) -> Int {
        guard !paragraphStarts.isEmpty, !ranges.isEmpty else { return 0 }
        let start = paragraphStarts[max(0, min(paragraphStarts.count - 1, line))]
        return ranges.lastIndex(where: { $0.location <= start }) ?? 0
    }

    /// The page holding a character offset (a page's own first character lands on that page).
    func page(forCharacter c: Int) -> Int {
        guard !ranges.isEmpty else { return 0 }
        return ranges.lastIndex(where: { $0.location <= c }) ?? 0
    }

    /// The first character of a page (where a relayout or a resume lands it again).
    func start(ofPage page: Int) -> Int {
        ranges.indices.contains(page) ? ranges[page].location : 0
    }

    /// The line a page is "at": the first paragraph that starts on it, else the one it continues.
    func line(forPage page: Int) -> Int {
        guard ranges.indices.contains(page), !paragraphStarts.isEmpty else { return 0 }
        let r = ranges[page]
        if let first = paragraphStarts.firstIndex(where: { $0 >= r.location && $0 < NSMaxRange(r) }) { return first }
        return max(0, (paragraphStarts.lastIndex(where: { $0 <= r.location }) ?? 0))
    }

    /// Typesets the chapter title and its paragraphs and cuts pages of `size`.
    static func make(title: String, paragraphs: [String], prefs: EBookReaderPrefs, rtl: Bool, size: CGSize) -> EBookPages {
        let paper = prefs.paper
        let ink = UIColor(rgb: paper.ink)
        let muted = UIColor(rgb: paper.muted)
        let fontSize = BP.px(CGFloat(prefs.fontSize))
        let body = EBookPages.font(prefs.font, size: fontSize)
        let heading = EBookPages.font(prefs.font, size: fontSize * 1.5)
        let direction: NSWritingDirection = rtl ? .rightToLeft : .leftToRight

        let text = NSMutableAttributedString()
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.baseWritingDirection = direction
        titleStyle.alignment = .natural
        titleStyle.paragraphSpacing = fontSize * 1.6
        titleStyle.lineSpacing = fontSize * 0.2
        if !title.isEmpty {
            text.append(NSAttributedString(string: title + "\n", attributes: [.font: heading, .foregroundColor: muted, .paragraphStyle: titleStyle]))
        }
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = direction
        style.alignment = .natural
        // CSS line-height is the whole line box; TextKit adds lineSpacing to the font's own height.
        style.lineSpacing = max(0, fontSize * CGFloat(prefs.lineHeight) - body.lineHeight)
        style.paragraphSpacing = fontSize * 0.9
        style.hyphenationFactor = 0.6
        var ranges: [NSRange] = []
        for (i, p) in paragraphs.enumerated() {
            let start = text.length
            let piece = i == paragraphs.count - 1 ? p : p + "\n"
            text.append(NSAttributedString(string: piece, attributes: [.font: body, .foregroundColor: ink, .paragraphStyle: style]))
            ranges.append(NSRange(location: start, length: (p as NSString).length))
        }

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        var pageRanges: [NSRange] = []
        let glyphs = layout.numberOfGlyphs
        var laid = 0
        while laid < glyphs || containers.isEmpty {
            let c = NSTextContainer(size: size)
            c.lineFragmentPadding = 0
            layout.addTextContainer(c)
            let g = layout.glyphRange(for: c)
            containers.append(c)
            pageRanges.append(layout.characterRange(forGlyphRange: g, actualGlyphRange: nil))
            // A container too small for even one line would never advance: stop there.
            if g.length == 0 { break }
            laid = NSMaxRange(g)
            if containers.count > 5000 { break }
        }
        return EBookPages(storage: storage, layout: layout, containers: containers, ranges: pageRanges, paragraphRanges: ranges, pageSize: size)
    }

    /// harbor-reader fontFamily: literary (Georgia), arabic (Traditional Arabic / Naskh),
    /// classic (Book Antiqua / Palatino); each falls back to the system serif.
    static func font(_ face: String, size: CGFloat) -> UIFont {
        let names: [String]
        switch face {
        case "arabic": names = ["GeezaPro", "DamascusMedium", "Damascus"]
        case "classic": names = ["Palatino-Roman", "BookAntiqua", "Baskerville"]
        default: names = ["Georgia", "Sentient-Regular"]
        }
        for n in names { if let f = UIFont(name: n, size: size) { return f } }
        let base = UIFont.systemFont(ofSize: size)
        if let serif = base.fontDescriptor.withDesign(.serif) { return UIFont(descriptor: serif, size: size) }
        return base
    }
}

extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255, alpha: alpha)
    }
}

/// harbor-reader.tsx without the DOM: the chapter's paragraphs, the page in view, the position
/// save (persistReadingPosition), chapter moves, bookmarks, the reading prefs and narration.
/// Upstream narrates with Edge voices in the desktop app and falls back to the device voice
/// (speakWithDevice: one utterance per paragraph from the current line); the TV speaks with
/// AVSpeechSynthesizer the same way, choosing a system voice for the selected Edge voice's locale.
@MainActor
final class EBookReaderModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    let book: EBook
    let epub: EPUBBook
    let chapters: [EBookChapter]
    let paths: [String]
    let pid: String

    @Published private(set) var index: Int
    @Published private(set) var paragraphs: [String] = []
    @Published private(set) var pages: EBookPages?
    @Published var page = 0 { didSet { if page != oldValue { pageChanged() } } }
    @Published private(set) var loading = true
    @Published private(set) var failed: String?
    @Published private(set) var prefs = EBookReaderPrefs()
    @Published private(set) var bookmarks: [EBookBookmark] = []
    @Published private(set) var speaking = false
    @Published private(set) var narrationPaused = false
    @Published private(set) var narrationNotice: String?
    /// The paragraph being read aloud (-1 when silent).
    @Published private(set) var spokenLine = -1
    /// Bumped when the page's drawing changes without a new layout (narration highlight).
    @Published private(set) var paint = 0

    private var identity = ""
    private var pageSize = CGSize(width: 1200, height: 800)
    private var saveTask: Task<Void, Never>?
    /// The position save waiting out the settle delay (flushed early on a chapter move or close).
    private var pendingSave: [any Encodable]?
    private var layoutSeq = 0
    private let synth = AVSpeechSynthesizer()
    private var speechIndex = 0
    /// The utterance in flight; a callback for any other (one stopped earlier) is ignored.
    private var utterance: ObjectIdentifier?
    /// Where the next layout should land: a line (bookmark, chapter start), a saved page inside a
    /// line (resume: characters from the paragraph's start), or the chapter's end.
    private enum Landing { case line(Int), anchor(line: Int, offset: Int), end }
    private var landing: Landing?
    /// Set once the reader has closed: nothing speaks or saves after it.
    private var closed = false

    init(launch: EBookReaderLaunch) {
        book = launch.book
        epub = launch.epub
        chapters = launch.chapters
        paths = launch.paths
        index = max(0, min(launch.chapters.count - 1, launch.index))
        pid = EBookStore.shared.pid
        super.init()
        synth.delegate = self
    }

    var chapter: EBookChapter { chapters[index] }
    var hasPrevious: Bool { index > 0 }
    var hasNext: Bool { index + 1 < chapters.count }
    var pageCount: Int { pages?.count ?? 0 }
    var currentLine: Int { pages?.line(forPage: page) ?? 0 }

    /// ebook-reader.tsx textDirection, unless the prefs force one.
    var rtl: Bool {
        switch prefs.direction {
        case "rtl": return true
        case "ltr": return false
        default: return textRTL
        }
    }

    /// (device-flow pass 8) The text's own direction, worked out once per chapter: `rtl` is read on
    /// every Left / Right press, and each read filtered the first 40 paragraphs' characters twice.
    private var textRTL = false

    private static func detectRTL(_ paragraphs: [String]) -> Bool {
        let sample = paragraphs.prefix(40).joined(separator: " ")
        let arabic = sample.unicodeScalars.filter { (0x0600...0x06ff).contains($0.value) || (0x0750...0x077f).contains($0.value) }.count
        let latin = sample.unicodeScalars.filter { ($0.value >= 0x41 && $0.value <= 0x5a) || ($0.value >= 0x61 && $0.value <= 0x7a) }.count
        return arabic > latin
    }

    func start(pageSize: CGSize) async {
        self.pageSize = pageSize
        if let p: EBookReaderPrefs = try? await HarborEngine.shared.call("ebook.prefs") { prefs = p }
        bookmarks = (try? await HarborEngine.shared.call("ebook.bookmarks", [pid, book.id])) ?? []
        await openChapter(index, landing: nil)
    }

    /// EBookDetails readChapter + the reader's first render: the text through the engine
    /// (cleanSourceText, paragraphs, the saved line), then pages.
    private func openChapter(_ i: Int, landing: Landing?) async {
        guard !closed else { return }
        stopSpeech()
        // (bug pass) Save the page being left before the chapter changes under it: a chapter move
        // inside the 400 ms settle cancelled the pending save, so that page never reached storage
        // (the last page of a chapter, its 100 %, was lost on every Right into the next one).
        let leaving = flushSave()
        index = i
        loading = true
        failed = nil
        pages = nil
        // (bug pass) A relayout still running for the chapter being left must not land its pages
        // over this one (it could, between here and this chapter's own layout).
        layoutSeq += 1
        await leaving?.value
        guard i == index, !closed else { return }
        let path = paths[i]
        let epub = self.epub
        let raw = await Task.detached(priority: .userInitiated) { epub.text(for: path) }.value
        struct Opened: Decodable { var paragraphs: [String]; var line: Int; var identity: String; var offset: Int? }
        let opened: Opened? = try? await HarborEngine.shared.call("ebook.openChapter", [pid, book.id, chapters[i], raw])
        // (bug pass) Only the newest chapter move owns the screen, failure included: an older one
        // failing late put "could not be loaded" over the chapter that had opened.
        guard i == index, !closed else { return }
        guard let opened else {
            loading = false
            failed = "This chapter could not be loaded."
            return
        }
        paragraphs = opened.paragraphs
        textRTL = Self.detectRTL(opened.paragraphs)
        identity = opened.identity
        self.landing = landing ?? opened.offset.map { Landing.anchor(line: opened.line, offset: $0) } ?? Landing.line(opened.line)
        await relayout()
        await EBookStore.shared.refreshLists()
    }

    /// Typesets the chapter off the main thread, then lands on the pending line (or keeps the
    /// current line when only the prefs changed).
    private func relayout() async {
        layoutSeq += 1
        let seq = layoutSeq
        // (bug pass) A prefs change or resize keeps the page's first character in view. Keeping its
        // line sent a page inside a long paragraph back to the paragraph's first page.
        let keepChar = pages.map { $0.start(ofPage: page) }
        let title = chapter.title
        let paras = paragraphs
        let prefs = self.prefs
        let rtl = self.rtl
        let size = pageSize
        let built = await Task.detached(priority: .userInitiated) {
            EBookPages.make(title: title, paragraphs: paras, prefs: prefs, rtl: rtl, size: size)
        }.value
        guard seq == layoutSeq else { return }
        pages = built
        // (device-flow pass 8) A new layout is a new text storage without the narration's mark: a
        // text size, font, width or paper change while reading aloud lost the lit paragraph until
        // the voice reached the next one. It is lit again on the new storage.
        highlighted = nil
        if speaking, spokenLine >= 0 { setSpokenLine(spokenLine) }
        loading = false
        let target: Int
        switch landing {
        case .end?: target = max(0, built.count - 1)
        case .line(let l)?: target = built.page(forLine: l)
        case .anchor(let l, let offset)?:
            target = built.paragraphStarts.indices.contains(l)
                ? built.page(forCharacter: max(0, built.paragraphStarts[l] + offset))
                : built.page(forLine: l)
        case nil: target = keepChar.map { built.page(forCharacter: $0) } ?? 0
        }
        landing = nil
        if page == target { pageChanged() } else { page = target }
        paint += 1
    }

    // MARK: paging

    func nextPage() {
        guard let pages = pages, !loading else { return }
        if page + 1 < pages.count { page += 1 } else if hasNext { Task { await openChapter(index + 1, landing: .line(0)) } }
    }

    func previousPage() {
        guard !loading else { return }
        if page > 0 { page -= 1 } else if hasPrevious { Task { await openChapter(index - 1, landing: .end) } }
    }

    /// The failed chapter's Try again: open it again where it was saved.
    func retry() {
        guard failed != nil, !loading else { return }
        let i = index
        leaveFailedState()
        Task { await openChapter(i, landing: nil) }
    }

    func goToChapter(_ i: Int, line: Int? = nil) {
        guard chapters.indices.contains(i) else { return }
        if i == index, let line, let pages = pages { page = pages.page(forLine: line); return }
        if failed != nil { leaveFailedState() }
        Task { await openChapter(i, landing: line.map { .line($0) }) }
    }

    /// (device-flow pass 8) Out of the failed state at once, as the manga reader's reload() and
    /// changeIndex() do: the page surface stays disabled while `failed` holds, and the card's Try
    /// again / Next chapter hand the ring back to it in the same moment. openChapter cleared the
    /// flag only once its Task ran, so the hand-off could find the surface still disabled and the
    /// ring would not land on the page.
    private func leaveFailedState() {
        failed = nil
        loading = true
    }

    /// What persistReadingPosition gets for the page in view: its line, plus the TV's page anchor
    /// (the page's first character, from that line's start; engine/ebook.ts pageAnchorKey).
    /// (bug pass) On a chapter's last page the whole rest of the chapter is on screen, so it saves
    /// the last line: the first paragraph starting on that page kept chapterProgress under 100, so a
    /// finished book never counted as read (upstream's scroll mode reaches the last line).
    private func positionArgs() -> [any Encodable]? {
        guard let pages, !paragraphs.isEmpty else { return nil }
        let line = page >= pages.count - 1 ? paragraphs.count - 1 : currentLine
        let lineStart = pages.paragraphStarts.indices.contains(line) ? pages.paragraphStarts[line] : 0
        let offset = pages.start(ofPage: page) - lineStart
        return [pid, book.id, chapter, line, paragraphs.count, index, chapters.count, identity, offset]
    }

    /// harbor-reader persistReadingPosition, a moment after the page settles.
    private func pageChanged() {
        guard !closed, let args = positionArgs() else { return }
        pendingSave = args
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flushSave()
        }
    }

    /// Sends the page waiting in the settle delay now (leaving the chapter or the reader). A chapter
    /// move awaits it, so the chapter being left never saves over the resume of the one opening.
    @discardableResult
    private func flushSave() -> Task<Void, Never>? {
        saveTask?.cancel()
        saveTask = nil
        guard let args = pendingSave else { return nil }
        pendingSave = nil
        return Task { let _: EBookResume? = try? await HarborEngine.shared.call("ebook.savePosition", args) }
    }

    /// Leaving the reader stops the voice and saves the page at once. Runs once: from Close / Back,
    /// and again from the view going away any other way (a profile switch, a lock screen), which
    /// used to leave the narration speaking over whatever came next.
    func close() {
        guard !closed else { return }
        stopSpeech()
        closed = true
        flushSave()
    }

    // MARK: prefs (harbor-reader patch)

    func patch(_ change: [String: AnyJSON]) {
        Task {
            if let p: EBookReaderPrefs = try? await HarborEngine.shared.call("ebook.savePrefs", [AnyJSON.object(change)]) {
                let relayoutNeeded = p.fontSize != prefs.fontSize || p.lineHeight != prefs.lineHeight || p.width != prefs.width
                    || p.font != prefs.font || p.direction != prefs.direction || p.background != prefs.background
                prefs = p
                if relayoutNeeded, pages != nil { await relayout() }
            }
        }
    }

    /// The page column: prefs.width (CSS px on the 1140 canvas), inside the screen's gutters.
    var columnWidth: CGFloat { min(BP.px(CGFloat(prefs.width)), 1920 - BP.gutter * 2) }

    func resize(_ size: CGSize) {
        guard abs(size.width - pageSize.width) > 1 || abs(size.height - pageSize.height) > 1 else { return }
        pageSize = size
        if pages != nil { Task { await relayout() } }
    }

    // MARK: bookmarks

    func addBookmark() {
        let line = currentLine
        let preview = paragraphs.indices.contains(line) ? paragraphs[line] : ""
        Task {
            bookmarks = (try? await HarborEngine.shared.call("ebook.addBookmark", [pid, book.id, chapter, line, preview])) ?? bookmarks
        }
    }

    func removeBookmark(_ id: String) {
        Task { bookmarks = (try? await HarborEngine.shared.call("ebook.removeBookmark", [pid, book.id, id])) ?? bookmarks }
    }

    func open(_ bm: EBookBookmark) {
        guard let i = chapters.firstIndex(where: { $0.id == bm.chapterId }) else { return }
        goToChapter(i, line: bm.line)
    }

    // MARK: narration (speakWithDevice)

    static let voices: [(id: String, label: String, tone: String, locale: String)] = [
        ("en-US-AvaNeural", "Ava", "American · Female", "en-US"), ("en-US-AndrewNeural", "Andrew", "American · Male", "en-US"),
        ("en-US-AriaNeural", "Aria", "American · Female", "en-US"), ("en-US-GuyNeural", "Guy", "American · Male", "en-US"),
        ("en-US-JennyNeural", "Jenny", "American · Female", "en-US"), ("en-GB-SoniaNeural", "Sonia", "British · Female", "en-GB"),
        ("en-GB-RyanNeural", "Ryan", "British · Male", "en-GB"), ("en-GB-LibbyNeural", "Libby", "British · Female", "en-GB"),
        ("en-AU-NatashaNeural", "Natasha", "Australian · Female", "en-AU"), ("en-AU-WilliamNeural", "William", "Australian · Male", "en-AU"),
        ("en-CA-ClaraNeural", "Clara", "Canadian · Female", "en-CA"), ("en-CA-LiamNeural", "Liam", "Canadian · Male", "en-CA"),
        ("ar-SA-ZariyahNeural", "زارية", "Saudi · Female", "ar-SA"), ("ar-SA-HamedNeural", "حامد", "Saudi · Male", "ar-SA"),
        ("ar-EG-SalmaNeural", "سلمى", "Egyptian · Female", "ar-EG"), ("ar-EG-ShakirNeural", "شاكر", "Egyptian · Male", "ar-EG"),
        ("ar-AE-FatimaNeural", "فاطمة", "Emirati · Female", "ar-AE"), ("ar-AE-HamdanNeural", "حمدان", "Emirati · Male", "ar-AE"),
        ("ar-KW-NouraNeural", "نورة", "Kuwaiti · Female", "ar-KW"), ("ar-KW-FahedNeural", "فهد", "Kuwaiti · Male", "ar-KW"),
    ]

    var voiceLabel: String {
        let v = Self.voices.first { $0.id == prefs.narrationVoice } ?? Self.voices[0]
        return "\(v.label) · \(v.tone)"
    }

    /// The system voice for the chosen Edge voice: same locale (and gender when the system says),
    /// the best quality installed. Arabic text with a non-Arabic voice reads with an Arabic one,
    /// as upstream's device fallback picks "ar" for right-to-left text.
    private func systemVoice() -> AVSpeechSynthesisVoice? {
        let chosen = Self.voices.first { $0.id == prefs.narrationVoice } ?? Self.voices[0]
        var locale = chosen.locale
        if rtl, !locale.hasPrefix("ar") { locale = "ar-SA" }
        if !rtl, locale.hasPrefix("ar") { locale = "en-US" }
        let female = chosen.tone.contains("Female")
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == locale }
        let ranked = candidates.sorted { a, b in
            let ga = (a.gender == (female ? .female : .male)) ? 1 : 0
            let gb = (b.gender == (female ? .female : .male)) ? 1 : 0
            if ga != gb { return ga > gb }
            return a.quality.rawValue > b.quality.rawValue
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: locale) ?? AVSpeechSynthesisVoice(language: String(locale.prefix(2)))
    }

    func toggleNarration() {
        // (device-flow pass 8) Not while a chapter opens or after it failed: `paragraphs` still held
        // the chapter being left (pages nil, so the voice started at its line 0), and once the new
        // text landed the next utterance read the new chapter's paragraph at the old index.
        if !speaking {
            guard !loading, failed == nil, pages != nil else { return }
            speak(from: currentLine)
            return
        }
        if narrationPaused {
            synth.continueSpeaking()
            narrationPaused = false
        } else {
            synth.pauseSpeaking(at: .word)
            narrationPaused = true
        }
    }

    func speak(from line: Int) {
        stopSpeech()
        guard !closed else { return }
        guard paragraphs.indices.contains(line) else {
            narrationNotice = "There is nothing to read aloud on this page."
            return
        }
        MusicPlayer.shared.pause()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        narrationNotice = nil
        speechIndex = line
        speaking = true
        narrationPaused = false
        speakCurrent()
    }

    private func speakCurrent() {
        guard paragraphs.indices.contains(speechIndex) else { finishSpeech(); return }
        let u = AVSpeechUtterance(string: paragraphs[speechIndex])
        u.voice = systemVoice()
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance = ObjectIdentifier(u)
        synth.speak(u)
    }

    func stopSpeech() {
        utterance = nil
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        finishSpeech()
    }

    private func finishSpeech() {
        speaking = false
        narrationPaused = false
        setSpokenLine(-1)
    }

    /// The paragraph painted on the current `pages.storage` (nil when none).
    private var highlighted: NSRange?

    private func setSpokenLine(_ line: Int) {
        guard let pages = pages else { spokenLine = line; highlighted = nil; return }
        let storage = pages.storage
        let next: NSRange? = pages.paragraphRanges.indices.contains(line) ? pages.paragraphRanges[line] : nil
        // NSLayoutManager's temporary attributes are macOS-only; a background colour on the storage
        // changes no glyph positions, so the pagination stays as it was.
        // (device-flow pass 8) Only the paragraph that was lit and the one to light are edited. The
        // attribute was removed over the whole chapter on every paragraph, and a storage edit
        // invalidates the layout from the edit on: a long chapter could be laid out again from its
        // first page, on the main thread, each time the voice moved on.
        if highlighted != next {
            storage.beginEditing()
            if let old = highlighted, NSMaxRange(old) <= storage.length {
                storage.removeAttribute(NSAttributedString.Key.backgroundColor, range: old)
            }
            if let next {
                storage.addAttribute(NSAttributedString.Key.backgroundColor, value: UIColor(rgb: 0xff9f4d, alpha: 0.22), range: next)
            }
            storage.endEditing()
            highlighted = next
        }
        spokenLine = line
        paint += 1
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.speaking, self.utterance == id else { return }
            // utterance.onstart → goTo(line): the page follows the voice.
            self.setSpokenLine(self.speechIndex)
            if let pages = self.pages { self.page = pages.page(forLine: self.speechIndex) }
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.speaking, self.utterance == id else { return }
            self.speechIndex += 1
            self.speakCurrent()
        }
    }
}
