import SwiftUI

/// bp-step-tmdb.tsx: "Connect TMDB". Also reused by Settings → Artwork and rows.
///
/// The key is checked against TMDB's configuration endpoint (engine onboarding.checkTmdbKey) and
/// saved only once TMDB accepts it. A refusal and an unreachable TMDB say different things, and
/// only the second offers "Save it anyway". Under the field a live note counts the characters
/// ("{n} of 32 characters", never past the expected length) or explains the skip.
struct TmdbKeyForm: View {
    let done: () -> Void
    let skip: (() -> Void)?
    @EnvironmentObject private var settings: SettingsBridge
    @State private var key = ""
    /// bp-step-tmdb Check: "idle" | "checking" | "rejected" | "unreachable".
    @State private var check = "idle"
    @State private var saveError: String?

    /// bp-step-tmdb MAX / KEY_LEN.
    private static let maxLength = 64
    private static let keyLength = 32

    private var draft: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var busy: Bool { check == "checking" }
    private var alert: Bool { check == "rejected" || check == "unreachable" }

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
                // Dimmed (not disabled) while empty or checking, so the ring never falls off it.
                Button(busy ? T("Checking…") : T("Verify key")) { Task { await verify() } }
                    .buttonStyle(BPActionStyle(primary: true, busy: busy || draft.isEmpty))
                if check == "unreachable" && !draft.isEmpty {
                    Button("Save it anyway") { Task { await save() } }.buttonStyle(BPActionStyle())
                }
                if !settings.slice.tmdbKey.isEmpty {
                    Button("Keep the key I have", action: done).buttonStyle(BPActionStyle())
                } else if let skip {
                    Button("Use Cinemeta instead", action: skip).buttonStyle(BPActionStyle())
                }
            }
            Text(verbatim: noteText).font(BP.sans(14)).foregroundStyle(alert ? BP.danger : BP.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let saveError { BPNote(text: saveError, tone: BP.danger) }
            BPNote(text: "Free, two minutes. Unlocks Trending, In Theaters, Top Rated and every service rail. Get one at themoviedb.org/settings/api.")
        }
        .frame(maxWidth: BP.px(560))
        .onChange(of: key) { _, now in
            // onChange: typing clears the last answer; the draft stops at 64 characters.
            if now.count > Self.maxLength { key = String(now.prefix(Self.maxLength)) }
            if check != "checking" { check = "idle" }
            saveError = nil
        }
    }

    /// bp-step-tmdb note(): the answer first, then the count, then the skip line.
    private var noteText: String {
        if check == "rejected" { return T("TMDB did not accept that key. Check you copied the v3 key, not the read access token.") }
        if check == "unreachable" { return T("Could not reach TMDB from this TV. You can save the key without checking it.") }
        // Never counts past the expected length: "40 of 32 characters" reads as a broken field.
        let n: Int = key.count
        if n > Self.keyLength { return T("%lld characters", n) }
        if n > 0 { return T("%lld of %lld characters", n, Self.keyLength) }
        return T("Skip this and Harbor runs on Cinemeta. You just see fewer rows.")
    }

    private func verify() async {
        let candidate: String = draft
        guard !candidate.isEmpty, !busy else { return }
        check = "checking"
        saveError = nil
        let raw: String? = try? await HarborEngine.shared.call("onboarding.checkTmdbKey", [candidate])
        let answer: String = raw ?? "unreachable"
        // The viewer typed on while TMDB answered: that answer is for another key.
        guard candidate == draft else { check = "idle"; return }
        if answer == "ok" {
            check = "idle"
            await save()
        } else {
            check = answer == "rejected" ? "rejected" : "unreachable"
        }
    }

    private func save() async {
        let value: String = draft
        guard !value.isEmpty else { return }
        do {
            try await settings.patch(["tmdbKey": .string(value)])
            check = "idle"
            done()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
