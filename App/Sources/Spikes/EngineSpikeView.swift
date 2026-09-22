import SwiftUI

struct EngineSpikeView: View {
    @State private var lines: [String] = []
    @State private var passed: Bool?

    var body: some View {
        SpikeResultView(title: "Engine · JavaScriptCore", lines: lines, passed: passed)
            .task { run() }
    }

    private func run() {
        do {
            let t0 = Date()
            let engine = try HarborEngine()
            let load = Date().timeIntervalSince(t0) * 1000
            lines.append(String(format: "bundle loaded in %.0f ms", load))
            for rounds in [1, 50] {
                let r = try engine.benchmark(rounds: rounds)
                lines.append("rounds=\(rounds): \(r["streams"] ?? 0) streams, kept \(r["kept"] ?? 0), \(r["ms"] ?? 0) ms")
                lines.append("  best: \(r["best"] ?? "?")")
            }
            passed = true
        } catch {
            lines.append("error: \(error)")
            passed = false
        }
    }
}
