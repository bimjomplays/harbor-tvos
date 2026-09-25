import SwiftUI

/// 4-digit keypad (bp-who-is-watching-pin.tsx): 3 tries then a 30 s cooldown per profile,
/// a shake instead of an error string on a miss.
struct PinPadView: View {
    let profile: ProfilesStore.Profile
    let finish: (Bool) -> Void
    /// Curfew lockdown: verify against the parent PIN hash instead of the profile's own.
    var hashOverride: String? = nil
    var title: String? = nil
    @EnvironmentObject private var profiles: ProfilesStore
    @State private var entry = ""
    @State private var shake = 0
    @State private var cooldownUntil: Date?
    @State private var now = Date()
    @FocusState private var keyFocus: String?

    private static var tries: [String: Int] = [:]
    private static var cooldowns: [String: Date] = [:]
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var secondsLeft: Int { max(0, Int((cooldownUntil ?? now).timeIntervalSince(now).rounded(.up))) }

    var body: some View {
        ZStack {
            BP.void_.ignoresSafeArea()
            VStack(spacing: BP.px(22)) {
                Text(title.map { T($0) } ?? T("Enter %@'s PIN", profile.name)).font(BP.display(30)).foregroundStyle(BP.ink)
                Text(secondsLeft > 0 ? "Too many tries. Try again in \(secondsLeft)s." : "Profile is locked. Enter the 4-digit PIN to continue.")
                    .font(BP.sans(15)).foregroundStyle(BP.inkMuted)
                HStack(spacing: BP.px(14)) {
                    ForEach(0..<4, id: \.self) { i in
                        Circle().fill(i < entry.count ? BP.ink : BP.edge2).frame(width: BP.px(14), height: BP.px(14))
                    }
                }
                .modifier(ShakeEffect(shakes: CGFloat(shake)))
                // bp-who-is-watching-pin.tsx: the dots are aria-hidden; a count of four stands in.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(T("PIN")))
                .accessibilityValue(Text(verbatim: "\(entry.count) / 4"))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(BP.px(56)), spacing: BP.px(10)), count: 3), spacing: BP.px(10)) {
                    ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "‹"], id: \.self) { key in
                        Button { tap(key) } label: {
                            Text(key).font(BP.sans(20, .semibold)).foregroundStyle(BP.ink)
                                .frame(width: BP.px(56), height: BP.px(56))
                                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                        .disabled(secondsLeft > 0 && key != "‹")
                        .focused($keyFocus, equals: key)
                        .accessibilityIdentifier("pin-key-\(key)")
                        // bp-who-is-watching-pin.tsx aria-label t("Delete") / t("common.back") (English "Back").
                        .accessibilityLabel(Text(verbatim: key == "⌫" ? T("Delete") : (key == "‹" ? T("Back") : key)))
                    }
                }
            }
        }
        .onAppear {
            cooldownUntil = Self.cooldowns[profile.id]
            // (navigation UI test) bp-who-is-watching-pin autofocuses the first key. Nothing seeded
            // it here: the tile that opened the pad is disabled under it, so the ring went nowhere
            // and Menu reached Who's watching's Back instead of the pad's. Back during a cool-down.
            let cooling: Bool = (cooldownUntil ?? Date()) > Date()
            DispatchQueue.main.async { keyFocus = cooling ? "‹" : "1" }
        }
        .onReceive(timer) { now = $0 }
        // (profiles device pass) bp-who-is-watching-pin re-seeds the first key when `cooling` flips.
        // The cool-down disables every key but Back, so the ring sat on Back when it ended and the
        // viewer's next Select (meaning to type) closed the keypad.
        // (profiles focus pass) Both ways, as upstream's seed effect runs on every `cooling` change
        // (the first key not disabled): the third miss disables the digit under the ring, and tvOS
        // then moved the ring wherever it could, so it goes to Back, the one key left.
        .onChange(of: secondsLeft > 0) { _, cooling in
            keyFocus = cooling ? "‹" : "1"
        }
        .onExitCommand { finish(false) }
    }

    private func tap(_ key: String) {
        switch key {
        case "‹": finish(false)
        case "⌫": if !entry.isEmpty { entry.removeLast() }
        default:
            guard entry.count < 4 else { return }
            entry += key
            if entry.count == 4 { check() }
        }
    }

    private func check() {
        let ok = hashOverride.map { ProfilesStore.hashPin(entry) == $0 } ?? profiles.verifyPin(entry, for: profile)
        if ok {
            Self.tries[profile.id] = 0
            finish(true)
            return
        }
        entry = ""
        let n = (Self.tries[profile.id] ?? 0) + 1
        Self.tries[profile.id] = n
        withAnimation(.default) { shake += 1 }
        if n >= 3 {
            Self.tries[profile.id] = 0
            let until = Date().addingTimeInterval(30)
            Self.cooldowns[profile.id] = until
            cooldownUntil = until
        }
    }
}

struct ShakeEffect: GeometryEffect {
    // (bug pass) Was an Int: the animation's in-between values were truncated to whole shakes, and
    // sin(n * 6π) is 0 for every whole n, so the dots never moved. Fractional values animate.
    var shakes: CGFloat
    var animatableData: CGFloat { get { shakes } set { shakes = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: sin(CGFloat(shakes) * .pi * 6) * 12, y: 0))
    }
}
