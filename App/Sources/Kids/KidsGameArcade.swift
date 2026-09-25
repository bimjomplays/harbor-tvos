import SwiftUI
import UIKit

/// kids/play/games.tsx `Game`: one hand-picked Scratch project.
struct KidsArcadeGame: Identifiable, Equatable {
    let name: String
    let blurb: String
    let scratchId: Int
    let cat: String
    var id: Int { scratchId }

    /// games.tsx embedUrl: the bare Scratch player (no comments or remixes around it), the page
    /// upstream puts in its iframe and the one the QR code opens.
    var embedURL: String { "https://scratch.mit.edu/projects/\(scratchId)/embed" }
    /// games.tsx thumbUrl.
    var thumbURL: String { "https://cdn2.scratch.mit.edu/get_image/project/\(scratchId)_480x360.png" }

    /// games.tsx GAMES, in upstream's order.
    static let all: [KidsArcadeGame] = [
        KidsArcadeGame(name: "Paper Minecraft", blurb: "Build and explore in 2D", scratchId: 10128407, cat: "Build & Cook"),
        KidsArcadeGame(name: "Miner Cat", blurb: "Dig deep, collect it all", scratchId: 336338957, cat: "Build & Cook"),
        KidsArcadeGame(name: "Burger Maker", blurb: "Stack the tastiest burger", scratchId: 650886217, cat: "Build & Cook"),
        KidsArcadeGame(name: "Appel", blurb: "Jumpy apple platformer", scratchId: 60917032, cat: "Action"),
        KidsArcadeGame(name: "Platformer!", blurb: "Run, jump and bounce", scratchId: 853110869, cat: "Action"),
        KidsArcadeGame(name: "Geometry Dash Wave", blurb: "Ride the wave, dodge spikes", scratchId: 728467856, cat: "Action"),
        KidsArcadeGame(name: "Flappy Bird", blurb: "Flap between the pipes", scratchId: 195385320, cat: "Action"),
        KidsArcadeGame(name: "Crossy Road", blurb: "Hop across safely", scratchId: 230324399, cat: "Action"),
        KidsArcadeGame(name: "Getting Over It", blurb: "Climb up. Don't fall!", scratchId: 389464290, cat: "Action"),
        KidsArcadeGame(name: "Rogue Knight", blurb: "Pixel knight adventure", scratchId: 437336918, cat: "Action"),
        KidsArcadeGame(name: "Pacman Platformer", blurb: "Chomp and jump", scratchId: 273440163, cat: "Action"),
        KidsArcadeGame(name: "Space Shooter", blurb: "Blast through space", scratchId: 562520973, cat: "Action"),
        KidsArcadeGame(name: "Dino Runner", blurb: "The no-internet dinosaur", scratchId: 318868094, cat: "Action"),
        KidsArcadeGame(name: "Dino Game Remastered", blurb: "Jump the cactuses, fancy", scratchId: 339875080, cat: "Action"),
        KidsArcadeGame(name: "Tetris", blurb: "Stack the falling blocks", scratchId: 469540467, cat: "Puzzle"),
        KidsArcadeGame(name: "2048", blurb: "Slide tiles, make big numbers", scratchId: 312722722, cat: "Puzzle"),
        KidsArcadeGame(name: "Mini Pacman", blurb: "Eat dots, dodge ghosts", scratchId: 164237855, cat: "Puzzle"),
        KidsArcadeGame(name: "Connect 4", blurb: "Four in a row wins", scratchId: 235787333, cat: "Puzzle"),
        KidsArcadeGame(name: "Emoji Memory", blurb: "Find the emoji pairs", scratchId: 163456722, cat: "Puzzle"),
        KidsArcadeGame(name: "Maze Game", blurb: "Find your way out", scratchId: 217898739, cat: "Puzzle"),
        KidsArcadeGame(name: "Treasure Hunter", blurb: "A 3D maze adventure", scratchId: 214123473, cat: "Puzzle"),
        KidsArcadeGame(name: "Tower Defense", blurb: "Stop the invaders", scratchId: 411210603, cat: "Puzzle"),
        KidsArcadeGame(name: "Tower Defense 2", blurb: "Even bigger defenses", scratchId: 187139359, cat: "Puzzle"),
        KidsArcadeGame(name: "Math Game", blurb: "Quick math challenges", scratchId: 621467787, cat: "Learning"),
        KidsArcadeGame(name: "Rapid Multiplication", blurb: "Times tables, fast!", scratchId: 196194631, cat: "Learning"),
        KidsArcadeGame(name: "Typing Game", blurb: "Type words like a pro", scratchId: 219477156, cat: "Learning"),
        KidsArcadeGame(name: "Piano", blurb: "Play real songs", scratchId: 409714793, cat: "Learning"),
        KidsArcadeGame(name: "Pixel Art Creator", blurb: "Draw with pixels", scratchId: 744659873, cat: "Learning"),
        KidsArcadeGame(name: "Minecraft Obby", blurb: "Hop the tricky blocks", scratchId: 320275826, cat: "Action"),
        KidsArcadeGame(name: "Pixel Parkour", blurb: "Leap rooftop to rooftop", scratchId: 211393717, cat: "Action"),
        KidsArcadeGame(name: "Parkour Pursuit", blurb: "Run, wall-jump, escape", scratchId: 297231510, cat: "Action"),
        KidsArcadeGame(name: "Sky Ninja", blurb: "Slice through the clouds", scratchId: 234172040, cat: "Action"),
        KidsArcadeGame(name: "Asteroids", blurb: "Zap the space rocks", scratchId: 795338000, cat: "Action"),
        KidsArcadeGame(name: "Frogger", blurb: "Help the frog cross", scratchId: 411129427, cat: "Action"),
        KidsArcadeGame(name: "Jetpack Joyride", blurb: "Blast off and dodge", scratchId: 177334143, cat: "Action"),
        KidsArcadeGame(name: "Snake", blurb: "Eat apples, grow long", scratchId: 407329986, cat: "Puzzle"),
        KidsArcadeGame(name: "Pong", blurb: "The original paddle battle", scratchId: 244698177, cat: "Puzzle"),
        KidsArcadeGame(name: "Breakout", blurb: "Smash all the bricks", scratchId: 580704486, cat: "Puzzle"),
        KidsArcadeGame(name: "Minesweeper", blurb: "Clear the field carefully", scratchId: 199047441, cat: "Puzzle"),
        KidsArcadeGame(name: "Super Tic-Tac-Toe", blurb: "Tic-tac-toe, leveled up", scratchId: 902399095, cat: "Puzzle"),
        KidsArcadeGame(name: "Wordle", blurb: "Guess the secret word", scratchId: 639908378, cat: "Learning"),
        KidsArcadeGame(name: "Solar System Sandbox", blurb: "Build your own planets", scratchId: 1020945768, cat: "Learning"),
        KidsArcadeGame(name: "Lines", blurb: "A calm drawing puzzle", scratchId: 237232045, cat: "Learning"),
        KidsArcadeGame(name: "Planet Clicker", blurb: "Grow a whole planet", scratchId: 377874630, cat: "Clickers"),
        KidsArcadeGame(name: "Cookie Clicker", blurb: "Bake ALL the cookies", scratchId: 930655286, cat: "Clickers"),
        KidsArcadeGame(name: "Money Clicker", blurb: "Tap your way to riches", scratchId: 208974963, cat: "Clickers"),
        KidsArcadeGame(name: "Restaurant Tycoon", blurb: "Run your own restaurant", scratchId: 261028674, cat: "Clickers"),
        KidsArcadeGame(name: "3D Ping Pong", blurb: "Table tennis in 3D", scratchId: 247987287, cat: "Sports & Racing"),
        KidsArcadeGame(name: "3D Tennis", blurb: "Serve and smash", scratchId: 520716879, cat: "Sports & Racing"),
        KidsArcadeGame(name: "Head Soccer", blurb: "Big-head soccer showdown", scratchId: 474230268, cat: "Sports & Racing"),
        KidsArcadeGame(name: "Soccer Pong", blurb: "Soccer meets pong", scratchId: 184355332, cat: "Sports & Racing"),
        KidsArcadeGame(name: "Nitro Racing", blurb: "Pedal to the metal", scratchId: 400349603, cat: "Sports & Racing"),
        KidsArcadeGame(name: "Mini Golf", blurb: "Putt through silly courses", scratchId: 166369590, cat: "Sports & Racing"),
    ]

