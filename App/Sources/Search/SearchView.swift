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

    @ViewBuilder private var statusLine: some View {
        switch model.status {
        case .loading: BPNote(text: "Searching…")
        case .failed(let why): BPNote(text: why, tone: BP.danger)
        case .done where model.rows.isEmpty: BPNote(text: "Nothing found for “\(model.query)”.")
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
                ForEach(model.rows) { row in
                    BPRowView(row: row, onFocus: { spotlight = $0 }, onSelect: { detail = $0 })
                }
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
