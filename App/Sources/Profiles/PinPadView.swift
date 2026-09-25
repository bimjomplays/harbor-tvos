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

    private static var tries: [String: Int] = [:]
    private static var cooldowns: [String: Date] = [:]
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var secondsLeft: Int { max(0, Int((cooldownUntil ?? now).timeIntervalSince(now).rounded(.up))) }

    var body: some View {
        ZStack {
            BP.void_.ignoresSafeArea()
            VStack(spacing: BP.px(22)) {
                Text(title ?? "Enter \(profile.name)'s PIN").font(BP.display(30)).foregroundStyle(BP.ink)
                Text(secondsLeft > 0 ? "Too many tries. Try again in \(secondsLeft)s." : "Profile is locked. Enter the 4-digit PIN to continue.")
                    .font(BP.sans(15)).foregroundStyle(BP.inkMuted)
                HStack(spacing: BP.px(14)) {
                    ForEach(0..<4, id: \.self) { i in
                        Circle().fill(i < entry.count ? BP.ink : BP.edge2).frame(width: BP.px(14), height: BP.px(14))
                    }
                }
                .modifier(ShakeEffect(shakes: CGFloat(shake)))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(BP.px(56)), spacing: BP.px(10)), count: 3), spacing: BP.px(10)) {
                    ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "‹"], id: \.self) { key in
                        Button { tap(key) } label: {
                            Text(key).font(BP.sans(20, .semibold)).foregroundStyle(BP.ink)
                                .frame(width: BP.px(56), height: BP.px(56))
                                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                        .disabled(secondsLeft > 0 && key != "‹")
                        .accessibilityIdentifier("pin-key-\(key)")
                    }
                }
            }
        }
        .onAppear { cooldownUntil = Self.cooldowns[profile.id] }
        .onReceive(timer) { now = $0 }
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