    /// games.tsx FILTERS.
    static let filters = ["All", "Action", "Puzzle", "Learning", "Clickers", "Sports & Racing", "Build & Cook"]
}

/// kids/play/games.tsx GameArcade: the category pills over a grid of Scratch thumbnails. Choosing a
/// game opens `KidsGameHandoff` in place of upstream's iframe player; the filter is kept while it
/// is open, and closing it puts focus back on the game's card.
struct KidsGameArcade: View {
    @Binding var playing: KidsArcadeGame?
    @State private var filter = "All"
    @FocusState private var focus: Int?

    private static let cardW: CGFloat = BP.px(220)

    private var shown: [KidsArcadeGame] {
        filter == "All" ? KidsArcadeGame.all : KidsArcadeGame.all.filter { $0.cat == filter }
    }

    var body: some View {
        // The arcade stays mounted (hidden, not focusable) under an open game, so its scroll position
        // and lazily built cards are still there when the game closes and focus returns (review 38).
        ZStack {
            arcade
                .opacity(playing == nil ? 1 : 0)
                .disabled(playing != nil)
                .accessibilityHidden(playing != nil)
            if let game = playing {
                KidsGameHandoff(game: game, onBack: { playing = nil })
            }
        }
        .onChange(of: playing) { old, now in
            guard now == nil, let old else { return }
            DispatchQueue.main.async { focus = old.scratchId }
        }
        // (kids device pass) Opening Games removed the Play Zone card under the ring, and tvOS put it
        // on the header's Back: the first game takes it.
        .onAppear {
            guard playing == nil else { return }
            let first = shown.first?.scratchId
            DispatchQueue.main.async { focus = first }
        }
    }

