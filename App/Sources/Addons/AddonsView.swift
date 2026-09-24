import SwiftUI

/// Addons (Stage 5 slice): what is installed on this TV or on the Stremio account,
/// enable/disable, install by URL, remove. All through the engine's addon store.
@MainActor
final class AddonsModel: ObservableObject {
    struct Addon: Decodable, Identifiable {
        struct Manifest: Decodable {
            var id: String?
            var name: String?
            var version: String?
            var description: String?
            var logo: String?
            var resources: [AnyJSON]?
            var types: [String]?
        }
        var transportUrl: String
        var manifest: Manifest
        var installedAt: Double?
        var id: String { transportUrl }
        var name: String { manifest.name ?? manifest.id ?? transportUrl }
        var declaresStreams: Bool {
            (manifest.resources ?? []).contains { r in r.string == "stream" || r["name"]?.string == "stream" }
        }
    }

    @Published private(set) var installed: [Addon] = []
    @Published private(set) var account: [Addon] = []
    @Published private(set) var disabled: Set<String> = []
    @Published private(set) var busy = false
    @Published var error: String?

    func load() async {
        busy = true; defer { busy = false }
        installed = (try? await HarborEngine.shared.call("addonStore.fetchInstalledAddons", [])) ?? []
        let p = ProfilesStore.shared.active
        if let authKey = p.flatMap({ ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }) {
            account = (try? await HarborEngine.shared.call("addons.userAddons", [authKey])) ?? []
        } else {
            account = []
        }
        let dis: [String] = (try? await HarborEngine.shared.callJSON("addonStore.loadDisabledAddons", []).array?.compactMap(\.string)) ?? []
        disabled = Set(dis)
    }

    func setEnabled(_ addon: Addon, _ on: Bool) async {
        _ = try? await HarborEngine.shared.callJSON("addonStore.setAddonEnabled", [.string(addon.transportUrl), .bool(on)])
        HarborEngine.shared.emitEvent("harbor:addons-changed")
        await load()
    }

    func install(url: String) async -> Bool {
        busy = true; defer { busy = false }
        error = nil
        do {
            struct Result: Decodable { var replaced: Bool; var syncedToStremio: Bool }
            let _: Result = try await HarborEngine.shared.call("addonStore.installFromUrl", [url])
            HarborEngine.shared.emitEvent("harbor:addons-changed")
            await load()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func uninstall(_ addon: Addon) async {
        _ = try? await HarborEngine.shared.callJSON("addonStore.uninstallAddon", [.string(addon.manifest.id ?? ""), .string(addon.transportUrl)])
        HarborEngine.shared.emitEvent("harbor:addons-changed")
        await load()
    }
}

struct AddonsView: View {
    @StateObject private var model = AddonsModel()
    @State private var url = ""
    @State private var adding = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            BPAmbientBackground()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(24)) {
                    Text("Addons").font(BP.display(36)).foregroundStyle(BP.ink)
                    section("Add an addon") {
                        BPField(label: "Manifest URL or stremio:// link", placeholder: "https://…/manifest.json", text: $url, keyboard: .URL)
                        HStack(spacing: BP.px(12)) {
                            Button(adding ? "Installing…" : "Install") { Task { adding = true; if await model.install(url: url) { url = "" }; adding = false } }
                                .buttonStyle(BPActionStyle(primary: true)).disabled(adding || url.count < 8)
                            Button("Done") { dismiss() }.buttonStyle(BPActionStyle())
                        }
                        if let e = model.error { BPNote(text: e, tone: BP.danger) }
                        BPNote(text: "Addons installed here stay on this Apple TV. Addons on your Stremio account appear below automatically.")
                    }
                    if !model.account.isEmpty {
                        section("From your Stremio account") { ForEach(model.account) { a in addonRow(a, local: false) } }
                    }
                    section("Installed on this TV") {
                        if model.installed.isEmpty { BPNote(text: model.busy ? "Loading…" : "Nothing installed yet.") }
                        ForEach(model.installed) { a in addonRow(a, local: true) }
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(50))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .ignoresSafeArea()
        .task { await model.load() }
    }

    private func addonRow(_ a: AddonsModel.Addon, local: Bool) -> some View {
        let enabled = !model.disabled.contains(a.transportUrl)
        return HStack(spacing: BP.px(14)) {
            RemoteImage(url: a.manifest.logo, contentMode: .fit).frame(width: BP.px(40), height: BP.px(40)).clipShape(RoundedRectangle(cornerRadius: BP.px(6)))
            VStack(alignment: .leading, spacing: BP.px(2)) {
                HStack(spacing: BP.px(8)) {
                    Text(a.name).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink)
                    if let v = a.manifest.version { Text("v\(v)").font(BP.sans(11)).foregroundStyle(BP.inkSubtle) }
                    if a.declaresStreams { tag("Streams") }
                    if !enabled { tag("Off") }
                }
                Text(a.manifest.description ?? a.transportUrl).font(BP.sans(12)).foregroundStyle(BP.inkMuted).lineLimit(2)
            }
            Spacer()
            Button(enabled ? "Disable" : "Enable") { Task { await model.setEnabled(a, !enabled) } }.buttonStyle(BPActionStyle())
            if local { Button("Remove") { Task { await model.uninstall(a) } }.buttonStyle(BPActionStyle()) }
        }
        .padding(BP.px(12))
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
        .focusSection()
    }

    private func tag(_ t: String) -> some View {
        Text(t).font(BP.sans(9.8, .bold)).textCase(.uppercase).foregroundStyle(BP.canvas)
            .padding(.horizontal, BP.px(5)).padding(.vertical, BP.px(2)).background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.ink))
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Text(T(title)).font(BP.sans(19, .bold)).foregroundStyle(BP.ink)
            content()
        }
        .padding(BP.px(22))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
        .focusSection()
    }
}
