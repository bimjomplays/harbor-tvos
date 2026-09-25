import UIKit

/// (player parity pass 2) components/format-badge.tsx's images (src/assets/badges, PNG and WebP),
/// which tools/sync_upstream_assets.sh copies into the bundle's badges/ folder. Each file is read
/// once; a missing one is remembered too, so the picker falls back to the badge's name without
/// asking the bundle again on every redraw.
@MainActor
enum StreamBadgeArt {
    private static var cache: [String: UIImage] = [:]
    private static var missing: Set<String> = []

    static func image(_ file: String) -> UIImage? {
        if let hit = cache[file] { return hit }
        if missing.contains(file) { return nil }
        let name: String = (file as NSString).deletingPathExtension
        let ext: String = (file as NSString).pathExtension
        guard let path = Bundle.main.path(forResource: name, ofType: ext, inDirectory: "badges"),
              let img = UIImage(contentsOfFile: path) else {
            missing.insert(file)
            return nil
        }
        cache[file] = img
        return img
    }
}
