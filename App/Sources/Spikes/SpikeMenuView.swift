import SwiftUI

/// Stage 0 risk tests. Replaced by the real shell in Stage 1.
struct SpikeMenuView: View {
    private var build: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let number = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(number))"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HarborBackground()
                VStack(spacing: 40) {
                    VStack(spacing: 12) {
                        Image(systemName: "sailboat.fill").font(.system(size: 90))
                        Text("Harbor").font(.system(size: 60, weight: .semibold))
                        Text("Stage 0 · Build \(build)")
                            .font(.title3).foregroundStyle(.secondary)
                            .accessibilityIdentifier("build-label")
                    }
                    HStack(spacing: 30) {
                        NavigationLink { EngineSpikeView() } label: { SpikeTile(title: "Engine", subtitle: "Harbor logic in JavaScriptCore", icon: "curlybraces") }
                            .accessibilityIdentifier("spike-engine")
                        NavigationLink { RustSpikeView() } label: { SpikeTile(title: "Rust", subtitle: "harbor-core static library", icon: "gearshape.2") }
                            .accessibilityIdentifier("spike-rust")
                        NavigationLink { PlayerSpikeView() } label: { SpikeTile(title: "Player", subtitle: "mpv test videos", icon: "play.rectangle") }
                            .accessibilityIdentifier("spike-player")
                        NavigationLink { StorageSpikeView() } label: { SpikeTile(title: "Storage", subtitle: "Keychain, prefs, caches", icon: "internaldrive") }
                            .accessibilityIdentifier("spike-storage")
                    }
                    .buttonStyle(.card)
                }
            }
        }
    }
}

struct SpikeTile: View {
    let title: String
    let subtitle: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon).font(.system(size: 44))
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(width: 300, height: 200, alignment: .leading)
        .padding(30)
        .background(Color.white.opacity(0.06))
    }
}

struct HarborBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.086, green: 0.106, blue: 0.149), Color(red: 0.031, green: 0.035, blue: 0.039)],
            startPoint: .top, endPoint: .bottom
        ).ignoresSafeArea()
    }
}

/// Shared result page: a title, lines of output, a pass/fail badge.
struct SpikeResultView: View {
    let title: String
    let lines: [String]
    let passed: Bool?
    var body: some View {
        ZStack {
            HarborBackground()
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(title).font(.largeTitle.weight(.semibold))
                    Spacer()
                    if let passed {
                        Text(passed ? "PASS" : "FAIL")
                            .font(.title2.weight(.bold))
                            .padding(.horizontal, 24).padding(.vertical, 8)
                            .background(passed ? Color.green.opacity(0.35) : Color.red.opacity(0.35))
                            .clipShape(Capsule())
                            .accessibilityIdentifier("spike-status")
                    } else {
                        ProgressView()
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 28, design: .monospaced)).lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("spike-output")
            }
            .padding(80)
        }
    }
}
