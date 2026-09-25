import SwiftUI
import UIKit

/// kids/play/play-zone.tsx: the underwater Play Zone with its four activities. Match the Pals,
/// Bubble Numbers and Ocean Wonders are Harbor's own code and are ported natively below. "Games"
/// (games.tsx) is a catalog of 53 third-party Scratch projects that upstream plays in an iframe
/// of scratch.mit.edu/projects/<id>/embed; tvOS has no web view (and Scratch's player needs a
/// browser: JavaScript, WebGL, Web Audio and a keyboard or mouse), so the TV keeps the same
/// catalog and hands the chosen game to a phone, tablet or computer by QR code (PLAN.md
/// decision 7). Back leaves an open game first, then the activity, then the Play Zone.
struct KidsPlayZoneView: View {
    enum Activity: String, CaseIterable, Identifiable {
        case games, memory, bubbles, facts
        var id: String { rawValue }
        var name: String {
            switch self {
            case .games: return "Games"
            case .memory: return "Match the Pals"
            case .bubbles: return "Bubble Numbers"
            case .facts: return "Ocean Wonders"
            }
        }
        var blurb: String {
            switch self {
            case .games: return "Hand-picked mini games"
            case .memory: return "Find the matching pairs"
            case .bubbles: return "Pop the bubbles in order"
            case .facts: return "Amazing true sea facts"
            }
        }
        var art: String {
            switch self {
            case .games: return "lilbluewhale"
            case .memory: return "lilpurpocto"
            case .bubbles: return "liloctored"
            case .facts: return "lilwhale1"
            }
        }
        /// lucide Gamepad2 / Puzzle / Hash / Fish.
        var icon: String {
            switch self {
            case .games: return "gamecontroller.fill"
            case .memory: return "puzzlepiece.fill"
            case .bubbles: return "number"
            case .facts: return "fish.fill"
            }
        }
        var chip: Color {
            switch self {
            case .games: return Color(hex: 0xf472b6)
            case .memory: return Color(hex: 0xa78bfa)
            case .bubbles: return Color(hex: 0x38bdf8)
            case .facts: return Color(hex: 0x4ade80)
            }
        }
    }

    @State private var activity: Activity?
    /// The arcade game that is open (upstream's `gameOpen`): Back closes it before the activity.
    @State private var game: KidsArcadeGame?
    @Environment(\.dismiss) private var dismiss
    /// (kids device pass) The header's Back is the first control on the page, so tvOS put the ring
    /// there when the Play Zone opened and when an activity closed: the kid's first OK left the
    /// Play Zone (or the activity) instead of opening one. The ring opens on the first activity and
    /// comes back to the one just closed.
    @FocusState private var cardFocus: Activity?

