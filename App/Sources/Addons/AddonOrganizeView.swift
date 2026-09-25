import SwiftUI

/// views/addons/organize/page.tsx: the Stremio account's addon order (synced everywhere) and the
/// addons that live only on this TV, each reordered and saved with upstream's checks (validate,
/// re-read for changes made elsewhere, back up, write, read back) by the engine
/// (addonsManager.organize*). Upstream drags rows or uses the up / down / top buttons; on a TV,
/// Select on a row picks it up, Up and Down move it, Select drops it (Back also drops), and the
/// same buttons sit at the end of each row.
struct AddonOrganizeView: View {
    let authKey: String?
    let onClose: () -> Void
    let onSaved: (String) -> Void

    struct Row: Decodable, Identifiable, Equatable { var key: String; var name: String; var host: String; var addonId: String; var logo: String?; var id: String { key } }
    struct Loaded: Decodable { var ok: Bool; var signedIn: Bool; var cloud: [Row]; var device: [Row]; var backups: Int }
    struct Backup: Decodable, Identifiable { var index: Int; var at: Double; var count: Int; var names: [String]; var id: Int { index } }
    struct Notice { var danger: Bool; var text: String; var retry = false; var reload = false }
    enum Section { case cloud, device }

    @State private var loading = true
    @State private var loadError = false
    @State private var signedIn = false
    @State private var baselineCloud: [Row] = []
    @State private var baselineDevice: [Row] = []
    @State private var cloud: [Row] = []
    @State private var device: [Row] = []
    @State private var saving: String?
    @State private var moving = false
    @State private var notice: Notice?
    @State private var grabbed: String?
    @State private var backupsOpen = false
    @State private var backups: [Backup] = []
    /// (bug pass 2) Focus is bound to the row key, not its index, so a picked-up row keeps focus as
    /// it moves; `moved` scrolls the list after it (the focus engine only scrolls on focus changes,
    /// so a row carried past the screen edge used to leave the view behind).
    @FocusState private var focusedRow: String?
    private struct MoveMark: Equatable { var key: String; var tick: Int }
    @State private var moved: MoveMark?

    private var dirty: Bool { cloud != baselineCloud || device != baselineDevice }
    private var locked: Bool { saving != nil || moving }

