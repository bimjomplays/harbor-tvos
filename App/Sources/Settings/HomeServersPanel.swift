import SwiftUI

/// Settings → Home servers (lib/media-server): Plex through the plex.tv/link PIN, Jellyfin and
/// Emby through address + credentials; each connection can be indexed, disabled or removed.
@MainActor
final class HomeServersModel: ObservableObject {
    struct Connection: Decodable, Identifiable {
        struct Summary: Decodable { var at: Double; var movies: Int; var shows: Int; var episodes: Int }
        struct SyncResult: Decodable { var ok: Bool; var message: String; var at: Double }
        var id: String; var provider: String; var name: String; var origin: String; var enabled: Bool
        var lastSyncAt: Double?; var lastSummary: Summary?; var lastSyncResult: SyncResult?
        var preferredQuality: String?; var refreshInterval: String?
        /// home-servers-tab.tsx "Every… N days" (refreshInterval "custom"), set on the desktop.
        var refreshEveryDays: Double?
    }
    struct Pin: Decodable { var pinId: Int; var code: String; var url: String; var expiresAt: Double }
    struct Poll: Decodable { struct Server: Decodable, Identifiable { var id: String; var name: String; var owned: Bool; var available: Bool; var origin: String }; var kind: String; var servers: [Server]? }
    struct Progress: Decodable { var connectionId: String; var active: Bool; var message: String }

    @Published private(set) var connections: [Connection] = []
    @Published private(set) var pin: Pin?
    @Published private(set) var servers: [Poll.Server] = []
    @Published private(set) var progress: [String: String] = [:]
    @Published private(set) var note: String?
    @Published private(set) var busy = false
    private var pollTask: Task<Void, Never>?
    private var unsubscribe: (() -> Void)?

    deinit { pollTask?.cancel(); unsubscribe?() }

    func load() async {
        if unsubscribe == nil {
            unsubscribe = HarborEngine.shared.onEvent { [weak self] type, detail in
                guard type == "harbor:media-server-sync", let p = detail.flatMap({ try? $0.decode(Progress.self) }) else { return }
                if p.active { self?.progress[p.connectionId] = p.message } else { self?.progress[p.connectionId] = nil; Task { await self?.load() } }
            }
        }
        connections = (try? await HarborEngine.shared.call("homeServers.connections", [])) ?? []
    }

    // Plex: mint a PIN, show it, poll until approved, then let the viewer pick a server.
    func startPlex() async {
        note = nil; servers = []
        do {
            let p: Pin = try await HarborEngine.shared.call("homeServers.plexPinStart", [])
            pin = p
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, !Task.isCancelled, let pin = self.pin else { return }
                    guard let r: Poll = try? await HarborEngine.shared.call("homeServers.plexPinPoll", [pin.pinId]) else { continue }
                    switch r.kind {
                    case "authorized":
                        self.servers = r.servers ?? []
                        if self.servers.isEmpty { self.note = "Plex signed in, but that account has no servers." ; self.pin = nil }
                        return
                    case "expired": self.pin = nil; self.note = "That code expired. Try again."; return
                    default: break
                    }
                }
            }
        } catch { note = "Plex sign-in failed: \(error.localizedDescription)" }
    }

    func addPlex(_ server: Poll.Server) async {
        guard let pin else { return }
        busy = true; defer { busy = false }
        struct Out: Decodable { var id: String }
        if let c: Out = try? await HarborEngine.shared.call("homeServers.plexAdd", [pin.pinId, server.id]) {
            self.pin = nil; servers = []
            await load()
            await sync(c.id)
        } else { note = "Couldn't save that Plex server." }
    }

    func cancelPlex() { pollTask?.cancel(); pin = nil; servers = [] }

    func connect(provider: String, address: String, username: String, password: String) async -> Bool {
        busy = true; defer { busy = false }
        note = nil
        struct Out: Decodable { var id: String }
        do {
            let c: Out = try await HarborEngine.shared.call("homeServers.connect", [provider, address, username, password])
            await load()
            await sync(c.id)
            return true
        } catch {
            note = "\(error)".split(separator: "\n").first.map(String.init)?.replacingOccurrences(of: "Error: ", with: "") ?? "Couldn't connect."
            return false
        }
    }

    func sync(_ id: String) async {
        struct Out: Decodable { var libraries: Int; var itemCount: Int; var removedItems: Int }
        progress[id] = "Connecting…"
        do {
            let o: Out = try await HarborEngine.shared.call("homeServers.sync", [id])
            note = "Indexed \(o.itemCount) items from \(o.libraries) libraries."
        } catch { note = "Sync failed: \("\(error)".split(separator: "\n").first.map(String.init) ?? "")" }
        progress[id] = nil
        await load()
    }

    func remove(_ id: String) async {
        _ = try? await HarborEngine.shared.callJSON("homeServers.remove", [.string(id)])
        await load()
    }

    func toggle(_ c: Connection) async {
        _ = try? await HarborEngine.shared.callJSON("homeServers.update", [.string(c.id), .object(["enabled": .bool(!c.enabled)])])
        await load()
    }

    // home-servers-tab.tsx pickers, as cycling buttons.
    static let qualities: [(String, String)] = [("original", "Original"), ("4k-40", "4K · 40 Mbps"), ("1080p-20", "1080p · 20 Mbps"), ("1080p-12", "1080p · 12 Mbps"), ("720p-4", "720p · 4 Mbps"), ("480p-2", "480p · 2 Mbps"), ("360p-0.7", "360p · 0.7 Mbps")]
    static let intervals: [(String, String)] = [("launch", "Every launch"), ("daily", "Daily"), ("three-days", "Every 3 days"), ("weekly", "Weekly"), ("manual", "Manual")]

    func cycle(_ c: Connection, field: String, options: [(String, String)], current: String?) async {
        let at = options.firstIndex { $0.0 == current } ?? 0
        let next = options[(at + 1) % options.count].0
        _ = try? await HarborEngine.shared.callJSON("homeServers.update", [.string(c.id), .object([field: .string(next)])])
        await load()
    }
}