    var body: some View {
        ZStack(alignment: .top) {
            KidsUnderwaterScene()
            VStack(alignment: .leading, spacing: BP.px(20)) {
                header
                Group {
                    switch activity {
                    case .games: KidsGameArcade(playing: $game)
                    case .memory: KidsMemoryMatch()
                    case .bubbles: KidsBubblePop()
                    case .facts: KidsOceanFacts()
                    case nil: picker
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, BP.gutter)
            .padding(.top, BP.px(40))
            .padding(.bottom, BP.px(32))
        }
        .ignoresSafeArea()
        .onExitCommand(perform: goBack)
        .onAppear { DispatchQueue.main.async { if activity == nil { cardFocus = Activity.allCases.first } } }
        .onChange(of: activity) { old, now in
            guard now == nil, let old else { return }
            DispatchQueue.main.async { cardFocus = old }
        }
    }

    private func goBack() {
        if game != nil { game = nil } else if activity != nil { activity = nil } else { dismiss() }
    }

    private var header: some View {
        HStack(spacing: BP.px(16)) {
            Button(action: goBack) {
                HStack(spacing: BP.px(10)) {
                    Image(systemName: "arrow.backward").accessibilityHidden(true)
                    Text("Back")
                }
            }
            .buttonStyle(KidsPillStyle(height: BP.px(56)))
            VStack(alignment: .leading, spacing: BP.px(2)) {
                Text(activity.map { T($0.name) } ?? T("Play Zone"))
                    .font(KidsTheme.font(34, .medium)).foregroundStyle(.white)
                    .shadow(color: Color(hex: 0x001428).opacity(0.5), radius: 14, y: 2)
                if activity == nil {
                    Text("Games, coloring and ocean wonders").font(KidsTheme.font(15, .semibold)).foregroundStyle(.white.opacity(0.75))
                }
            }
            Spacer()
            KidsArt(doodle: "lilbluewhale").frame(height: BP.px(64))
        }
        .focusSection()
    }

    private var picker: some View {
        LazyVGrid(columns: [GridItem(.fixed(BP.px(430)), spacing: BP.px(20)), GridItem(.fixed(BP.px(430)), spacing: BP.px(20))], spacing: BP.px(20)) {
            ForEach(Activity.allCases) { a in
                Button { activity = a } label: {
                    HStack(spacing: BP.px(20)) {
                        KidsArt(doodle: a.art).frame(width: BP.px(80), height: BP.px(80))
                        VStack(alignment: .leading, spacing: BP.px(4)) {
                            HStack(spacing: BP.px(10)) {
                                Image(systemName: a.icon)
                                    .font(.system(size: BP.px(15), weight: .bold)).foregroundStyle(.white)
                                    .frame(width: BP.px(32), height: BP.px(32))
                                    .background(Circle().fill(a.chip))
                                    .accessibilityHidden(true)
                                Text(T(a.name)).font(KidsTheme.font(24, .medium)).foregroundStyle(KidsTheme.sea)
                            }
                            Text(T(a.blurb)).font(KidsTheme.font(15, .semibold)).foregroundStyle(KidsTheme.seaMuted)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, BP.px(28)).padding(.vertical, BP.px(24))
                    .frame(width: BP.px(430), alignment: .leading)
                    .background(.white.opacity(0.9))
                }
                .buttonStyle(KidsCardStyle(radius: BP.px(16), ring: BP.px(4)))
                .focused($cardFocus, equals: a)
                .accessibilityIdentifier("kids-play-\(a.rawValue)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
    }
}

// MARK: - Underwater scene

/// kids/play/underwater.tsx: the sea gradient, light shafts, drifting pals and rising bubbles.
struct KidsUnderwaterScene: View {
    private struct Drifter { var src: String; var top: CGFloat; var left: CGFloat; var w: CGFloat; var dur: Double; var flip = false; var op: Double }
    private static let drifters: [Drifter] = [
        Drifter(src: "lilbluewhale", top: 16, left: 74, w: 120, dur: 9, flip: true, op: 0.95),
        Drifter(src: "lilwhale1", top: 64, left: 4, w: 96, dur: 11, op: 0.92),
        Drifter(src: "liloctored", top: 30, left: 8, w: 72, dur: 8, op: 0.9),
        Drifter(src: "lilpurpocto", top: 74, left: 86, w: 66, dur: 10, flip: true, op: 0.9),
        Drifter(src: "lilwhitestar", top: 12, left: 38, w: 26, dur: 7, op: 0.75),
        Drifter(src: "lilorangestar2", top: 48, left: 92, w: 30, dur: 9, op: 0.8),
        Drifter(src: "lilpurplestar", top: 86, left: 30, w: 28, dur: 8, op: 0.75),
        Drifter(src: "lilwhitestar2", top: 40, left: 55, w: 22, dur: 10, op: 0.65),
    ]
    private struct Bubble { var left: CGFloat; var size: CGFloat; var delay: Double; var dur: Double }
    private static let bubbles: [Bubble] = [
        Bubble(left: 6, size: 14, delay: 0, dur: 4.2), Bubble(left: 14, size: 8, delay: 1.4, dur: 3.6),
        Bubble(left: 23, size: 18, delay: 0.6, dur: 5.0), Bubble(left: 31, size: 10, delay: 2.2, dur: 4.4),
        Bubble(left: 44, size: 15, delay: 0.2, dur: 4.8), Bubble(left: 52, size: 9, delay: 1.8, dur: 3.8),
        Bubble(left: 63, size: 20, delay: 0.9, dur: 5.4), Bubble(left: 71, size: 11, delay: 2.6, dur: 4.0),
        Bubble(left: 82, size: 16, delay: 0.4, dur: 4.6), Bubble(left: 90, size: 9, delay: 1.1, dur: 3.5),
        Bubble(left: 96, size: 13, delay: 2.0, dur: 5.2),
    ]

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: UIAccessibility.isReduceMotionEnabled)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                ZStack(alignment: .topLeading) {
                    LinearGradient(stops: [.init(color: Color(hex: 0x2a9db8), location: 0), .init(color: Color(hex: 0x1a7d9e), location: 0.26),
                                           .init(color: Color(hex: 0x10618a), location: 0.52), .init(color: Color(hex: 0x0a4062), location: 0.78),
                                           .init(color: Color(hex: 0x062c47), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                    // The light shafts, fading out towards the sea floor.
                    LinearGradient(stops: [.init(color: .clear, location: 0.12), .init(color: .white.opacity(0.10), location: 0.18), .init(color: .clear, location: 0.26),
                                           .init(color: .clear, location: 0.38), .init(color: .white.opacity(0.07), location: 0.46), .init(color: .clear, location: 0.54),
                                           .init(color: .clear, location: 0.68), .init(color: .white.opacity(0.09), location: 0.76), .init(color: .clear, location: 0.84)],
                                   startPoint: UnitPoint(x: 0, y: 0.3), endPoint: UnitPoint(x: 1, y: 0.7))
                        .frame(height: geo.size.height * 0.62)
                        .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
                    ForEach(Array(Self.drifters.enumerated()), id: \.offset) { i, d in
                        // kids-drift: a slow sway, each pal on its own period and phase.
                        let phase: Double = (t + Double(i) * 0.7).truncatingRemainder(dividingBy: d.dur) / d.dur * 2 * Double.pi
                        let w: CGFloat = BP.px(d.w)
                        let x: CGFloat = geo.size.width * d.left / 100 + w / 2 + CGFloat(sin(phase)) * BP.px(8)
                        let y: CGFloat = geo.size.height * d.top / 100 + w / 2 + CGFloat(cos(phase)) * BP.px(10)
                        KidsArt(doodle: d.src)
                            .frame(width: w)
                            .scaleEffect(x: d.flip ? -1 : 1, y: 1)
                            .rotationEffect(.degrees(sin(phase) * 4))
                            .opacity(d.op)
                            .position(x: x, y: y)
                    }
                    ForEach(Array(Self.bubbles.enumerated()), id: \.offset) { _, b in
                        // kid-bubble-rise: up from below the floor, fading as it climbs.
                        let p: Double = (t + b.delay).truncatingRemainder(dividingBy: b.dur) / b.dur
                        let y: CGFloat = geo.size.height + BP.px(24) - CGFloat(p) * geo.size.height * 0.9
                        Circle().fill(.white.opacity(0.1))
                            .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 2))
                            .frame(width: BP.px(b.size), height: BP.px(b.size))
                            .opacity(1 - p)
                            .position(x: geo.size.width * b.left / 100, y: y)
                    }
                    LinearGradient(colors: [.clear, Color(hex: 0x03121e).opacity(0.55)], startPoint: .top, endPoint: .bottom)
                        .frame(height: BP.px(72))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Match the Pals

/// kids/play/memory-match.tsx: six pairs of sea pals face down; flip two, keep a match.
struct KidsMemoryMatch: View {
    private static let pairs = ["lilbluewhale", "lilwhale1", "liloctored", "lilpurpocto", "lilorangestar2", "lilpurplestar"]
    private struct Card: Identifiable { var key: Int; var art: String; var id: Int { key } }

    private static func buildDeck() -> [Card] {
        (pairs + pairs).enumerated().map { Card(key: $0.offset, art: $0.element) }.shuffled()
    }

    @State private var deck = KidsMemoryMatch.buildDeck()
    @State private var flipped: [Int] = []
    @State private var matched: Set<Int> = []
    @State private var moves = 0
    @State private var locked = false
    private var won: Bool { matched.count == deck.count }
    /// (kids device pass) Card keys, -1 for "Play again". The deck is disabled under the win card,
    /// which threw the ring off the last card to the header's Back (the next OK left the game), and
    /// nothing put it on the deck when the game opened or after Play again.
    @FocusState private var ring: Int?

    var body: some View {
        ZStack {
            VStack(spacing: BP.px(24)) {
                HStack(spacing: BP.px(16)) {
                    Text("Moves: \(moves)")
                        .font(KidsTheme.font(16, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, BP.px(20)).padding(.vertical, BP.px(8))
                        .background(Capsule().fill(.white.opacity(0.2)))
                    Button(action: reset) {
                        HStack(spacing: BP.px(8)) { Image(systemName: "arrow.counterclockwise").accessibilityHidden(true); Text("Shuffle") }
                    }
                    .buttonStyle(KidsPillStyle())
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(BP.px(92)), spacing: BP.px(14)), count: 4), spacing: BP.px(14)) {
                    ForEach(deck) { card in
                        let up = matched.contains(card.key) || flipped.contains(card.key)
                        Button { tap(card.key) } label: { face(card, up: up) }
                            .buttonStyle(KidsCardStyle(radius: BP.px(16), ring: 0))
                            .focused($ring, equals: card.key)
                            .accessibilityLabel(up ? "Card" : "Hidden card")
                    }
                }
                .focusSection()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(won)
            if won { winCard.transition(.opacity) }
        }
        .animation(BP.easeFast, value: won)
        .onAppear { focusDeck() }
        .onChange(of: won) { _, w in
            if w { DispatchQueue.main.async { ring = -1 } } else { focusDeck() }
        }
    }

    private func focusDeck() {
        let first = deck.first?.key
        DispatchQueue.main.async { ring = first }
    }

    private func face(_ card: Card, up: Bool) -> some View {
        let isMatched = matched.contains(card.key)
        return ZStack {
            // Back: the sea-blue face with a question mark.
            RoundedRectangle(cornerRadius: BP.px(16), style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x1d84a8), Color(hex: 0x0d5379)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Text("?").font(KidsTheme.font(28, .bold)).foregroundStyle(.white.opacity(0.8)))
                .overlay(RoundedRectangle(cornerRadius: BP.px(16), style: .continuous).stroke(.white.opacity(0.3), lineWidth: BP.px(4)))
                .opacity(up ? 0 : 1)
            // Front: the pal, framed in sunny yellow once matched.
            RoundedRectangle(cornerRadius: BP.px(16), style: .continuous)
                .fill(.white.opacity(0.95))
                .overlay(KidsArt(doodle: card.art).padding(BP.px(8)))
                .overlay(RoundedRectangle(cornerRadius: BP.px(16), style: .continuous).stroke(isMatched ? KidsTheme.sunny : .white.opacity(0.7), lineWidth: BP.px(4)))
                .scaleEffect(x: -1, y: 1)
                .opacity(up ? 1 : 0)
        }
        .frame(width: BP.px(92), height: BP.px(92) * 4 / 3)
        .rotation3DEffect(.degrees(up ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .animation(.easeInOut(duration: 0.3), value: up)
    }

    private func tap(_ key: Int) {
        guard !locked, !matched.contains(key), !flipped.contains(key) else { return }
        let next = flipped + [key]
        flipped = next
        guard next.count >= 2 else { return }
        moves += 1
        let a = deck.first(where: { $0.key == next[0] })
        let b = deck.first(where: { $0.key == next[1] })
        if let a, let b, a.art == b.art {
            matched.formUnion([a.key, b.key])
            flipped = []
            return
        }
        locked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            locked = false
            flipped = []
        }
    }

    private func reset() {
        deck = Self.buildDeck()
        flipped = []
        matched = []
        moves = 0
        locked = false
    }

    private var winCard: some View {
        ZStack {
            Color(hex: 0x0a2a3f).opacity(0.75).ignoresSafeArea()
            VStack(spacing: BP.px(16)) {
                Image(systemName: "party.popper.fill").font(.system(size: BP.px(44))).foregroundStyle(Color(hex: 0xe08900)).accessibilityHidden(true)
                Text("You found them all!").font(KidsTheme.font(30, .medium)).foregroundStyle(KidsTheme.sea)
                Text("\(moves) moves. Amazing memory!").font(KidsTheme.font(16, .semibold)).foregroundStyle(KidsTheme.seaMuted)
                Button(action: reset) {
                    HStack(spacing: BP.px(8)) { Image(systemName: "arrow.counterclockwise").accessibilityHidden(true); Text("Play again") }
                }
                .buttonStyle(KidsPillStyle(fill: KidsTheme.sunny, ink: KidsTheme.sunnyInk, height: BP.px(56)))
                .prefersDefaultFocus(true, in: winNS)
                .focused($ring, equals: -1)
            }
            .padding(.horizontal, BP.px(48)).padding(.vertical, BP.px(40))
            .background(RoundedRectangle(cornerRadius: BP.px(16), style: .continuous).fill(.white.opacity(0.95)))
            .overlay(RoundedRectangle(cornerRadius: BP.px(16), style: .continuous).stroke(KidsTheme.sunny, lineWidth: BP.px(4)))
            .focusScope(winNS)
        }
    }
    @Namespace private var winNS
}

// MARK: - Bubble Numbers

/// kids/play/bubble-pop.tsx: pop numbered bubbles from 1 upwards; levels grow from 3 to 10.
struct KidsBubblePop: View {
    private static let levels = [3, 4, 5, 6, 7, 8, 9, 10]
    private struct Bubble: Identifiable { var n: Int; var left: CGFloat; var top: CGFloat; var size: CGFloat; var bob: Double; var id: Int { n } }

    /// layoutBubbles(count, salt): a jittered grid, five to a row.
    private static func layout(_ count: Int, salt: Int) -> [Bubble] {
        let cols = min(count, 5)
        return (0..<count).map { i in
            let col = i % cols, row = i / cols
            let jitterX = CGFloat((i * 37 + salt * 13) % 12) - 6
            let jitterY = CGFloat((i * 53 + salt * 7) % 14) - 7
            let span = CGFloat(max(1, cols - 1))
            return Bubble(n: i + 1,
                          left: 10 + CGFloat(col) * (80 / span) + jitterX,
                          top: 18 + CGFloat(row) * 34 + jitterY,
                          size: CGFloat(84 + (i * 29 + salt * 11) % 22),
                          bob: 2.6 + Double((i * 17) % 14) / 10)
        }
    }

    @State private var levelIdx = 0
    @State private var salt = 1
    @State private var nextUp = 1
    @State private var wrong: Int?
    @Namespace private var doneNS
    /// (kids device pass) Bubble numbers; -1 "Again", -2 "Bigger numbers!". A popped bubble is
    /// disabled under the ring, which then jumped to the header's Back (the next OK left the game);
    /// it now moves to the nearest bubble still up, and to the done card's buttons at the end.
    @FocusState private var ring: Int?

    private var count: Int { Self.levels[levelIdx] }
    private var done: Bool { nextUp > count }

    var body: some View {
        ZStack {
            VStack(spacing: BP.px(16)) {
                Text("Pop the bubbles in order! Find number \(done ? "..." : String(nextUp))")
                    .font(KidsTheme.font(17, .bold)).foregroundStyle(.white)
                    .padding(.horizontal, BP.px(24)).padding(.vertical, BP.px(8))
                    .background(Capsule().fill(.white.opacity(0.2)))
                GeometryReader { geo in
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: UIAccessibility.isReduceMotionEnabled)) { tl in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        ZStack(alignment: .topLeading) {
                            ForEach(Self.layout(count, salt: salt)) { b in
                                let popped = b.n < nextUp
                                // curfew-bob: a gentle float; curfew-shake on a wrong pick.
                                let bob: CGFloat = CGFloat(sin(t / b.bob * 2 * Double.pi)) * BP.px(6)
                                let shake: CGFloat = wrong == b.n ? CGFloat(sin(t * 60)) * BP.px(6) : 0
                                let side: CGFloat = BP.px(b.size)
                                let x: CGFloat = geo.size.width * b.left / 100 + side / 2 + shake
                                let y: CGFloat = geo.size.height * b.top / 100 + side / 2 + bob
                                Button { pop(b.n) } label: {
                                    Text("\(b.n)")
                                        .font(KidsTheme.font(30, .semibold)).foregroundStyle(.white)
                                        .frame(width: BP.px(b.size), height: BP.px(b.size))
                                        .background(Circle().fill(.white.opacity(0.15)))
                                        .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: BP.px(4)))
                                }
                                .buttonStyle(KidsBubbleStyle())
                                .disabled(popped || done)
                                .focused($ring, equals: b.n)
                                .opacity(popped ? 0 : 1)
                                .scaleEffect(popped ? 1.5 : 1)
                                .animation(.easeOut(duration: 0.3), value: popped)
                                .accessibilityLabel("Bubble \(b.n)")
                                .position(x: x, y: y)
                            }
                        }
                    }
                }
                .frame(maxWidth: BP.px(720))
                .focusSection()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if done { doneCard.transition(.opacity) }
        }
        .animation(BP.easeFast, value: done)
        .onAppear { DispatchQueue.main.async { ring = 1 } }
        .onChange(of: done) { _, d in
            let target = d ? (levelIdx < Self.levels.count - 1 ? -2 : -1) : 1
            DispatchQueue.main.async { ring = target }
        }
    }

    private func pop(_ n: Int) {
        guard !done else { return }
        if n != nextUp {
            wrong = n
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { if wrong == n { wrong = nil } }
            return
        }
        nextUp += 1
        guard !done, let target = nearestLeft(to: n) else { return }
        DispatchQueue.main.async { ring = target }
    }

    /// The bubble still up that sits closest to the one just popped.
    private func nearestLeft(to n: Int) -> Int? {
        let all = Self.layout(count, salt: salt)
        guard let from = all.first(where: { $0.n == n }) else { return nil }
        func d(_ b: Bubble) -> CGFloat { (b.left - from.left) * (b.left - from.left) + (b.top - from.top) * (b.top - from.top) }
        return all.filter { $0.n >= nextUp }.min { d($0) < d($1) }?.n
    }

    private func startLevel(_ idx: Int) {
        levelIdx = idx
        salt += 1
        nextUp = 1
        wrong = nil
    }

    private var doneCard: some View {
        ZStack {
            Color(hex: 0x0a2a3f).opacity(0.6).ignoresSafeArea()
            VStack(spacing: BP.px(16)) {
                Image(systemName: "party.popper.fill").font(.system(size: BP.px(44))).foregroundStyle(Color(hex: 0xe08900)).accessibilityHidden(true)
                Text("You counted to \(count)!").font(KidsTheme.font(30, .medium)).foregroundStyle(KidsTheme.sea)
                HStack(spacing: BP.px(12)) {
                    Button("Again") { startLevel(levelIdx) }
                        .buttonStyle(KidsPillStyle(fill: .white, ink: KidsTheme.sea, height: BP.px(56)))
                        .focused($ring, equals: -1)
                    if levelIdx < Self.levels.count - 1 {
                        Button("Bigger numbers!") { startLevel(levelIdx + 1) }
                            .buttonStyle(KidsPillStyle(fill: KidsTheme.sunny, ink: KidsTheme.sunnyInk, height: BP.px(56)))
                            .prefersDefaultFocus(true, in: doneNS)
                            .focused($ring, equals: -2)
                    }
                }
            }
            .padding(.horizontal, BP.px(48)).padding(.vertical, BP.px(40))
            .background(RoundedRectangle(cornerRadius: BP.px(16), style: .continuous).fill(.white.opacity(0.95)))
            .overlay(RoundedRectangle(cornerRadius: BP.px(16), style: .continuous).stroke(KidsTheme.sunny, lineWidth: BP.px(4)))
            .focusScope(doneNS)
        }
    }
}

/// A bubble: brighter and a little bigger while focused, a sunny rim so the remote can see it.
struct KidsBubbleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .overlay(Circle().stroke(KidsTheme.sunny, lineWidth: focused ? 5 : 0))
                .shadow(color: Color(hex: 0x001428).opacity(0.5), radius: focused ? 18 : 10, y: focused ? 12 : 8)
                .scaleEffect(focused ? (configuration.isPressed ? 1.05 : 1.12) : 1)
                .animation(BP.easeFast, value: focused)
        }
    }
}

// MARK: - Ocean Wonders

/// kids/play/ocean-facts.tsx: one true sea fact at a time with its Wikimedia Commons photo
/// (a sea pal when the photo will not load), in a shuffled order; "Another one!" moves on.
struct KidsOceanFacts: View {
    private struct Fact { var fact: String; var art: String; var img: String }
    private static let wm = "https://upload.wikimedia.org/wikipedia/commons/thumb"
    private static let facts: [Fact] = [
        Fact(fact: "Octopuses have three hearts and blue blood!", art: "liloctored", img: "\(wm)/5/57/Octopus2.jpg/960px-Octopus2.jpg"),
        Fact(fact: "A blue whale's heart is as big as a small car.", art: "lilbluewhale", img: "\(wm)/1/1c/Anim1754_-_Flickr_-_NOAA_Photo_Library.jpg/960px-Anim1754_-_Flickr_-_NOAA_Photo_Library.jpg"),
        Fact(fact: "Starfish can regrow a whole arm if they lose one.", art: "lilorangestar2", img: "\(wm)/c/c7/Starfish_montage.png/960px-Starfish_montage.png"),
        Fact(fact: "Whales sing songs that travel for miles under the sea.", art: "lilwhale1", img: "\(wm)/6/61/Humpback_Whale_underwater_shot.jpg/960px-Humpback_Whale_underwater_shot.jpg"),
        Fact(fact: "Sea otters hold hands while they sleep so they don't float apart.", art: "lilwhitestar", img: "\(wm)/0/02/Sea_Otter_%28Enhydra_lutris%29_%2825169790524%29_crop.jpg/960px-Sea_Otter_%28Enhydra_lutris%29_%2825169790524%29_crop.jpg"),
        Fact(fact: "Seahorse dads are the ones who carry the babies.", art: "lilpurplestar", img: "\(wm)/2/25/Hippocampus_hippocampus_%28on_Ascophyllum_nodosum%29.jpg/960px-Hippocampus_hippocampus_%28on_Ascophyllum_nodosum%29.jpg"),
        Fact(fact: "Crabs walk sideways, and they're really fast at it!", art: "lilpurpocto", img: "\(wm)/7/71/Cancer_pagurus.jpg/960px-Cancer_pagurus.jpg"),
        Fact(fact: "Sharks grow new teeth their whole lives, row after row.", art: "lilbluewhale", img: "\(wm)/5/56/White_shark.jpg/960px-White_shark.jpg"),
        Fact(fact: "The ocean covers more than half of our whole planet.", art: "lilwhale1", img: "\(wm)/d/db/Pacific_Ocean_as_viewed_from_GOES-18_on_September_23%2C_2023.jpg/960px-Pacific_Ocean_as_viewed_from_GOES-18_on_September_23%2C_2023.jpg"),
        Fact(fact: "Some jellyfish can glow in the dark like little lanterns.", art: "lilpurplestar", img: "\(wm)/4/44/Jelly_cc11.jpg/960px-Jelly_cc11.jpg"),
        Fact(fact: "An octopus can squeeze through a hole the size of a coin.", art: "lilpurpocto", img: "\(wm)/0/0b/Enteroctopus_dolfeini.jpg/960px-Enteroctopus_dolfeini.jpg"),
        Fact(fact: "Dolphins sleep with one eye open to stay safe.", art: "lilwhitestar2", img: "\(wm)/b/bc/Tursiops_truncatus_01-cropped.jpg/960px-Tursiops_truncatus_01-cropped.jpg"),
        Fact(fact: "A group of fish swimming together is called a school.", art: "lilorangestar2", img: "\(wm)/b/b1/Sardines_-_%E9%B0%AF%28%E3%81%84%E3%82%8F%E3%81%97%29.jpg/960px-Sardines_-_%E9%B0%AF%28%E3%81%84%E3%82%8F%E3%81%97%29.jpg"),
        Fact(fact: "Sea turtles can live to be more than 100 years old.", art: "lilwhitestar", img: "\(wm)/a/a3/Green_sea_turtle_%28Chelonia_mydas%29_Moorea.jpg/960px-Green_sea_turtle_%28Chelonia_mydas%29_Moorea.jpg"),
        Fact(fact: "Penguins can't fly in the air, but they fly underwater.", art: "liloctored", img: "\(wm)/a/a3/Aptenodytes_forsteri_-Snow_Hill_Island%2C_Antarctica_-adults_and_juvenile-8.jpg/960px-Aptenodytes_forsteri_-Snow_Hill_Island%2C_Antarctica_-adults_and_juvenile-8.jpg"),
        Fact(fact: "Coral reefs are built by tiny animals smaller than your fingernail.", art: "lilpurplestar", img: "\(wm)/7/76/Blue_Linckia_Starfish.JPG/960px-Blue_Linckia_Starfish.JPG"),
        Fact(fact: "Clownfish live safely inside stinging anemones. The stings don't hurt them!", art: "lilorangestar2", img: "\(wm)/f/f6/Clown_fish_in_the_Andaman_Coral_Reef.jpg/960px-Clown_fish_in_the_Andaman_Coral_Reef.jpg"),
        Fact(fact: "Electric eels can make their own electricity to light up their hunt.", art: "lilwhale1", img: "\(wm)/8/8f/Electric-eel.jpg/960px-Electric-eel.jpg"),
    ]

    /// ocean-facts.tsx shuffled(seed): the same LCG, so an order is a pure function of its seed.
    private static func shuffled(_ seed: Int) -> [Int] {
        var order = Array(facts.indices)
        var s = seed
        var i = order.count - 1
        while i > 0 {
            s = (s * 9301 + 49297) % 233280
            let j = Int(Double(s) / 233280 * Double(i + 1))
            order.swapAt(i, j)
            i -= 1
        }
        return order
    }

    @State private var order = KidsOceanFacts.shuffled(Int.random(in: 0..<233280))
    @State private var idx = 0
    @State private var image: UIImage?
    @State private var imgFailed = false
    /// (kids device pass) The activity card that opened this is gone, and tvOS put the ring on the
    /// header's Back: "Another one!" takes it, as the only thing to press here.
    @FocusState private var nextFocused: Bool

    private var fact: Fact { Self.facts[order[idx % order.count]] }

    var body: some View {
        VStack(spacing: BP.px(24)) {
            VStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    Color(hex: 0xdceef5)
                    if imgFailed {
                        KidsArt(doodle: fact.art).frame(height: BP.px(96)).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let image {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill).transition(.opacity)
                        Text("Wikimedia Commons".uppercased())
                            .font(KidsTheme.font(9.5, .semibold)).tracking(1).foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(2))
                            .background(Capsule().fill(.black.opacity(0.45)))
                            .padding(.trailing, BP.px(12)).padding(.bottom, BP.px(8))
                    } else {
                        ProgressView().tint(KidsTheme.seaMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: imgFailed ? BP.px(180) : BP.px(250))
                .clipped()
                Text(fact.fact)
                    .font(KidsTheme.font(27, .medium)).foregroundStyle(KidsTheme.sea)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, BP.px(40)).padding(.vertical, BP.px(32))
            }
            .frame(width: BP.px(640))
            .background(.white.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: BP.px(32), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BP.px(32), style: .continuous).stroke(.white.opacity(0.25), lineWidth: BP.px(4)))
            .shadow(color: Color(hex: 0x001428).opacity(0.6), radius: 40, y: 30)
            .id(idx)
            .transition(.opacity)
            Button { idx += 1 } label: {
                HStack(spacing: BP.px(12)) { Image(systemName: "sparkles").accessibilityHidden(true); Text("Another one!") }
            }
            .buttonStyle(KidsPillStyle(fill: KidsTheme.sunny, ink: KidsTheme.sunnyInk, height: BP.px(64)))
            .focused($nextFocused)
            .accessibilityIdentifier("kids-facts-next")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(BP.easeFast, value: idx)
        .onAppear { DispatchQueue.main.async { nextFocused = true } }
        .task(id: idx) {
            image = nil
            imgFailed = false
            if let u = URL(string: fact.img) {
                let img = await ImageLoader.shared.image(for: u)
                // (bug pass) "Another one!" cancels this task, but the load runs on: a slow photo
                // landing after the next fact's (often preloaded) one put the wrong animal on it.
                guard !Task.isCancelled else { return }
                image = img
                imgFailed = img == nil
            }
            // The next fact's photo warms the cache (ocean-facts.tsx preloads it).
            let next = Self.facts[order[(idx + 1) % order.count]]
            if let u = URL(string: next.img) { _ = await ImageLoader.shared.image(for: u) }
        }
    }
}
