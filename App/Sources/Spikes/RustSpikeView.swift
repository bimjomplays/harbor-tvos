import SwiftUI
import HarborFFI

struct RustSpikeView: View {
    @State private var lines: [String] = []
    @State private var passed: Bool?

    var body: some View {
        SpikeResultView(title: "Rust · harbor-core", lines: lines, passed: passed)
            .task { run() }
    }

    private func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
        guard let p else { return "" }
        defer { harbor_string_free(p) }
        return String(cString: p)
    }

    private func run() {
        lines.append("harbor-core version \(take(harbor_core_version()))")
        let streams = """
        [{"addonId":"comet","addonName":"Comet","name":"[TB+] Comet 2160p","title":"Movie.2024.2160p.UHD.BluRay.DV.HDR10.x265-GROUP\\n💾 22.1 GB 👤 120","url":"https://x/1"},
         {"addonId":"torrentio","addonName":"Torrentio","name":"Torrentio 1080p","title":"Movie.2024.1080p.WEB-DL.x264\\n💾 4 GB 👤 5","infoHash":"abc"}]
        """
        let t0 = Date()
        let out = take(harbor_run_pipeline(streams, nil, "{\"activeDebrids\":[\"torbox\"]}"))
        let ms = Date().timeIntervalSince(t0) * 1000
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lines.append("bad JSON: \(out.prefix(200))"); passed = false; return
        }
        if let err = json["error"] { lines.append("error: \(err)"); passed = false; return }
        let picker = json["picker"] as? [String: Any]
        let all = picker?["all"] as? [[String: Any]] ?? []
        let primary = picker?["primary"] as? [String: Any]
        lines.append(String(format: "pipeline: %d ranked in %.2f ms, %d bytes", all.count, ms, out.utf8.count))
        lines.append("primary: \(primary?["resolution"] ?? "?") \(primary?["addonName"] ?? "?") score \(primary?["score"] ?? "?")")
        for s in all { lines.append("  \(s["resolution"] ?? "?") \(s["addonName"] ?? "?") → \(s["score"] ?? "?")") }
        passed = all.count == 2
    }
}
