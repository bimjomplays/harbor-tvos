import SwiftUI

/// bp-list-dialog.tsx: every custom list with a tick when the title is in it; Select toggles.
/// A new list is named with the on-screen keyboard.
struct ListDialogView: View {
    let meta: Meta
    @Environment(\.dismiss) private var dismiss
    @State private var lists: [ListSummary] = []
    @State private var naming = false
    @State private var newName = ""
    @State private var creating = false
    @FocusState private var focus: String?
    struct ListSummary: Decodable, Identifiable { var id: String; var name: String; var count: Int; var contains: Bool }

    var body: some View {
        ZStack(alignment: .trailing) {
            BP.void_.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(10)) {
                Text("Add to list").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).accessibilityAddTraits(.isHeader)
                Text(meta.name).font(BP.sans(13)).foregroundStyle(BP.inkMuted).lineLimit(1)
                if lists.isEmpty && !naming { BPNote(text: "No lists yet") }
                ForEach(lists) { l in
                    Button { Task { await toggle(l) } } label: {
                        HStack { Text(l.name); Spacer(); Text("\(l.count)").foregroundStyle(BP.inkSubtle); if l.contains { Image(systemName: "checkmark").accessibilityHidden(true) } }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(BPActionStyle(primary: l.contains))
                    .focused($focus, equals: l.id)
                    .bpSelected(l.contains)
                }
                if naming {
                    BPField(label: "New list", placeholder: "List name", text: $newName)
                    HStack(spacing: BP.px(8)) {
                        Button("Create") { Task { await create() } }.buttonStyle(BPActionStyle(primary: true, busy: creating)).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        // (detail pass) Both buttons go with the naming row: the ring moves back to "New list"
                        // (or the new list) instead of falling off the dialog.
                        Button("Cancel") { naming = false; newName = ""; focus = "new" }.buttonStyle(BPActionStyle())
                    }
                } else {
                    Button { naming = true } label: { Label("New list", systemImage: "plus") }.buttonStyle(BPActionStyle()).focused($focus, equals: "new")
                }
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(BPActionStyle())
            }
            .padding(BP.px(24))
            .frame(width: BP.px(440), alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(BP.panel.opacity(0.98))
            .ignoresSafeArea()
        }
        .onExitCommand { dismiss() }
        .task { await load(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focus = lists.first?.id ?? "new" } }
    }

    private func load() async {
        lists = (try? await HarborEngine.shared.call("actions.lists", [meta.id])) ?? []
    }

    private func toggle(_ l: ListSummary) async {
        let _: Bool? = try? await HarborEngine.shared.call("actions.toggleList", [l.id, meta]) as Bool
        await load()
    }

    private func create() async {
        // (social pass) One at a time: a double press on Create made two lists of the same name.
        guard !creating else { return }
        creating = true
        defer { creating = false }
        let id: String? = try? await HarborEngine.shared.call("actions.newList", [newName]) as String
        if let id { let _: Bool? = try? await HarborEngine.shared.call("actions.toggleList", [id, meta]) as Bool }
        naming = false; newName = ""
        await load()
        focus = id.flatMap { i in lists.contains(where: { $0.id == i }) ? i : nil } ?? "new"
    }
}

/// bp-rate-dialog.tsx: 1–10 in a row, the current score lit; "Remove rating" when one exists.
struct RateDialogView: View {
    let meta: Meta
    @Environment(\.dismiss) private var dismiss
    @State private var score = 0
    @State private var note: String?
    @FocusState private var focus: Int?
    struct Rating: Decodable { var score: Int; var updatedAt: Double }

    var body: some View {
        ZStack(alignment: .bottom) {
            BP.void_.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(14)) {
                Text("Rate this").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).accessibilityAddTraits(.isHeader)
                Text(meta.name).font(BP.sans(13)).foregroundStyle(BP.inkMuted).lineLimit(1)
                HStack(spacing: BP.px(8)) {
                    ForEach(1...10, id: \.self) { n in
                        Button("\(n)") { Task { await rate(n) } }
                            .buttonStyle(BPActionStyle(primary: n <= score && score > 0))
                            .focused($focus, equals: n)
                            // The filled run of numbers is drawn; the rating given reads as selected.
                            .bpSelected(n == score)
                    }
                }
                .focusSection()
                HStack(spacing: BP.px(8)) {
                    if score > 0 { Button("Remove rating") { Task { await unrate() } }.buttonStyle(BPActionStyle()) }
                    Button("Close") { dismiss() }.buttonStyle(BPActionStyle())
                }
                if let note { BPNote(text: note, tone: BP.inkMuted) }
            }
            .padding(BP.px(24)).padding(.horizontal, BP.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BP.panel.opacity(0.98))
            .ignoresSafeArea()
        }
        .onExitCommand { dismiss() }
        .task {
            let r: Rating? = try? await HarborEngine.shared.call("actions.rating", [meta.id]) as Rating
            score = r?.score ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focus = score > 0 ? score : 8 }
        }
    }

    /// bp-rate-dialog.tsx: a score rates and closes (the Rate cell re-reads it as the dialog goes).
    /// (detail pass) It stayed open; the dialog now closes unless the device-only note has to show.
    private func rate(_ n: Int) async {
        struct Out: Decodable { var score: Int; var synced: Bool }
        if let o: Out = try? await HarborEngine.shared.call("actions.rate", [meta, n]) {
            score = o.score
            if o.synced { dismiss(); return }
            note = "Saved on this device. It syncs to your Harbor account when you sign in."
        }
    }

    /// bp-rate-dialog.tsx "Remove rating": unrate and close. (detail pass) The button vanished under
    /// the ring once the score cleared and the focus fell off the dialog.
    private func unrate() async {
        _ = try? await HarborEngine.shared.callJSON("actions.unrate", [.string(meta.id)])
        score = 0
        dismiss()
    }
}
