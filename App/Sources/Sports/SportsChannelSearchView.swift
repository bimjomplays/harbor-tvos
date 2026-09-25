import SwiftUI

/// bp-sports-broadcast-search.tsx: "Search your channels" over every playlist's sports channels
/// (engine `sports.searchChannels`, searchSportsChannels(index, query, 30)). Each result plays on
/// Select; the square beside it pins the channel for the fixture's league ("Always use for
/// {league}", source-store toggleAttachedChannel), so the picker tries it first next time.
/// Opened from the event page's channel picker and from the official-broadcast list.
struct SportsChannelSearchView: View {
    let game: SportsModel.Game
    /// bp-sports-watch playSearched: the caller closes this cover, clears an attached stream and plays.
    let onPlay: (SportsEventModel.WatchOption) -> Void
    let onClose: () -> Void

    struct Row: Decodable, Identifiable, Equatable {
        var channelId: String; var name: String; var logo: String?; var group: String?; var url: String
        var headers: [String: String]?; var attached: Bool
        var id: String { channelId }
    }
    struct Result: Decodable { var searchable: Bool; var league: String; var leagueLabel: String; var attachedIds: [String]; var rows: [Row] }

    @State private var query = ""
    @State private var result: Result?
    @State private var pinned: Set<String> = []
    @State private var pinning: String?
    @State private var seeded = false
    private enum Seat: Hashable { case field, done, row(String), pin(String) }
    @FocusState private var seat: Seat?

    private var league: String { result?.league ?? game.league }
    private var leagueLabel: String { result?.leagueLabel ?? game.leagueLabel }
    private var rows: [Row] { result?.rows ?? [] }

