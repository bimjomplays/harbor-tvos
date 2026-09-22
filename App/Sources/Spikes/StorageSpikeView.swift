import SwiftUI

struct StorageSpikeView: View {
    @State private var lines: [String] = []
    @State private var passed: Bool?

    var body: some View {
        SpikeResultView(title: "Storage · Keychain / Prefs / Caches", lines: lines, passed: passed)
            .task { run() }
    }

    private func run() {
        var ok = true
        let stamp = ISO8601DateFormatter().string(from: Date())
        // What survived from the last launch tells us whether tvOS purged anything.
        lines.append("previous run: keychain=\(SecretStore.get("harbor.auth.spike") ?? "none") prefs=\(Prefs.get(String.self, for: "harbor.active-profile") ?? "none") cache=\(CacheStore.shared.get(String.self, for: "spike.stamp") ?? "none")")
        lines.append("cache folder empty at launch: \(CacheStore.shared.isEmpty)")
        do {
            try SecretStore.set(stamp, for: "harbor.auth.spike")
            try Prefs.set(stamp, for: "harbor.active-profile")
            try CacheStore.shared.set(stamp, for: "spike.stamp")
            try KeyValueStore.shared.set("{\"big\":\"\(String(repeating: "x", count: 200_000))\"}", for: "harbor.library.snapshot")
        } catch { lines.append("write error: \(error)"); ok = false }
        ok = ok && SecretStore.get("harbor.auth.spike") == stamp
        ok = ok && Prefs.get(String.self, for: "harbor.active-profile") == stamp
        ok = ok && CacheStore.shared.get(String.self, for: "spike.stamp") == stamp
        ok = ok && (KeyValueStore.shared.get("harbor.library.snapshot")?.count ?? 0) > 200_000
        lines.append("routing: auth→\(KeyValueStore.tier(for: "harbor.auth.x")) profiles→\(KeyValueStore.tier(for: "harbor.profiles.v1")) library→\(KeyValueStore.tier(for: "harbor.library.snapshot"))")
        lines.append("prefs used: \(Prefs.usedBytes()) B of \(Prefs.budgetBytes) B budget")
        lines.append("caches used: \(CacheStore.shared.usedBytes()) B")
        lines.append("wrote stamp \(stamp)")
        passed = ok
    }
}
