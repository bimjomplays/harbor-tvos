import SwiftUI

/// components/curfew-guard.tsx: a kid profile's daily allowance (`kid.curfewMinutes`) counts down
/// only while something plays; once spent, a lockdown that only the parent PIN (or a profile
/// switch) can lift. The record lives per profile and per calendar day.
@MainActor
final class CurfewState: ObservableObject {
    static let shared = CurfewState()
    struct Record: Codable { var date: String; var seconds: Int; var unlocked: Bool }
    @Published private(set) var locked = false
    @Published private(set) var profile: ProfilesStore.Profile?
    private var ticker: Task<Void, Never>?

    /// lib/curfew.ts todayKey: the viewer's local calendar day. (bug pass) Was `.iso8601`, whose
    /// format style is pinned to GMT, so the allowance rolled over at UTC midnight (8 pm in New
    /// York): a spent allowance came back that evening and a parent's unlock ran out mid-evening.
    /// Same yyyy-MM-dd spelling, so a record written today still matches when the dates agree.
    private static func today() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private static func key(_ id: String) -> String { "harbor.curfew.v1.\(id)" }

    /// (bug pass 2) The record is a Swift-only Prefs key (a Codable struct, not an engine string),
    /// so engine/profilesRoom.ts PROFILE_KEY_PREFIXES can't reach it: ProfilesStore drops it when a
    /// profile is deleted here or dropped by a roster sync.
    static func purge(profileId id: String) {
        Prefs.remove(key(id))
    }

    private func load(_ id: String) -> Record {
        let r = Prefs.get(Record.self, for: Self.key(id))
        if let r, r.date == Self.today() { return r }
        return Record(date: Self.today(), seconds: 0, unlocked: false)
    }

    func start() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    private func tick() {
        let p = ProfilesStore.shared.active
        // (bug pass) Publish only on a change: RootView observes this object, and assigning the same
        // values every second re-rendered the root (and every observer) once a second for everyone.
        guard let p, let limit = p.kid?.curfewMinutes, limit > 0 else {
            if profile != nil { profile = nil }
            if locked { locked = false }
            return
        }
        if profile != p { profile = p }
        var rec = load(p.id)
        if PlaybackState.shared.active, !rec.unlocked, rec.seconds < limit * 60 {
            rec.seconds += 1
            try? Prefs.set(rec, for: Self.key(p.id))
        }
        let now = !rec.unlocked && rec.seconds >= limit * 60
        if locked != now { locked = now }
    }

    /// The parent PIN was entered: the rest of today is free.
    func unlock() {
        guard let p = profile else { return }
        var rec = load(p.id); rec.unlocked = true
        try? Prefs.set(rec, for: Self.key(p.id))
        locked = false
    }
}

struct CurfewLockView: View {
    @ObservedObject var state: CurfewState
    @EnvironmentObject private var app: AppModel
    @State private var pin = false

    var body: some View {
        ZStack {
            // (kids device pass) curfew-guard.tsx: the sky-to-sea gradient with white copy. The lock
            // drew the theme's ink on a fixed dark purple, so under a light theme (MinUI, Kawaii,
            // which a kid profile can carry) "Time's up!" was dark on dark and could not be read.
            KidsSeaBackdrop(bubbles: [8, 22, 38, 56, 70, 84, 93], bubbleStep: 3)
            if pin, let p = state.profile, let hash = p.kid?.parentPinHash {
                PinPadView(profile: p, finish: { ok in if ok { state.unlock() }; pin = false }, hashOverride: hash, title: "Parent PIN")
            } else {
                VStack(spacing: BP.px(18)) {
                    // (device-flow pass 7) curfew-guard.tsx: the Harbor mark (h-24, white), "Time's
                    // up!", then the sailing-away line every kid gets, then the PIN hint or "Ask a
                    // grown-up". The TV drew an octopus emoji and skipped the middle line.
                    Image("HarborMark").resizable().renderingMode(.template).scaledToFit()
                        .foregroundStyle(.white)
                        .frame(width: BP.px(96), height: BP.px(96))
                        .accessibilityHidden(true)
                    Text("Time's up!").font(BP.display(48)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 3)
                    Text(T("The ship is sailing away. Thanks for watching with Harbor, it's time to listen to your grown-ups."))
                        .font(BP.sans(18, .medium)).foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center).frame(maxWidth: BP.px(460)).fixedSize(horizontal: false, vertical: true)
                    Text(T(state.profile?.kid?.parentPinHash != nil ? "A grown-up can enter the parent PIN to keep watching." : "Ask a grown-up to switch profiles."))
                        .font(BP.sans(14)).foregroundStyle(.white.opacity(0.8))
                    HStack(spacing: BP.px(12)) {
                        if state.profile?.kid?.parentPinHash != nil { Button("Enter parent PIN") { pin = true }.buttonStyle(BPActionStyle(primary: true)) }
                        Button("Switch profile") { app.stage = .whoIsWatching }.buttonStyle(BPActionStyle())
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}
