import SwiftUI

/// Search room: keyboard on the left, query + results on the right.
struct SearchView: View {
    @StateObject private var model = SearchModel()
    @State private var spotlight: Meta?
    @State private var detail: Meta?

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: BP.px(40)) {
                VStack(alignment: .leading, spacing: BP.px(16)) {
                    queryLine
                    BPKeyboardView(onChar: { model.query += $0 },
                                   onBackspace: { if !model.query.isEmpty { model.query.removeLast() } },
                                   onClear: { model.query = "" })
                    statusLine
                }
                .padding(.leading, BP.gutter)
                .padding(.top, BP.barHeight + BP.px(20))
                .frame(width: BP.px(560), alignment: .leading)
                results
            }
        }
        .onAppear { if let q = Fixtures.query, model.query.isEmpty { model.query = q } }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
        .fullScreenCover(item: $person) { p in PersonView(personId: p.tmdbId ?? 0, name: p.name) }
        .fullScreenCover(item: $channel) { ch in
            PlayerScreen(title: ch.name, subtitle: ch.playlistName, url: URL(string: ch.url) ?? URL(string: "about:blank")!, isLive: true) { _ in channel = nil }
        }
    }

    private var queryLine: some View {
        HStack(spacing: BP.px(8)) {
            Image(systemName: "magnifyingglass").foregroundStyle(BP.inkMuted)
            Text(model.query.isEmpty ? "Search movies, series, anime" : model.query)
                .font(BP.sans(22, .semibold)).foregroundStyle(model.query.isEmpty ? BP.inkSubtle : BP.ink).lineLimit(1)
            Rectangle().fill(BP.ink).frame(width: 2, height: BP.px(26)).opacity(0.8)
            Spacer()
        }
        .frame(height: BP.px(44))
        .accessibilityIdentifier("search-query")
    }

    @State private var channel: SearchModel.Results.LiveTvHit?
    @State private var person: SearchModel.Results.Person?

    @StateObject private var addons = AddonsModel()

    // use-bp-search "Addons you could install": index hits, Select installs (or shows a tick).
    private var addonIndexRow: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Addons you could install").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.trackGap) {
                    ForEach(model.addonHits) { hit in
                        Button {
                            guard !hit.installed, let url = hit.transportUrl else { return }
                            Task { _ = await addons.install(url: url) }
                        } label: {
                            HStack(spacing: BP.px(10)) {
                                RemoteImage(url: hit.logo, contentMode: .fit).frame(width: BP.px(36), height: BP.px(36)).clipShape(RoundedRectangle(cornerRadius: BP.px(8)))
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: BP.px(6)) {
                                        Text(hit.name).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                        if hit.installed { Image(systemName: "checkmark").font(.system(size: BP.px(11), weight: .bold)).foregroundStyle(BP.live) }
                                    }
                                    Text(hit.installed ? "Installed" : (hit.blurb ?? "Select to install")).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                                }
                            }
                            .padding(.horizontal, BP.px(12)).padding(.vertical, BP.px(8))
                            .frame(width: BP.px(280), alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                        .disabled(addons.busy)
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    // bp-search-rows BpChannelCell: a channel from your Live TV sources, Select tunes it.
    private var channelRow: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text("Live TV").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: BP.trackGap) {
                    ForEach(model.channels) { ch in
                        Button { channel = ch } label: {
                            VStack(spacing: BP.px(6)) {
                                RemoteImage(url: ch.logo, contentMode: .fit).frame(width: BP.px(120), height: BP.px(60))
                                Text(ch.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(2).multilineTextAlignment(.center)
                                Text(ch.group ?? ch.playlistName).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                            }
                            .padding(BP.px(10))
                            .frame(width: BP.px(190), height: BP.px(130))
                            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                    }
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    @ViewBuilder private var statusLine: some View {
        switch model.status {
        case .loading: BPNote(text: "Searching…")
        case .failed(let why): BPNote(text: why, tone: BP.danger)
        case .done where model.rows.isEmpty && model.channels.isEmpty: BPNote(text: "Nothing found for “\(model.query)”.")
        default: EmptyView()
        }
    }

    private var results: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: BP.rowGap) {
                Color.clear.frame(height: BP.barHeight + BP.px(20))
                if let top = spotlight ?? model.topMatch {
                    TopMatchPanel(meta: top).padding(.horizontal, BP.gutter)
                }
                if !model.people.isEmpty {
                    VStack(alignment: .leading, spacing: BP.px(10)) {
                        Text("People").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: BP.trackGap) {
                                ForEach(model.people) { person in
                                    Button { if person.tmdbId != nil { self.person = person } } label: {
                                        VStack(spacing: BP.px(8)) {
                                            RemoteImage(url: person.profile).frame(width: BP.px(110), height: BP.px(110)).clipShape(Circle())
                                            Text(person.name).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                            if let k = person.knownFor, !k.isEmpty { Text(k).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1) }
                                        }
                                        .frame(width: BP.px(130))
                                    }
                                    .buttonStyle(BPTileStyle(radius: BP.px(55)))
                                }
                            }
                            .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(14))
                        }
                        .scrollClipDisabled()
                    }
                    .focusSection()
                }
                if !model.channels.isEmpty { channelRow }
                ForEach(model.rows) { row in
                    BPRowView(row: row, onFocus: { spotlight = $0 }, onSelect: { detail = $0 })
                }
                if !model.addonHits.isEmpty { addonIndexRow }
                Color.clear.frame(height: BP.hintHeight + BP.px(40))
            }
        }
        .frame(maxWidth: .infinity)
        .focusSection()
    }
}


/// Top match (use-bp-search.ts slot 1): art on the right, title, facts and overview.
struct TopMatchPanel: View {
    let meta: Meta
    var body: some View {
        HStack(alignment: .top, spacing: BP.px(18)) {
            VStack(alignment: .leading, spacing: BP.px(6)) {
                Text("Top match").font(BP.sans(11, .bold)).foregroundStyle(BP.accent).textCase(.uppercase).tracking(1)
                Text(meta.name).font(BP.display(26)).foregroundStyle(BP.ink).lineLimit(2)
                if !meta.facts.isEmpty { Text(meta.facts).font(BP.sans(13, .medium)).foregroundStyle(BP.inkMuted) }
                Text(meta.description ?? "").font(BP.sans(14)).foregroundStyle(BP.inkMuted).lineLimit(3)
            }
            Spacer(minLength: 0)
            RemoteImage(url: meta.background ?? meta.poster)
                .frame(width: BP.px(200), height: BP.px(112))
                .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
        }
        .padding(BP.px(16))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
        .animation(.easeOut(duration: 0.26), value: meta.id)
    }
}
