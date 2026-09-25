import Foundation
import Combine

/// The eleven Anime4K GLSL shaders (src-tauri/src/anime4k.rs), kept in Caches: tvOS gives an app
/// no persistent local storage beyond small data, so a few MB of downloads belong where the system
/// may purge them (bug pass 2; they were in Application Support). A purged set is simply fetched
/// again on next use: `ensure()` downloads whatever is missing, and `paths(for:)` rechecks the
/// files. mpv gets the chain as absolute paths through `glsl-shaders`.
@MainActor
final class Anime4KStore: ObservableObject {
    static let shared = Anime4KStore()

    struct Entry: Decodable { var url: String; var local: String }

    @Published private(set) var installed = false
    @Published private(set) var busy = false
    @Published private(set) var note: String?

    let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("anime4k", isDirectory: true)
    }()

    private init() {
        // (bug pass 2) Builds before this kept the shaders in Application Support: let that copy go.
        let old = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("anime4k", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.path) { try? FileManager.default.removeItem(at: old) }
        installed = Self.complete(in: dir)
    }

    private static func complete(in dir: URL) -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        let present = Set(names)
        let required = ["Anime4K_Clamp_Highlights.glsl", "Anime4K_Restore_CNN_VL.glsl", "Anime4K_Restore_CNN_M.glsl", "Anime4K_Restore_CNN_Soft_VL.glsl",
                        "Anime4K_Restore_CNN_Soft_M.glsl", "Anime4K_Upscale_CNN_x2_VL.glsl", "Anime4K_Upscale_CNN_x2_M.glsl",
                        "Anime4K_Upscale_Denoise_CNN_x2_VL.glsl", "Anime4K_Upscale_Denoise_CNN_x2_M.glsl", "Anime4K_AutoDownscalePre_x2.glsl", "Anime4K_AutoDownscalePre_x4.glsl"]
        return required.allSatisfy { present.contains($0) && ((try? fm.attributesOfItem(atPath: dir.appendingPathComponent($0).path)[.size] as? Int) ?? 0) > 0 }
    }

    /// Download the missing shaders (about 3 MB in total). Safe to call repeatedly.
    func ensure(force: Bool = false) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        note = nil
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let list: [Entry] = try await HarborEngine.shared.call("anime4k.files", [])
            for e in list {
                let dest = dir.appendingPathComponent(e.local)
                if !force, let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int, size > 0 { continue }
                guard let url = URL(string: e.url) else { continue }
                var req = URLRequest(url: url); req.setValue("Harbor", forHTTPHeaderField: "User-Agent")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
                    throw NSError(domain: "anime4k", code: 1, userInfo: [NSLocalizedDescriptionKey: "download \(e.local): HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"])
                }
                try data.write(to: dest, options: .atomic)
            }
            installed = Self.complete(in: dir)
            note = installed ? "Shaders ready." : "Some shaders are still missing."
        } catch {
            note = T("Download failed") + ": " + error.localizedDescription
            installed = Self.complete(in: dir)
        }
    }

    /// Absolute paths for a chain of file names, or nil when any file is missing.
    func paths(for files: [String]) -> [String]? {
        guard installed else { return nil }
        let out = files.map { dir.appendingPathComponent($0).path }
        guard out.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
            // (bug pass 2) Caches were purged since launch: the next ensure() fetches them again.
            installed = false
            return nil
        }
        return out
    }
}
