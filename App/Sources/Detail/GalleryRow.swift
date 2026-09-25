import SwiftUI

/// bp-gallery-row.tsx: backdrops, posters and logos as tiles; Select opens a lightbox with Left/Right.
struct GalleryRow: View {
    let meta: Meta
    @State private var gallery: Gallery?
    @State private var lightbox: Lightbox?
    struct Gallery: Decodable { var backdrops: [String]; var posters: [String]; var logos: [String] }
    struct Lightbox: Identifiable { var images: [String]; var index: Int; var tall: Bool; var id: String { "\(index)-\(images.count)" } }

    var body: some View {
        Group {
            if let g = gallery, !(g.backdrops.isEmpty && g.posters.isEmpty && g.logos.isEmpty) {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    Text("Gallery").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).padding(.horizontal, BP.gutter).accessibilityAddTraits(.isHeader)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: BP.px(10)) {
                            ForEach(Array(g.backdrops.enumerated()), id: \.offset) { i, url in tile(url, number: i + 1, size: CGSize(width: BP.px(300), height: BP.px(169))) { lightbox = Lightbox(images: g.backdrops, index: i, tall: false) } }
                            ForEach(Array(g.posters.enumerated()), id: \.offset) { i, url in tile(url, number: g.backdrops.count + i + 1, size: CGSize(width: BP.px(113), height: BP.px(169))) { lightbox = Lightbox(images: g.posters, index: i, tall: true) } }
                            ForEach(Array(g.logos.enumerated()), id: \.offset) { i, url in tile(url, number: g.backdrops.count + g.posters.count + i + 1, size: CGSize(width: BP.px(220), height: BP.px(169)), fit: true) { lightbox = Lightbox(images: g.logos, index: i, tall: false) } }
                        }
                        .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(10))
                    }
                    .scrollClipDisabled()
                }
                .focusSection()
            }
        }
        .task(id: meta.id) {
            let p = ProfilesStore.shared.active
            // (device-flow pass 6) The task runs again whenever a cover over the page closes (this
            // row's own lightbox included): a failed re-read (offline, TMDB's cache run out) took
            // the row away from under the ring. It keeps what it drew, as DetailModel.loadExtras does.
            let g: Gallery? = try? await HarborEngine.shared.call("detailRoom.gallery", [meta, p?.id ?? "default", p?.linked ?? true])
            if let g { gallery = g }
        }
        .fullScreenCover(item: $lightbox) { lb in LightboxView(images: lb.images, index: lb.index, tall: lb.tall) }
    }

    private func tile(_ url: String, number: Int, size: CGSize, fit: Bool = false, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            RemoteImage(url: url, contentMode: fit ? .fit : .fill).frame(width: size.width, height: size.height)
                .background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(BP.panel2))
                .clipShape(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous))
        }
        .buttonStyle(BPTileStyle(radius: BP.rXS))
        // bp-gallery-row.tsx aria-label={`${title} ${i + 1}`}: the art alone has no name.
        .accessibilityLabel(Text(verbatim: "\(T("Gallery")) \(number)"))
    }
}

struct LightboxView: View {
    let images: [String]
    @State var index: Int
    let tall: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            BP.void_.ignoresSafeArea()
            if images.indices.contains(index) {
                RemoteImage(url: images[index], contentMode: .fit).padding(BP.px(60)).id(index).transition(.opacity)
            }
            VStack {
                Spacer()
                Text("\(index + 1) / \(images.count) · Left and Right browse · Menu closes").font(BP.sans(13)).foregroundStyle(BP.inkMuted).padding(.bottom, BP.px(30))
            }
            Button { } label: { Color.clear.contentShape(Rectangle()) }.buttonStyle(.plain)
                .onMoveCommand { dir in
                    if dir == .left { index = (index - 1 + images.count) % images.count }
                    else if dir == .right { index = (index + 1) % images.count }
                }
                // The invisible surface is the viewer's only focus stop: upstream's "Image {n}", not an empty button.
                .accessibilityLabel(Text(verbatim: T("Image %lld", index + 1)))
                .accessibilityValue(Text(verbatim: "\(index + 1) / \(images.count)"))
        }
        .animation(.easeInOut(duration: 0.2), value: index)
        .onExitCommand { dismiss() }
        .ignoresSafeArea()
    }
}

/// bp-season-menu.tsx: seasons as a scrollable list with episode counts.
struct SeasonsSheet: View {
    let seasons: [Int]
    let counts: [Int: Int]
    @Binding var season: Int
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Int?

    var body: some View {
        ZStack(alignment: .trailing) {
            BP.void_.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(8)) {
                Text("Seasons").font(BP.sans(19, .bold)).foregroundStyle(BP.ink).accessibilityAddTraits(.isHeader)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: BP.px(6)) {
                        ForEach(seasons, id: \.self) { s in
                            Button { season = s; dismiss() } label: {
                                HStack { Text(s == 0 ? "Specials" : "Season \(s)"); Spacer(); Text("\(counts[s] ?? 0) episodes").foregroundStyle(BP.inkSubtle) }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(BPActionStyle(primary: season == s)).bpSelected(season == s)
                            .focused($focus, equals: s)
                        }
                    }
                }
                Button("Close") { dismiss() }.buttonStyle(BPActionStyle())
            }
            .padding(BP.px(24))
            .frame(width: BP.px(420), alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(BP.panel.opacity(0.98))
            .ignoresSafeArea()
        }
        .onExitCommand { dismiss() }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focus = season } }
    }
}