    private var arcade: some View {
        VStack(spacing: BP.px(16)) {
            HStack(spacing: BP.px(8)) {
                ForEach(KidsArcadeGame.filters, id: \.self) { f in
                    let on = f == filter
                    Button(T(f)) { filter = f }
                        .buttonStyle(KidsPillStyle(fill: on ? KidsTheme.sunny : Color.white.opacity(0.2),
                                                   focusedFill: on ? KidsTheme.sunny : Color.white.opacity(0.3),
                                                   ink: on ? KidsTheme.sunnyInk : Color.white,
                                                   height: BP.px(48)))
                }
            }
            .frame(maxWidth: .infinity)
            .focusSection()
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cardW), spacing: BP.px(20)), count: 4), spacing: BP.px(20)) {
                    ForEach(shown) { g in
                        Button { playing = g } label: { card(g) }
                            .buttonStyle(KidsCardStyle(radius: BP.px(22), ring: BP.px(4)))
                            .focused($focus, equals: g.scratchId)
                            .accessibilityLabel(g.name)
                    }
                }
                .padding(.vertical, BP.px(16))
                .frame(maxWidth: .infinity)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    private func card(_ g: KidsArcadeGame) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color(hex: 0xdceef5)
                RemoteImage(url: g.thumbURL)
            }
            .frame(width: Self.cardW, height: Self.cardW * 3 / 4)
            .clipped()
            VStack(alignment: .leading, spacing: BP.px(2)) {
                Text(g.name).font(KidsTheme.font(17, .medium)).foregroundStyle(KidsTheme.sea).lineLimit(1)
                Text(T(g.blurb)).font(KidsTheme.font(12.5, .semibold)).foregroundStyle(KidsTheme.seaMuted).lineLimit(1)
            }
            .padding(.horizontal, BP.px(16)).padding(.vertical, BP.px(12))
            .frame(width: Self.cardW, alignment: .leading)
        }
        .background(.white.opacity(0.95))
    }
}

