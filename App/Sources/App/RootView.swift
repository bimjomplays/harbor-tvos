import SwiftUI

struct RootView: View {
    @StateObject private var app = AppModel()

    var body: some View {
        ZStack {
            BPAmbientBackground()
            switch app.stage {
            case .boot: BootSplashView()
            case .onboarding: OnboardingView()
            case .whoIsWatching: WhoIsWatchingView()
            case .shell: ShellView()
            }
        }
        .environmentObject(app)
        .environmentObject(app.account)
        .environmentObject(app.profiles)
        .environmentObject(app.sync)
        .environmentObject(SettingsBridge.shared)
        .task { await app.boot() }
        .preferredColorScheme(.dark)
    }
}

/// Boot splash (index-tv.html#boot): #08090a, the mark rising in over 1200 ms, then a spinner.
struct BootSplashView: View {
    @State private var shown = false
    var body: some View {
        ZStack {
            Color(hex: 0x08090a).ignoresSafeArea()
            VStack(spacing: BP.px(28)) {
                HarborMark(size: BP.px(120))
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.92)
                ProgressView().tint(BP.inkMuted).opacity(shown ? 1 : 0)
            }
        }
        .onAppear { withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 1.2)) { shown = true } }
        .accessibilityIdentifier("boot-splash")
    }
}

/// The sail mark from the app icon, drawn as a shape so it scales crisply.
struct HarborMark: View {
    var size: CGFloat
    var body: some View {
        Image("HarborMark")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(BP.ink)
            .frame(width: size, height: size)
    }
}

/// "Harb(o)r" wordmark in Fraunces with the tilted o (bp-top-bar.tsx:320-336).
struct HarborWordmark: View {
    var px: CGFloat = 24
    var body: some View {
        HStack(spacing: 0) {
            Text("Harb")
            Text("o").rotationEffect(.degrees(7), anchor: UnitPoint(x: 0.5, y: 0.65))
            Text("r")
        }
        .font(BP.wordmark(px))
        .foregroundStyle(BP.ink)
    }
}
