import Foundation
import Combine
import SwiftUI

/// Per-card marks from the engine (`cards.marks`, bp-card-marks + bp-card-state-marks):
/// the identity chip, watchlist bookmark, watched check and the Top 10 ribbon.
struct CardMarks: Decodable, Equatable {
    var id: String
    var chip: String?
    var bookmark: String?      // topStart | topEnd | bottomEnd | bottomStart
    var watched: String?       // topEnd | bottomEnd
    var top10: String?         // left | right
}

/// One process-wide table keyed by meta id. Screens ask for their visible metas after a load;
/// tiles read it directly, so a mark that changes (watched, bookmarked) updates everywhere.
@MainActor
final class CardMarksStore: ObservableObject {
    static let shared = CardMarksStore()

    @Published private(set) var byId: [String: CardMarks] = [:]
    private var lastMetas: [Meta] = []

    private struct CardMeta: Encodable {
        var id: String; var type: String; var name: String
        var releaseInfo: String?; var releaseDate: String?; var inTheaters: Bool?
        init(_ m: Meta) { id = m.id; type = m.type; name = m.name; releaseInfo = m.releaseInfo; releaseDate = m.releaseDate; inTheaters = m.inTheaters }
    }

    func refresh(_ metas: [Meta]) async {
        guard !Fixtures.active, !metas.isEmpty else { return }
        lastMetas = metas
        let p = ProfilesStore.shared.active
        guard let list: [CardMarks] = try? await HarborEngine.shared.call("cards.marks", [metas.map(CardMeta.init), p?.id ?? "default", p?.linked ?? true]) else { return }
        var next = byId
        for m in list { next[m.id] = m }
        byId = next
    }

    /// Re-read the Stremio library into the watchlist aggregate, then re-mark the last screen.
    func refreshWatchlist() async {
        guard !Fixtures.active else { return }
        let key = ProfilesStore.shared.active.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey }
        _ = try? await HarborEngine.shared.callJSON("cards.refreshWatchlist", [key.map { .string($0) } ?? .null])
        await refresh(lastMetas)
    }

    /// Something local changed (a title finished, a bookmark toggled): recompute the last screen.
    func remark() async { await refresh(lastMetas) }
}

/// The overlay every tile draws (bp-card-state-marks.tsx geometry: 7 px insets, 5 px gaps,
/// 26 px circles, ribbon 27 % of the card width flush with the top edge).
struct CardMarksOverlay: View {
    let marks: CardMarks?
    /// Local fallback for screenshot fixtures and the moment before the engine answers.
    let fallbackChip: String?
    let size: CGSize

    private var chip: String? { marks?.chip ?? fallbackChip }

    var body: some View {
        ZStack(alignment: .topLeading) {
            corner(.topLeading) {
                if let chip { chipView(chip) }
                if marks?.bookmark == "topStart" { circle("bookmark.fill") }
            }
            corner(.topTrailing) {
                if marks?.bookmark == "topEnd" { circle("bookmark.fill") }
                if marks?.watched == "topEnd" { circle("checkmark") }
            }
            corner(.bottomTrailing) {
                if marks?.bookmark == "bottomEnd" { circle("bookmark.fill") }
                if marks?.watched == "bottomEnd" { circle("checkmark") }
            }
            corner(.bottomLeading) {
                if marks?.bookmark == "bottomStart" { circle("bookmark.fill") }
            }
            if let side = marks?.top10, let ribbon = Self.ribbon(side: side) {
                Image(uiImage: ribbon)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: min(max(size.width * 0.27, BP.px(34)), BP.px(72)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side == "left" ? .topLeading : .topTrailing)
                    .padding(.horizontal, BP.px(7))
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func corner<C: View>(_ alignment: Alignment, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: alignment.horizontal == .leading ? .leading : .trailing, spacing: BP.px(5)) { content() }
            .padding(BP.px(7))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private func chipView(_ text: String) -> some View {
        Text(text)
            .font(BP.sans(9.8, .bold)).textCase(.uppercase).tracking(0.5).lineLimit(1)
            .foregroundStyle(BP.canvas)
            .padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(3))
            .background(RoundedRectangle(cornerRadius: BP.px(4), style: .continuous).fill(BP.ink))
            .frame(maxWidth: size.width - BP.px(56), alignment: .leading)
    }

    private func circle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: BP.px(11), weight: .heavy))
            .foregroundStyle(BP.ink)
            .frame(width: BP.px(26), height: BP.px(26))
            .background(Circle().fill(BP.void_.opacity(0.92)))
            .overlay(Circle().strokeBorder(BP.edge2, lineWidth: 1))
    }

    private static var cache: [String: UIImage] = [:]
    static func ribbon(side: String) -> UIImage? {
        let name = side == "left" ? "toptabl" : "toptabr"
        if let hit = cache[name] { return hit }
        guard let path = Bundle.main.path(forResource: name, ofType: "png", inDirectory: "marks"),
              let img = UIImage(contentsOfFile: path) else { return nil }
        cache[name] = img
        return img
    }
}
