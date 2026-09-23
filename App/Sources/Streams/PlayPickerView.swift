import SwiftUI

/// Stream picker: the ranked list grouped by quality tier, best cached pick first.
struct PlayPickerView: View {
    let meta: Meta
    let episode: AnyJSON?
    let onPlay: (ScoredStream, StreamsModel.Resolved) -> Void
    @StateObject private var model = StreamsModel()
    @State private var resolving: String?
    @State private var resolveError: String?
    @Environment(\.dismiss) private var dismiss

    private static let tierOrder = ["4K_DV", "4K_HDR", "4K", "1080p_HDR", "1080p", "720p", "SD", "ROUGH"]
    private static let tierLabel: [String: String] = ["4K_DV": "4K Dolby Vision", "4K_HDR": "4K HDR", "4K": "4K", "1080p_HDR": "1080p HDR", "1080p": "1080p", "720p": "720p", "SD": "SD", "ROUGH": "Other"]

    var body: some View {
        ZStack {
            BPAmbientBackground()
            HStack(alignment: .top, spacing: BP.px(40)) {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    Text("Play").font(BP.sans(11, .bold)).foregroundStyle(BP.accent).textCase(.uppercase).tracking(1)
                    Text(meta.name).font(BP.display(30)).foregroundStyle(BP.ink).lineLimit(3)
                    if let ep = episodeLabel { Text(ep).font(BP.sans(16, .semibold)).foregroundStyle(BP.inkMuted) }
                    statusLine
                    if let resolveError { BPNote(text: resolveError, tone: BP.danger) }
                    RemoteImage(url: meta.poster).frame(width: BP.px(177), height: BP.px(265)).clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous)).padding(.top, BP.px(10))
                }
                .frame(width: BP.px(300), alignment: .leading)
                list
            }
            .padding(.horizontal, BP.gutter).padding(.top, BP.px(50))
        }
        .ignoresSafeArea()
        .task { await model.search(meta: meta, episode: episode) }
        .onDisappear { model.cancel() }
    }

    private var episodeLabel: String? {
        guard let s = episode?["season"]?.number, let e = episode?["episode"]?.number else { return nil }
        let name = episode?["name"]?.string
        return "S\(Int(s)) E\(Int(e))" + (name.map { " · \($0)" } ?? "")
    }

    @ViewBuilder private var statusLine: some View {
        switch model.phase {
        case .searching:
            HStack(spacing: BP.px(8)) {
                ProgressView().tint(BP.inkMuted)
                Text(model.progress.total > 0 ? "Asking addons… \(model.progress.settled)/\(model.progress.total)" : "Asking your addons…").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
            }
        case .done:
            Text(model.streams.isEmpty ? (model.addonCount == 0 ? "No stream addons installed. Sign in to Stremio or add addons." : "No streams found.") : "\(model.streams.count) streams from \(model.addonCount) addons")
                .font(BP.sans(14)).foregroundStyle(BP.inkMuted)
        case .failed(let why): BPNote(text: why, tone: BP.danger)
        case .idle: EmptyView()
        }
    }

    private var groups: [(String, [ScoredStream])] {
        Self.tierOrder.compactMap { tier in
            let items = model.streams.filter { $0.tier == tier }
            return items.isEmpty ? nil : (Self.tierLabel[tier] ?? tier, items)
        }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: BP.px(10)) {
                if let best = model.primary {
                    Text("Best pick").font(BP.sans(13, .bold)).foregroundStyle(BP.accent).textCase(.uppercase).tracking(1)
                    row(best, highlight: true)
                }
                ForEach(groups, id: \.0) { title, items in
                    Text(title).font(BP.sans(15, .bold)).foregroundStyle(BP.inkMuted).padding(.top, BP.px(10))
                    ForEach(items) { s in row(s, highlight: false) }
                }
                Color.clear.frame(height: BP.px(60))
            }
            .padding(.vertical, BP.px(10))
        }
        .focusSection()
    }

    private func row(_ s: ScoredStream, highlight: Bool) -> some View {
        Button { Task { await pick(s) } } label: {
            VStack(alignment: .leading, spacing: BP.px(5)) {
                HStack(spacing: BP.px(8)) {
                    ForEach(badges(s), id: \.self) { b in
                        Text(b).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(0.4)
                            .foregroundStyle(b == "Cached" ? BP.canvas : BP.ink)
                            .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2))
                            .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(b == "Cached" ? BP.live : BP.on))
                    }
                    Spacer()
                    Text(s.addonName).font(BP.sans(11, .semibold)).foregroundStyle(BP.inkMuted)
                    if resolving == s.id { ProgressView().tint(BP.inkMuted).scaleEffect(0.7) }
                }
                Text(s.parsedTitle ?? s.title ?? s.name ?? "Stream").font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                HStack(spacing: BP.px(10)) {
                    if let g = s.releaseGroup { Text(g) }
                    if let sz = s.sizeText { Text(sz) }
                    if let seeds = s.seeders, seeds > 0 { Text("\(Int(seeds)) seeders") }
                    if let langs = s.audioLanguages, !langs.isEmpty { Text(langs.prefix(3).joined(separator: ", ")) }
                }
                .font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
            }
            .padding(BP.px(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(highlight ? BP.panel2 : BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(highlight ? BP.accent.opacity(0.6) : BP.edge, lineWidth: 1))
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM))
        .disabled(resolving != nil)
        .accessibilityIdentifier("stream-\(s.index)")
    }

    private func badges(_ s: ScoredStream) -> [String] {
        var out: [String] = []
        if s.isCached { out.append("Cached") }
        if let r = s.resolution, r != "unknown" { out.append(r) }
        if let h = s.hdrFormat { out.append(h) }
        if let c = s.codec, c != "unknown", c != "Other" { out.append(c) }
        if let a = s.audio?.codec, a != "Other" { out.append(a + ((s.audio?.channels ?? 0) >= 6 ? " 5.1" : "")) }
        if s.remux == true { out.append("Remux") }
        if let src = s.source, !["unknown", "other"].contains(src.lowercased()) { out.append(src) }
        return out
    }

    private func pick(_ s: ScoredStream) async {
        resolving = s.id; resolveError = nil
        let r = await model.resolve(s)
        resolving = nil
        if r.ok, r.data != nil {
            onPlay(s, r)
        } else {
            resolveError = "Couldn't get a playable link (\(r.code ?? "unknown")). Try another stream."
        }
    }
}
