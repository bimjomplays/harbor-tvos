import SwiftUI

/// bp-step-tmdb.tsx: "Connect TMDB". Also reused by Settings → Artwork and rows.
struct TmdbKeyForm: View {
    let done: () -> Void
    let skip: (() -> Void)?
    @EnvironmentObject private var settings: SettingsBridge
    @State private var key = ""
    @State private var busy = false
    @State private var note: String?
    @State private var unreachable = false

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            if !settings.slice.tmdbKey.isEmpty && key.isEmpty {
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    Text("TMDB connected").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                    Text("The key is saved on this device only.").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                }
            }
            BPField(label: "TMDB API key, v3 auth", placeholder: "32 characters", text: $key, phone: true)
            HStack(spacing: BP.px(12)) {
                Button(busy ? "Checking…" : "Verify key") { Task { await verify() } }
                    .buttonStyle(BPActionStyle(primary: true)).disabled(busy || key.count < 20)
                if unreachable {
                    Button("Save it anyway") { Task { await save() } }.buttonStyle(BPActionStyle())
                }
                if !settings.slice.tmdbKey.isEmpty {
                    Button("Keep the key I have", action: done).buttonStyle(BPActionStyle())
                } else if let skip {
                    Button("Use Cinemeta instead", action: skip).buttonStyle(BPActionStyle())
                }
            }
            if let note { BPNote(text: note, tone: unreachable ? BP.inkMuted : BP.danger) }
            BPNote(text: "Free, two minutes. Unlocks Trending, In Theaters, Top Rated and every service rail. Get one at themoviedb.org/settings/api.")
        }
        .frame(maxWidth: BP.px(560))
    }

    private func verify() async {
        busy = true; defer { busy = false }
        note = nil; unreachable = false
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("eyJ") {
            note = "That is the API Read Access Token. Harbor needs the shorter API Key (32 letters and numbers) from the same TMDB page."
            return
        }
        if trimmed.count != 32 {
            note = "A TMDB v3 API key is exactly 32 letters and numbers; this one is \(trimmed.count). Check for a missed or extra character."
            return
        }
        let result = await settings.verifyTmdb(key: trimmed)
        if result.ok {
            await save()
        } else {
            unreachable = true
            let why = result.reason.map { "\n\nTMDB said: \($0.prefix(220))" } ?? ""
            note = "TMDB did not accept that key, or could not be reached from this TV. Check you copied the v3 key, not the read access token.\(why)"
        }
    }

    private func save() async {
        do {
            try await settings.patch(["tmdbKey": .string(key.trimmingCharacters(in: .whitespaces))])
            done()
        } catch {
            note = error.localizedDescription
        }
    }
}
