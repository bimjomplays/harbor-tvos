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

    private static func today() -> String { Date().formatted(.iso8601.year().month().day()) }
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
        guard let p, let limit = p.kid?.curfewMinutes, limit > 0 else { profile = nil; locked = false; return }
        profile = p
        var rec = load(p.id)
        if PlaybackState.shared.active, !rec.unlocked, rec.seconds < limit * 60 {
            rec.seconds += 1
            try? Prefs.set(rec, for: Self.key(p.id))
        }
        locked = !rec.unlocked && rec.seconds >= limit * 60
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
            Color(hex: 0x1b1340).ignoresSafeArea()
            if pin, let p = state.profile, let hash = p.kid?.parentPinHash {
                PinPadView(profile: p, finish: { ok in if ok { state.unlock() }; pin = false }, hashOverride: hash, title: "Parent PIN")
            } else {
                VStack(spacing: BP.px(18)) {
                    Text("🐙").font(.system(size: BP.px(90)))
                    Text("Time's up!").font(BP.display(48)).foregroundStyle(BP.ink)
                    Text(state.profile?.kid?.parentPinHash != nil ? "A grown-up can enter the parent PIN to keep watching." : "Ask a grown-up to switch profiles.")
                        .font(BP.sans(18)).foregroundStyle(BP.inkMuted)
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
