import SwiftUI

/// bp-hero-manga.tsx (and the desktop's anime-hero/hero-manga-adaptation.tsx): on an anime's page,
/// the manga it adapts, from AniList relations (lib/manga/anime-adaptation resolveAnimeSourceReading).
/// Select searches the active manga source for that title and opens the first hit's detail page.
/// A light novel ("Read the eBook", Stage 13) opens its AniList entry on the eBook detail page,
/// which looks the book up in the eBook sources; it shows while the eBook tab is on.
@MainActor
struct MangaHeroEntry: View {
    let meta: Meta
    @State private var source: Source?
    @State private var open: MangaOpen?
    @State private var openEBook: EBookOpen?
    @State private var busy = false
    @State private var missing = false
    @ObservedObject private var settings = SettingsBridge.shared
    @AppStorage(EBookGate.key) private var ebookOn = false

    struct Source: Decodable, Equatable { var kind: String; var title: String; var poster: String?; var anilistId: Int }

    /// Manga needs the manga reader on; a light novel needs the eBook tab.
    private func shown(_ s: Source) -> Bool { s.kind == "ebook" ? ebookOn : (s.kind == "manga" && settings.mangaOn) }

    var body: some View {
        Group {
            if let s = source, shown(s) {
                HStack(spacing: BP.px(12)) {
                    Button { Task { if s.kind == "ebook" { await openBook(s) } else { await openManga(s) } } } label: {
                        HStack(spacing: BP.px(10)) {
                            RemoteImage(url: s.poster)
                                .frame(width: BP.px(36), height: BP.px(54))
                                .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.kind == "ebook" ? "Read the eBook" : "Read the Manga").font(BP.sans(10, .bold)).textCase(.uppercase).tracking(1.4).foregroundStyle(BP.accent)
                                Text(s.title).font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                    .frame(maxWidth: BP.px(260), alignment: .leading)
                            }
                            if busy { ProgressView().tint(BP.inkMuted) }
                        }
                        .padding(.horizontal, BP.px(10)).padding(.vertical, BP.px(8))
                        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
                    }
                    .buttonStyle(BPTileStyle(radius: BP.rMD))
                    .accessibilityLabel(T(s.kind == "ebook" ? "Read the eBook" : "Read the Manga") + " " + s.title)
                    if missing { BPNote(text: "Your manga source does not have this title.", tone: BP.inkSubtle) }
                }
                .focusSection()
            }
        }
        .task(id: meta.id) {
            source = nil
            source = try? await HarborEngine.shared.call("manga.animeSource", [meta.id, meta.name])
        }
        .fullScreenCover(item: $open) { o in MangaDetailView(mangaId: o.id) }
        .fullScreenCover(item: $openEBook) { o in EBookDetailView(open: o) }
    }

    /// hero-manga-adaptation open() for kind "ebook": the AniList entry's eBook id.
    @MainActor private func openBook(_ s: Source) async {
        guard !busy else { return }
        busy = true
        let id: String = (try? await HarborEngine.shared.call("ebook.anilistEBookId", [s.anilistId])) ?? "anilist:\(s.anilistId)"
        busy = false
        openEBook = EBookOpen(id: id)
    }

    @MainActor private func openManga(_ s: Source) async {
        guard !busy else { return }
        busy = true
        missing = false
        let id: String? = try? await HarborEngine.shared.call("manga.firstByTitle", [s.title])
        busy = false
        if let id { open = MangaOpen(id: id) } else { missing = true }
    }
}
