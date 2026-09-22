import SwiftUI

/// Runs EngineSmoke: host boot, runtime.selfTest, a real Cinemeta call through the bundle.
struct EngineHostSpikeView: View {
    @State private var lines: [String] = []
    @State private var passed: Bool?

    var body: some View {
        SpikeResultView(title: "Engine host · selfTest + Cinemeta", lines: lines, passed: passed)
            .task {
                let out = await EngineSmoke.run()
                lines = out
                passed = out.contains { $0.contains("ok=true") } && !out.contains { $0.contains("failed") }
            }
    }
}