    var body: some View {
        ZStack {
            BP.canvas.ignoresSafeArea()
            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(24)) {
                    header
                    if loading {
                        ProgressView().tint(BP.inkMuted)
                    } else if loadError {
                        loadErrorPanel
                    } else {
                        HStack(alignment: .top, spacing: BP.px(36)) {
                            VStack(alignment: .leading, spacing: BP.px(24)) {
                                if let n = notice { noticePanel(n).disabled(grabbed != nil) }
                                if signedIn {
                                    section(.cloud, title: T("Your Stremio account"), sub: T("This order syncs to every Stremio app signed into this account."), rows: cloud,
                                            empty: T("No addons are synced to this account yet."), action: nil)
                                    if !device.isEmpty {
                                        section(.device, title: T("On this device only"), sub: T("These live in Harbor on this computer and never touch your account."), rows: device,
                                                empty: nil, action: AnyView(moveAllButton))
                                    }
                                } else {
                                    section(.device, title: T("On this device"), sub: T("Sign in to Stremio to organize the addons synced to your account."), rows: device, empty: nil, action: nil)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            goodToKnow.frame(width: BP.px(440))
                        }
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(50))
            }
            .onChange(of: moved) { _, mark in
                guard let mark else { return }
                withAnimation(BP.easeFast) { proxy.scrollTo(mark.key) }
            }
            }
        }
        .ignoresSafeArea()
        .onExitCommand {
            if grabbed != nil { grabbed = nil } else if backupsOpen { backupsOpen = false } else if !locked { onClose() }
        }
        .task { await load(reset: true) }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center, spacing: BP.px(16)) {
            VStack(alignment: .leading, spacing: BP.px(6)) {
                Text(T("Organize addons")).font(BP.display(30, .medium)).foregroundStyle(BP.ink)
                Text(T("This order drives your catalog rows and the default stream order. A stream priority set in Settings overrides it for streams."))
                    .font(BP.sans(13)).foregroundStyle(BP.inkMuted).lineLimit(2)
            }
            Spacer()
            if signedIn && !loadError {
                Button { backupsOpen.toggle(); if backupsOpen { Task { await loadBackups() } } } label: {
                    Label(backups.isEmpty ? T("Backups") : "\(T("Backups")) · \(backups.count)", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(BPActionStyle(primary: backupsOpen))
            }
            if !loadError {
                Button(T("Cancel")) { onClose() }.buttonStyle(BPActionStyle()).disabled(locked)
                Button(saving.map(stepLabel) ?? T("Save order")) { Task { await save() } }
                    .buttonStyle(BPActionStyle(primary: true, busy: saving != nil)).disabled(!dirty || moving || loading)
            }
        }
        .disabled(grabbed != nil)
        .focusSection()
        .overlay(alignment: .topTrailing) {
            if backupsOpen { backupsPanel.offset(y: BP.px(90)) }
        }
        .zIndex(2)
    }

    private func stepLabel(_ s: String) -> String {
        switch s {
        case "saving": return T("Saving")
        case "verifying": return T("Verifying")
        default: return T("Checking")
        }
    }

    // MARK: sections (organize/section-card.tsx)

    private func section(_ which: Section, title: String, sub: String, rows: [Row], empty: String?, action: AnyView?) -> some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            HStack(alignment: .center, spacing: BP.px(12)) {
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    Text(title).font(BP.display(21, .medium)).foregroundStyle(BP.ink)
                    Text(sub).font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                }
                Spacer()
                if let action { action }
                Text(rows.count == 1 ? T("%lld addon", rows.count) : T("%lld addons", rows.count))
                    .font(BP.sans(12, .semibold)).foregroundStyle(BP.inkMuted)
                    .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(4)).background(Capsule().fill(BP.edge))
            }
            if rows.isEmpty, let empty {
                Text(empty).font(BP.sans(14)).foregroundStyle(BP.inkSubtle).padding(BP.px(16))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge, style: StrokeStyle(lineWidth: 1, dash: [6])))
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                organizeRow(which, row, index: i, count: rows.count)
            }
        }
        .padding(BP.px(22))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
        .focusSection()
    }

    private func organizeRow(_ which: Section, _ row: Row, index i: Int, count: Int) -> some View {
        let isGrabbed = grabbed == row.key
        let frozen = locked || (grabbed != nil && !isGrabbed)
        return HStack(spacing: BP.px(10)) {
            Button {
                withAnimation(BP.easeFast) { grabbed = isGrabbed ? nil : row.key }
            } label: {
                HStack(spacing: BP.px(14)) {
                    Image(systemName: isGrabbed ? "arrow.up.and.down" : "line.3.horizontal").foregroundStyle(isGrabbed ? BP.accent : BP.inkSubtle)
                        .accessibilityLabel(Text(T("Drag to reorder")))
                    Text("\(i + 1)").font(BP.sans(16, .bold)).monospacedDigit().foregroundStyle(BP.inkSubtle).frame(minWidth: BP.px(28))
                    AddonLogoView(url: row.logo, name: row.name, side: BP.px(40))
                    VStack(alignment: .leading, spacing: BP.px(2)) {
                        Text(row.name).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                        Text(row.host).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(isGrabbed ? BP.accent.opacity(0.14) : BP.panel2))
                .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(isGrabbed ? BP.accent.opacity(0.6) : BP.edge, lineWidth: isGrabbed ? 2 : 1))
            }
            .buttonStyle(BPTileStyle(radius: BP.rSM))
            .focused($focusedRow, equals: row.key)
            // A grabbed row (Up/Down move it) reads as selected.
            .bpSelected(isGrabbed)
            .onMoveCommand { dir in
                guard isGrabbed else { return }
                switch dir {
                case .up: move(which, from: i, to: i - 1)
                case .down: move(which, from: i, to: i + 1)
                default: break
                }
            }
            Button { move(which, from: i, to: i - 1) } label: { Image(systemName: "arrow.up") }
                .buttonStyle(BPActionStyle()).disabled(i == 0).accessibilityLabel(T("Move up"))
            Button { move(which, from: i, to: i + 1) } label: { Image(systemName: "arrow.down") }
                .buttonStyle(BPActionStyle()).disabled(i >= count - 1).accessibilityLabel(T("Move down"))
            Button { move(which, from: i, to: 0) } label: { Image(systemName: "chevron.up.2") }
                .buttonStyle(BPActionStyle()).disabled(i == 0).accessibilityLabel(T("Move to top"))
        }
        .disabled(frozen)
    }

    /// reorder.ts moveItem: clamp the target, splice the row out and back in.
    private func move(_ which: Section, from: Int, to: Int) {
        var list = which == .cloud ? cloud : device
        let target = max(0, min(list.count - 1, to))
        guard from >= 0, from < list.count, from != target else { return }
        let item = list.remove(at: from)
        list.insert(item, at: target)
        withAnimation(BP.easeFast) {
            if which == .cloud { cloud = list } else { device = list }
        }
        // (bug pass 2) The ForEach is keyed by row id, so the moved row keeps its focus; say so
        // explicitly for a picked-up row, and bring the row's new place into view.
        // (addons pass) A row sent to either end disables the arrow just pressed (Move up / Move to
        // top at the top, Move down at the bottom), which dropped the focus ring to wherever the
        // focus engine found; it goes to the moved row instead.
        if grabbed == item.key || target == 0 || target == list.count - 1 { focusedRow = item.key }
        moved = MoveMark(key: item.key, tick: (moved?.tick ?? 0) + 1)
    }

    private var moveAllButton: some View {
        Button { Task { await moveAll() } } label: {
            Label(moving ? T("Checking") : T("Move all to account"), systemImage: "icloud.and.arrow.up")
        }
        .buttonStyle(BPActionStyle(busy: moving))
        .disabled(saving != nil || dirty || grabbed != nil)
    }

    // MARK: side panels

    private var goodToKnow: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Label(T("Good to know"), systemImage: "info.circle").font(BP.display(18, .medium)).foregroundStyle(BP.ink)
            ForEach([
                "Number 1 answers first when you press Play, unless Settings has a stream priority.",
                "The order also decides which addon's rows win on your Home screen.",
                "Nothing changes until you press Save. Leaving this page discards edits.",
                "The Backups button at the top keeps your last five orders. One click restores any of them.",
                "Harbor double-checks with Stremio after saving, so a half-written order can't slip through.",
            ], id: \.self) { line in
                Text("• " + T(line)).font(BP.sans(13)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
            BPNote(text: "Press Select on an addon to pick it up, move it with Up and Down, then press Select again to drop it.", tone: BP.inkSubtle)
        }
        .padding(BP.px(20))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
    }

    /// organize/backups-card.tsx.
    private var backupsPanel: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            Text(T("A safety copy of your addon order. One is saved automatically before Harbor writes any change, and you can save one yourself any time. The five most recent are kept."))
                .font(BP.sans(12)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true)
            Button(T("Back up current order")) { Task { await backupNow() } }
                .buttonStyle(BPActionStyle()).disabled(cloud.isEmpty || locked)
            if backups.isEmpty {
                Text(T("No backups yet. Press the button above to save your first one.")).font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
            }
            ForEach(backups) { b in
                HStack(spacing: BP.px(12)) {
                    VStack(alignment: .leading, spacing: BP.px(2)) {
                        Text(Date(timeIntervalSince1970: b.at / 1000).formatted(date: .abbreviated, time: .shortened)).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink)
                        Text(T("%lld addons", b.count) + " · " + namesLine(b.names)).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                    }
                    Spacer()
                    Button(T("Restore")) { Task { await restore(b.index) } }.buttonStyle(BPActionStyle()).disabled(locked)
                }
            }
        }
        .padding(BP.px(18))
        .frame(width: BP.px(520))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.elevated))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge2, lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
        .focusSection()
    }

    /// backups-card.tsx namesLine: three names, then "+N more".
    private func namesLine(_ names: [String]) -> String {
        let first = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? T("%@ +%lld more", first, names.count - 3) : first
    }

    private func noticePanel(_ n: Notice) -> some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text(n.text).font(BP.sans(14)).foregroundStyle(n.danger ? BP.danger : BP.inkMuted).fixedSize(horizontal: false, vertical: true)
            if n.retry || n.reload {
                HStack(spacing: BP.px(10)) {
                    if n.retry { Button(T("Retry")) { Task { await save() } }.buttonStyle(BPActionStyle()) }
                    if n.reload { Button(T("Reload list")) { Task { await load() } }.buttonStyle(BPActionStyle()) }
                }
                .focusSection()
            }
        }
        .padding(BP.px(18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(n.danger ? BP.danger.opacity(0.15) : BP.panel2))
    }

    private var loadErrorPanel: some View {
        VStack(spacing: BP.px(18)) {
            Text(T("Couldn't load your Stremio collection. Nothing can be reordered safely without it.")).font(BP.sans(16)).foregroundStyle(BP.inkMuted).multilineTextAlignment(.center)
            HStack(spacing: BP.px(12)) {
                Button(T("Try again")) { Task { await load() } }.buttonStyle(BPActionStyle(primary: true))
                Button(T("Go back")) { onClose() }.buttonStyle(BPActionStyle())
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity).padding(BP.px(60))
    }

    // MARK: engine

    /// `reset`: a new visit (the backup-before-first-write starts over); Reload / Try again keep it.
    private func load(reset: Bool = false) async {
        loading = true; defer { loading = false }
        notice = nil; grabbed = nil
        guard let r: Loaded = try? await HarborEngine.shared.call("addonsManager.organizeLoad", [authKey, reset]) else { loadError = true; return }
        loadError = !r.ok
        signedIn = r.signedIn
        baselineCloud = r.cloud; cloud = r.cloud
        baselineDevice = r.device; device = r.device
        if backupsOpen || r.backups > 0 { await loadBackups() }
    }

    private func loadBackups() async {
        backups = (try? await HarborEngine.shared.call("addonsManager.organizeBackups", [])) ?? []
    }

    private func save() async {
        guard dirty, saving == nil else { return }
        notice = nil; grabbed = nil
        saving = cloud != baselineCloud ? "checking" : "saving"
        defer { saving = nil }
        struct Saved: Decodable { var ok: Bool; var scope: String?; var toast: String?; var tone: String?; var text: String?; var retry: Bool?; var reload: Bool? }
        let r: Saved? = try? await HarborEngine.shared.call("addonsManager.organizeSave", [cloud.map(\.key), device.map(\.key)])
        guard let r else {
            notice = Notice(danger: true, text: T("Something unexpected went wrong. Nothing may have been written. Retry to re-check."), retry: true)
            return
        }
        if r.ok {
            onSaved(r.toast ?? T("Addon order saved on this device"))
        } else {
            notice = Notice(danger: r.tone != "info", text: r.text ?? "", retry: r.retry ?? false, reload: r.reload ?? false)
            await loadBackups()
        }
    }

    private func moveAll() async {
        guard !locked, !dirty else { return }
        moving = true; defer { moving = false }
        struct Moved: Decodable { var ok: Bool; var text: String; var reload: Bool }
        guard let r: Moved = try? await HarborEngine.shared.call("addonsManager.organizeMoveAll", []), !r.text.isEmpty else { return }
        if r.ok { await load() }
        notice = Notice(danger: !r.ok, text: r.text, reload: r.reload)
        await loadBackups()
    }

    private func backupNow() async {
        struct Out: Decodable { var ok: Bool; var text: String }
        guard let r: Out = try? await HarborEngine.shared.call("addonsManager.organizeBackupNow", [cloud.map(\.key)]), r.ok else { return }
        notice = Notice(danger: false, text: r.text)
        await loadBackups()
    }

    private func restore(_ index: Int) async {
        struct Out: Decodable { var keys: [String]; var text: String }
        guard let r: Out = try? await HarborEngine.shared.call("addonsManager.organizeRestore", [index]) else { return }
        let byKey = Dictionary(uniqueKeysWithValues: baselineCloud.map { ($0.key, $0) })
        cloud = r.keys.compactMap { byKey[$0] }
        backupsOpen = false
        notice = Notice(danger: false, text: r.text)
        // (addons pass) The panel closes under the Restore just pressed: focus goes to the
        // restored list's first row rather than wherever the focus engine lands.
        focusedRow = cloud.first?.key
    }
}
