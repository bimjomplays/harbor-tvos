import SwiftUI

/// epg-match-modal.tsx: when a channel's tvg-id is wrong (or missing), the viewer picks its guide
/// channel by hand. The search starts from the channel's own name; any word found in the guide
/// channel id or its first programme title matches; 120 results at most. The pick is stored by
/// lib/iptv/epg-map.ts and the resolver honours it first, so the guide lane and now/next follow.
struct EpgMatchView: View {
    @ObservedObject var model: LiveModel
    let channel: LiveModel.Channel
    let dismiss: () -> Void

    @State private var query = ""
    @State private var list: LiveModel.EpgMatchList?
    @State private var seeded = false
    @State private var fetchedQuery: String?
    @State private var busy = false
    /// (device-flow pass 4) The first read failed. Upstream's list is in memory; here it is an
    /// engine read over the whole guide, and until it answered (or when it failed) the page was a
    /// bare field over nothing, with no sign that anything was happening.
    @State private var failed = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            BP.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(14)) {
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    Text("Match EPG channel").font(BP.display(32)).foregroundStyle(BP.ink)
                    Text(channel.name).font(BP.sans(15)).foregroundStyle(BP.inkMuted).lineLimit(1)
                }
                HStack(alignment: .bottom, spacing: BP.px(12)) {
                    BPField(label: "Search", placeholder: placeholder, text: $query)
                        .frame(maxWidth: BP.px(620))
                    if list?.current != nil {
                        Button("Clear match") { assign(nil) }
                            .buttonStyle(BPActionStyle(busy: busy))
                    }
                    Button("Close") { dismiss() }.buttonStyle(BPActionStyle())
                }
                .focusSection()
                results
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(20))
        }
        .task(id: query) { await search() }
    }

    private var placeholder: String {
        guard let total = list?.total else { return "Search EPG channels" }
        return T("Search %@ EPG channels", total.formatted())
    }

    private var results: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: BP.px(6)) {
                ForEach(list?.entries ?? []) { e in
                    row(e)
                }
                if let list, list.entries.isEmpty {
                    BPNote(text: "No EPG channels match. This playlist's EPG source may be empty.", tone: BP.inkSubtle)
                        .padding(.vertical, BP.px(24))
                } else if list == nil {
                    if failed {
                        BPNote(text: "No EPG channels match. This playlist's EPG source may be empty.", tone: BP.inkSubtle)
                            .padding(.vertical, BP.px(24))
                    } else {
                        ProgressView().tint(BP.inkMuted).padding(.vertical, BP.px(24))
                    }
                }
            }
            .padding(.vertical, BP.px(8)).padding(.bottom, BP.hintHeight + BP.px(40))
        }
        .focusSection()
    }

    private func row(_ e: LiveModel.EpgMatchEntry) -> some View {
        let matched = list?.current == e.id
        return Button { assign(e.id) } label: {
            HStack(spacing: BP.px(12)) {
                Image(systemName: "link")
                    .font(.system(size: BP.px(13), weight: .bold))
                    .foregroundStyle(BP.inkSubtle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BP.px(2)) {
                    Text(e.id).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                    if !e.sample.isEmpty {
                        Text(e.sample).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if matched {
                    Text("Matched").textCase(.uppercase).font(BP.sans(11, .bold)).foregroundStyle(BP.accent)
                }
            }
            .padding(.horizontal, BP.px(16)).padding(.vertical, BP.px(10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(matched ? BP.on : BP.panel2))
            .opacity(busy ? 0.6 : 1)
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM))
    }

    /// The first call seeds the field with the channel's name; later edits search after a short pause.
    private func search() async {
        if seeded {
            guard query != fetchedQuery else { return }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
        }
        let asked: String? = seeded ? query : nil
        guard let out = await model.epgCandidates(for: channel, query: asked) else {
            if !Task.isCancelled, list == nil { failed = true }
            return
        }
        if Task.isCancelled { return }
        fetchedQuery = out.query
        list = out
        if !seeded {
            seeded = true
            query = out.query
        }
    }

    private func assign(_ tvgId: String?) {
        // (focus pass 2) Re-entry guard instead of .disabled(busy): a disabled row drops the ring.
        guard !busy else { return }
        busy = true
        Task {
            await model.setEpgMatch(channel, tvgId: tvgId)
            busy = false
            dismiss()
        }
    }
}