struct HomeServersPanel: View {
    @StateObject private var model = HomeServersModel()
    @State private var provider = "jellyfin"
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showForm = false
    /// The connection whose Remove is waiting for the viewer's answer.
    @State private var removing: HomeServersModel.Connection?

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            ForEach(model.connections) { c in
                HStack(spacing: BP.px(10)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(c.name)").font(BP.sans(15, .semibold)).foregroundStyle(BP.ink)
                        Text(model.progress[c.id].map { T($0) } ?? summary(c)).font(BP.sans(12)).foregroundStyle(BP.inkMuted).lineLimit(1)
                    }
                    .frame(width: BP.px(420), alignment: .leading)
                    Button(model.progress[c.id] == nil ? "Sync now" : "Syncing…") { Task { await model.sync(c.id) } }.buttonStyle(BPActionStyle()).disabled(model.progress[c.id] != nil)
                    Button(c.enabled ? "Enabled" : "Disabled") { Task { await model.toggle(c) } }.buttonStyle(BPActionStyle(primary: c.enabled))
                    // (settings bug pass) home-servers-tab.tsx: Remove asks first (HomeServerRemoveDialog,
                    // it also drops the cached titles) and is off while that server syncs.
                    Button("Remove") { removing = c }.buttonStyle(BPActionStyle()).disabled(model.progress[c.id] != nil)
                }
                HStack(spacing: BP.px(10)) {
                    Button(T("Quality") + ": " + T(Self.label(HomeServersModel.qualities, c.preferredQuality ?? "original"))) { Task { await model.cycle(c, field: "preferredQuality", options: HomeServersModel.qualities, current: c.preferredQuality) } }.buttonStyle(BPActionStyle())
                    // A desktop "Every… N days" (custom) interval shows as such and cycles on to Manual;
                    // it read as "Every launch" and cycled to Daily.
                    let refreshLabel: String = c.refreshInterval == "custom" ? Self.customDays(c) : T(Self.label(HomeServersModel.intervals, c.refreshInterval ?? "launch"))
                    let refreshAt: String? = c.refreshInterval == "custom" ? "weekly" : c.refreshInterval
                    Button(T("Refresh") + ": " + refreshLabel) { Task { await model.cycle(c, field: "refreshInterval", options: HomeServersModel.intervals, current: refreshAt) } }.buttonStyle(BPActionStyle())
                    if let r = c.lastSyncResult, !r.ok { Text("Last sync failed: \(r.message)").font(BP.sans(12)).foregroundStyle(BP.danger).lineLimit(1) }
                }
                .padding(.bottom, BP.px(6))
            }
            if model.connections.isEmpty && model.pin == nil && !showForm {
                Text("Play from Plex, Jellyfin or Emby on your network; their libraries join the stream picker and the Library.").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
            }
            if let pin = model.pin {
                if model.servers.isEmpty {
                    VStack(alignment: .leading, spacing: BP.px(6)) {
                        Text("On your phone or computer open plex.tv/link and enter").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                        Text(pin.code).font(BP.display(44)).foregroundStyle(BP.ink).tracking(6)
                        HStack(spacing: BP.px(8)) { ProgressView().tint(BP.inkMuted); Text("Waiting for Plex…").font(BP.sans(13)).foregroundStyle(BP.inkSubtle); Button("Cancel") { model.cancelPlex() }.buttonStyle(BPActionStyle()) }
                    }
                } else {
                    Text("Choose a server").font(BP.sans(15, .semibold)).foregroundStyle(BP.ink)
                    ForEach(model.servers) { s in
                        Button("\(s.name)\(s.owned ? "" : " (shared)")\(s.available ? "" : " · offline")") { Task { await model.addPlex(s) } }.buttonStyle(BPActionStyle(primary: s.available)).disabled(model.busy)
                    }
                }
            } else if showForm {
                HStack(spacing: BP.px(8)) {
                    Button("Jellyfin") { provider = "jellyfin" }.buttonStyle(BPActionStyle(primary: provider == "jellyfin"))
                    Button("Emby") { provider = "emby" }.buttonStyle(BPActionStyle(primary: provider == "emby"))
                }
                BPField(label: "Server address", placeholder: "192.168.1.20:8096 or https://media.example.com", text: $address, keyboard: .URL)
                BPField(label: "Username", placeholder: "Username", text: $username)
                BPField(label: "Password", placeholder: "Password", text: $password, secure: true)
                HStack(spacing: BP.px(8)) {
                    Button(model.busy ? "Connecting…" : "Connect") { Task { if await model.connect(provider: provider, address: address, username: username, password: password) { showForm = false; address = ""; username = ""; password = "" } } }
                        .buttonStyle(BPActionStyle(primary: true)).disabled(model.busy || address.count < 3)
                    Button("Cancel") { showForm = false }.buttonStyle(BPActionStyle())
                }
            } else {
                HStack(spacing: BP.px(8)) {
                    Button("Add Plex") { Task { await model.startPlex() } }.buttonStyle(BPActionStyle(primary: true))
                    Button("Add Jellyfin or Emby") { showForm = true }.buttonStyle(BPActionStyle())
                }
            }
            if let n = model.note { BPNote(text: n, tone: n.hasPrefix("Indexed") ? BP.live : BP.danger) }
        }
        .task { await model.load() }
        .alert(removeTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { c in
            Button("Remove server", role: .destructive) { Task { await model.remove(c.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Cached titles from this server will also be removed. Your media on the server will not be changed.")
        }
    }

    private var removeTitle: String { T("Remove %@?", removing?.name ?? "") }

    private static func label(_ options: [(String, String)], _ value: String) -> String {
        options.first(where: { $0.0 == value })?.1 ?? options[0].1
    }

    /// mediaServerSyncDue: `Math.max(1, refreshEveryDays ?? 1)` days.
    private static func customDays(_ c: HomeServersModel.Connection) -> String {
        // RefreshDaysField keeps 1…365; a synced value is bounded before Int() (which traps on huge/NaN).
        let raw: Double = c.refreshEveryDays ?? 1
        let days: Int = raw.isFinite ? Int(min(365, max(1, raw.rounded()))) : 1
        return days == 1 ? "Every day" : "Every \(days) days"
    }

    private func summary(_ c: HomeServersModel.Connection) -> String {
        let kind = c.provider == "plex" ? "Plex" : c.provider == "emby" ? "Emby" : "Jellyfin"
        guard let s = c.lastSummary else { return "\(kind) · \(c.origin) · not indexed yet" }
        return "\(kind) · \(s.movies) movies, \(s.shows) shows, \(s.episodes) episodes · \(Date(timeIntervalSince1970: s.at / 1000).formatted(date: .abbreviated, time: .shortened))"
    }
}
