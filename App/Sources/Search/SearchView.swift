import SwiftUI

/// Search room: keyboard on the left, query + results on the right.
struct SearchView: View {
    @StateObject private var model = SearchModel()
    @State private var spotlight: Meta?

    var body: some View {
        ZStack(alignment: .topLeading) {
            SpotlightView(meta: spotlight ?? model.topMatch, boxHeight: BP.px(200) + BP.barHeight)
                .opacity(model.rows.isEmpty ? 0 : 1)
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
                Color.clear.frame(height: BP.barHeight + BP.px(200))
                ForEach(model.rows) { row in
                    BPRowView(row: row, onFocus: { spotlight = $0 }, onSelect: { _ in })
                }
                Color.clear.frame(height: BP.hintHeight + BP.px(40))
            }
        }
        .frame(maxWidth: .infinity)
    }
}