/// games.tsx GamePlayer, as far as tvOS allows: upstream plays the project in an iframe of
/// scratch.mit.edu. Apple TV has no web view and cannot run Scratch's player natively, so the
/// game's thumbnail sits beside a QR code for the same embed page, to play on a phone, tablet or
/// computer. "Pick another" (upstream's failed-state button) or Back returns to the arcade.
struct KidsGameHandoff: View {
    let game: KidsArcadeGame
    let onBack: () -> Void
    private let qr: UIImage?
    private static var qrCache: [String: UIImage] = [:]
    @FocusState private var pickFocused: Bool

    init(game: KidsArcadeGame, onBack: @escaping () -> Void) {
        self.game = game
        self.onBack = onBack
        // One Core Image pass per game, not per body re-evaluation (review 38).
        if let hit = Self.qrCache[game.embedURL] { self.qr = hit } else {
            let made = QRCode.image(game.embedURL)
            if let made { Self.qrCache[game.embedURL] = made }
            self.qr = made
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: BP.px(32)) {
            VStack(alignment: .leading, spacing: BP.px(12)) {
                HStack(spacing: BP.px(12)) {
                    Text(game.name)
                        .font(KidsTheme.font(24, .medium)).foregroundStyle(.white).lineLimit(1)
                        .shadow(color: Color(hex: 0x001428).opacity(0.5), radius: 10, y: 2)
                    Text(T("on Scratch").uppercased())
                        .font(KidsTheme.font(11, .bold)).tracking(1.3).foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(4))
                        .background(Capsule().fill(.white.opacity(0.2)))
                }
                ZStack {
                    Color(hex: 0x04121e)
                    RemoteImage(url: game.thumbURL)
                }
                .frame(width: BP.px(400), height: BP.px(300))
                .clipShape(RoundedRectangle(cornerRadius: BP.px(12), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: BP.px(12), style: .continuous).stroke(.white.opacity(0.35), lineWidth: BP.px(4)))
                .shadow(color: Color(hex: 0x001428).opacity(0.7), radius: 36, y: 28)
                Text(T(game.blurb)).font(KidsTheme.font(15, .semibold)).foregroundStyle(.white.opacity(0.8))
            }
            VStack(alignment: .leading, spacing: BP.px(14)) {
                VStack(spacing: BP.px(10)) {
                    if let qr {
                        Image(uiImage: qr).interpolation(.none).resizable()
                            .frame(width: BP.px(170), height: BP.px(170))
                    }
                    Text("Scan to play on a phone, tablet or computer")
                        .font(KidsTheme.font(16, .bold)).foregroundStyle(KidsTheme.sea)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: "scratch.mit.edu/projects/\(game.scratchId)")
                        .font(KidsTheme.font(11.5, .semibold)).foregroundStyle(KidsTheme.seaMuted)
                }
                .padding(BP.px(22))
                .frame(width: BP.px(300))
                .background(RoundedRectangle(cornerRadius: BP.px(16), style: .continuous).fill(.white.opacity(0.95)))
                .overlay(RoundedRectangle(cornerRadius: BP.px(16), style: .continuous).stroke(.white.opacity(0.35), lineWidth: BP.px(4)))
                HStack(spacing: BP.px(10)) {
                    KidsArt(doodle: "liloctored").frame(width: BP.px(40), height: BP.px(40))
                    Text("Scratch games need a web browser, and Apple TV doesn't have one.")
                        .font(KidsTheme.font(13.5, .semibold)).foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: BP.px(300), alignment: .leading)
                Button(action: onBack) {
                    HStack(spacing: BP.px(8)) { Image(systemName: "gamecontroller.fill").accessibilityHidden(true); Text("Pick another") }
                }
                .buttonStyle(KidsPillStyle(fill: KidsTheme.sunny, ink: KidsTheme.sunnyInk, height: BP.px(52)))
                .focused($pickFocused)
                .accessibilityIdentifier("kids-game-pick-another")
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { DispatchQueue.main.async { pickFocused = true } }
    }
}
