import SwiftUI

/// bp-score-chips.tsx: provider marks with their values, fetched per title through the engine
/// (use-bp-card-badges gates). `surface` picks the card or detail settings family.
struct ScoreChipsView: View {
    let meta: Meta?
    var surface = "card"
    var limit = 4
    @State private var badges: [Badge] = []
    @State private var loadedFor: String?
    struct Badge: Decodable {
        var kind: String; var source: String?; var value: AnyJSON
        var label: String {
            switch kind {
            case "rating": return (source ?? "imdb").uppercased().replacingOccurrences(of: "IMDB", with: "IMDb")
            case "rt": return "RT"
            case "audience": return "Audience"
            case "metacritic": return "MC"
            case "letterboxd": return "Letterboxd"
            case "mdblist": return "MDBList"
            case "trakt": return "Trakt"
            case "simkl": return "Simkl"
            default: return kind
            }
        }
        var text: String {
            switch kind {
            case "rating": return value.string ?? ""
            case "rt", "audience", "trakt": return "\(Int((value.number ?? 0).rounded()))%"
            case "letterboxd": return String(format: "%.1f", (value.number ?? 0) / 2)
            case "simkl": return String(format: "%.1f", value.number ?? 0)
            default: return "\(Int((value.number ?? 0).rounded()))"
            }
        }
    }

    var body: some View {
        HStack(spacing: BP.px(10)) {
            ForEach(Array(badges.prefix(limit).enumerated()), id: \.offset) { _, b in
                HStack(spacing: BP.px(4)) {
                    Text(b.label).font(BP.sans(9.8, .bold)).foregroundStyle(BP.canvas)
                        .padding(.horizontal, BP.px(5)).padding(.vertical, BP.px(2))
                        .background(RoundedRectangle(cornerRadius: BP.px(4)).fill(BP.ink))
                    Text(b.text).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).monospacedDigit()
                }
            }
        }
        .task(id: meta?.id) {
            guard let meta, loadedFor != meta.id else { return }
            // Focus glides across a rail; wait for it to settle before asking five providers.
            try? await Task.sleep(for: .milliseconds(surface == "detail" ? 0 : 350))
            guard !Task.isCancelled else { return }
            let p = ProfilesStore.shared.active
            let list: [Badge] = (try? await HarborEngine.shared.call("scores.forMeta", [meta, p?.id ?? "default", p?.linked ?? true, surface])) ?? []
            guard !Task.isCancelled else { return }
            badges = list; loadedFor = meta.id
        }
    }
}