    var body: some View {
        ZStack {
            BP.void_.opacity(0.86).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(16)) {
                header
                queryRow
                results
            }
            .padding(BP.px(36))
            .frame(width: BP.px(1000), alignment: .leading)
            .frame(maxHeight: BP.px(590))
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: T("Search your channels")))
        .task(id: query) {
            // useDeferredValue: a short settle so every keystroke does not rescan the index.
            if result != nil { try? await Task.sleep(for: .milliseconds(220)) }
            guard !Task.isCancelled else { return }
            let got: Result? = try? await HarborEngine.shared.call("sports.searchChannels", [query, game.league, 30])
            guard !Task.isCancelled else { return }
            guard let got else {
                // (review 19) A failed first read left the spinner up for good: it reads as nothing
                // found (Done and Back still close the panel).
                if result == nil { result = Result(searchable: false, league: game.league, leagueLabel: game.leagueLabel, attachedIds: [], rows: []) }
                return
            }
            result = got
            pinned = Set(got.attachedIds)
        }
        .onAppear {
            // BpSportsBroadcastSearch seeds the name field (fieldRef ?? seedRef).
            guard !seeded else { return }
            seeded = true
            seat = .field
        }
        .onChange(of: query) { _, now in
            // BpKeyboard onChar: the query stops at 40 characters.
            if now.count > 40 { query = String(now.prefix(40)) }
        }
        .onExitCommand { onClose() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: BP.px(14)) {
            Text(verbatim: T("Search your channels")).font(BP.display(24)).foregroundStyle(BP.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: BP.px(10))
            if !league.isEmpty {
                Text(verbatim: T("Always use for %@", leagueLabel))
                    .font(BP.sans(12, .bold)).textCase(.uppercase).tracking(BP.px(1.9))
                    .foregroundStyle(BP.inkSubtle).lineLimit(1)
            }
        }
    }

    private var queryRow: some View {
        HStack(spacing: BP.px(10)) {
            HStack(spacing: BP.px(10)) {
                Image(systemName: "magnifyingglass").font(.system(size: BP.px(16), weight: .semibold))
                    .foregroundStyle(BP.inkSubtle).accessibilityHidden(true)
                TextField(T("Channel name"), text: $query)
                    .font(BP.sans(18, .semibold))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .focused($seat, equals: .field)
                    .accessibilityLabel(Text(verbatim: T("Search your channels")))
            }
            .padding(.horizontal, BP.px(16))
            .frame(height: BP.px(54))
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel2))
            .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(seat == .field ? BP.focusStroke : BP.edge2, lineWidth: 1))
            Button { onClose() } label: { Text(verbatim: T("Done")).padding(.horizontal, BP.px(10)) }
                .buttonStyle(BPActionStyle())
                .focused($seat, equals: .done)
        }
        .focusSection()
    }

    @ViewBuilder private var results: some View {
        if result == nil {
            ProgressView().tint(BP.inkMuted)
        } else if rows.isEmpty {
            let note: String = query.isEmpty ? T("Type a channel name to find it in your playlists.") : T("No channel in your playlists matches that name.")
            Text(verbatim: note).font(BP.sans(15)).foregroundStyle(BP.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: BP.px(8)) {
                    ForEach(rows.uniquedById()) { row in resultRow(row) }
                }
                .padding(.vertical, BP.px(10)).padding(.horizontal, BP.px(14))
            }
            .padding(.horizontal, -BP.px(14))
            .scrollClipDisabled()
            .focusSection()
        }
    }

    private func resultRow(_ row: Row) -> some View {
        let on: Bool = pinned.contains(row.channelId)
        return HStack(spacing: BP.px(8)) {
            Button { play(row) } label: {
                HStack(spacing: BP.px(14)) {
                    logo(row).frame(width: BP.px(44), height: BP.px(44))
                    VStack(alignment: .leading, spacing: BP.px(3)) {
                        Text(verbatim: row.name).font(BP.sans(16, .bold)).foregroundStyle(BP.ink).lineLimit(1)
                        if let g = row.group, !g.isEmpty {
                            Text(verbatim: g).font(BP.sans(12, .semibold)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, BP.px(16))
                .frame(maxWidth: .infinity, minHeight: BP.px(62), alignment: .leading)
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
            }
            .buttonStyle(BPTileStyle(radius: BP.rSM))
            .focused($seat, equals: .row(row.channelId))
            if !league.isEmpty {
                Button { togglePin(row) } label: {
                    Image(systemName: on ? "pin.fill" : "pin")
                        .font(.system(size: BP.px(18), weight: .semibold))
                        .foregroundStyle(on ? BP.ink : BP.inkSubtle)
                        .frame(width: BP.px(62), height: BP.px(62))
                        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(on ? BP.on : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(on ? Color.clear : BP.edge2, lineWidth: 1))
                        // Busy while its write runs: dimmed, never disabled, so the ring stays put.
                        .opacity(pinning == row.channelId ? 0.55 : 1)
                }
                .buttonStyle(BPTileStyle(radius: BP.rSM))
                .focused($seat, equals: .pin(row.channelId))
                .accessibilityLabel(Text(verbatim: T("Always use for %@", leagueLabel)))
                .bpSelected(on)
            }
        }
    }

    @ViewBuilder private func logo(_ row: Row) -> some View {
        if let l = row.logo, !l.isEmpty {
            RemoteImage(url: l, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: BP.px(6), style: .continuous))
        } else {
            Image(systemName: "tv").font(.system(size: BP.px(18), weight: .semibold)).foregroundStyle(BP.inkMuted).accessibilityHidden(true)
        }
    }

    private func play(_ row: Row) {
        let option = SportsEventModel.WatchOption(
            channelId: row.channelId, name: row.name, logo: row.logo, url: row.url, headers: row.headers,
            tier: "search", attached: pinned.contains(row.channelId), label: row.name, copy: row.group ?? "", reasons: [], score: 0)
        onPlay(option)
    }

    private func togglePin(_ row: Row) {
        guard pinning == nil else { return }
        pinning = row.channelId
        let id: String = row.channelId
        let tag: String = league
        Task {
            let on: Bool? = try? await HarborEngine.shared.call("sports.toggleAttachedChannel", [tag, id])
            if let on {
                if on { pinned.insert(id) } else { pinned.remove(id) }
            }
            pinning = nil
        }
    }
}
