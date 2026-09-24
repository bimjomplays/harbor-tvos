import SwiftUI
import UIKit

/// use-bp-sections.ts: the Home bands that own the backdrop (`owns: "band"`). While focus sits in
/// one, bp-home fades the spotlight out and BpBandIdentity speaks for the band instead; bp-ambient
/// paints the band's own layers (a still, the services wash, the stage mosaic) and suppresses the
/// focused card's art. Card-owned bands (resume, catalog, more) keep the spotlight.
struct HomeBand: Equatable {
    enum Id: String { case live, services, collections, addons }
    var id: Id
    /// BpBandArt.key: one per focused cell (a service, an addon, a collection, a channel).
    var key: String
    /// BpBandArt.title / .line: the focused cell's own words (never translated upstream).
    var title: String?
    var line: String?
    /// BpBandArt.src for a `still` band (collections, live).
    var still: String?
    /// BpBandArt.posters for a `mosaic` band (services, addons).
    var posters: [String] = []
    /// The service's brand hex (services `wash`).
    var tint: String?
    /// logoScale "bug": the small mark beside the eyebrow (an addon's icon, a channel logo).
    var bug: String?

    // BP_BANDS copy.
    var eyebrow: String {
        switch id {
        case .live: return "Live"
        case .services: return "Streaming"
        case .collections: return "Collections"
        case .addons: return "Installed"
        }
    }
    var bandTitle: String {
        switch id {
        case .live: return "On right now"
        case .services: return "Your services"
        case .collections: return "Every saga, in order"
        case .addons: return "Your addons"
        }
    }
    var bandLine: String {
        switch id {
        case .live: return "Your channels, playing this minute."
        case .services: return "Straight into the apps you already pay for."
        case .collections: return "Whole runs gathered so nothing arrives out of sequence."
        case .addons: return "What each addon is actually serving up right now."
        }
    }
    var mosaic: Bool { id == .services || id == .addons }

    /// bp-ambient MOSAIC_MIN: the band mosaic paints from fourteen posters up.
    static let mosaicMin = 14
    /// use-bp-sections BAND_SETTLE_MS: holding Down through five bands settles once.
    static let settle: Duration = .milliseconds(180)

    /// The rail row keys that belong to a band-owned band (live is the lead row, not a rail row).
    static func band(forRow key: String) -> Id? {
        switch key {
        case "services": return .services
        case "addons": return .addons
        case "collections": return .collections
        default: return nil
        }
    }

    /// The band record for a focused tile of a band row (bp-service-row / bp-addon-row /
    /// bp-collection-card recordFor).
    static func forTile(_ meta: Meta, in id: Id) -> HomeBand {
        switch id {
        case .services:
            return HomeBand(id: .services, key: meta.id, title: meta.name, line: nil, still: nil, tint: meta.providerBadge?.tint)
        case .addons:
            let logo = meta.providerBadge?.logo ?? ""
            return HomeBand(id: .addons, key: meta.id, title: meta.name, line: nil, still: nil, bug: logo.isEmpty ? nil : logo)
        case .collections:
            return HomeBand(id: .collections, key: meta.id, title: meta.name, line: meta.description, still: meta.background)
        case .live:
            return HomeBand(id: .live, key: meta.id, title: meta.name)
        }
    }

    /// bp-live-band-art.ts bpLiveBandArt: the airing title (else the channel), "Started at {time}"
    /// (else the group, else "Live"), the channel logo as the bug.
    @MainActor static func forChannel(_ c: LiveRowModel.Cell) -> HomeBand {
        let line = c.now.map { "Started at \(LiveChannelRow.time($0.startMs))" } ?? (c.channel.group ?? "Live")
        let logo = c.channel.logo ?? ""
        return HomeBand(id: .live, key: "iptv:\(c.playlistId):\(c.channel.id)", title: c.now?.title ?? c.channel.name, line: line,
                        still: nil, bug: logo.isEmpty ? nil : logo)
    }
}

/// bp-ambient.tsx for a band that owns the backdrop: void, the services wash in the brand hue, the
/// stage mosaic (bp-mosaic variant "stage", 32 %) when fourteen posters are in, a still in the art
/// envelope (the right 76 %, feathered on the lead edge), under the same scrims as title art.
struct HomeBandBackdrop: View {
    let band: HomeBand

    var body: some View {
        ZStack {
            BP.void_
            if let hex = band.tint, let tint = Color(css: hex) {
                RadialGradient(colors: [tint.opacity(0.36), tint.opacity(0.1), .clear], center: .topTrailing, startRadius: 0, endRadius: 1500)
            }
            if band.mosaic, band.posters.count >= HomeBand.mosaicMin, SettingsBridge.shared.slice.bigPictureMosaic ?? true {
                BPMosaicView(posters: band.posters, stage: true).opacity(0.32).id(band.key).transition(.opacity)
            }
            if let still = band.still, !still.isEmpty {
                GeometryReader { g in
                    RemoteImage(url: still)
                        .frame(width: g.size.width * 0.76, height: g.size.height)
                        .clipped()
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.5), location: 0.17),
                                                     .init(color: .black, location: 0.38)], startPoint: .leading, endPoint: .trailing))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .id(still)
                .transition(.opacity)
            }
            LinearGradient(colors: [BP.void_.opacity(0.82), BP.void_.opacity(0.52), BP.void_.opacity(0.16), .clear],
                           startPoint: .leading, endPoint: .init(x: 0.7, y: 0.5))
            LinearGradient(colors: [.clear, BP.void_.opacity(0.3), BP.void_.opacity(0.88), BP.void_], startPoint: .init(x: 0.5, y: 0.35), endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.26), value: band.posters.count >= HomeBand.mosaicMin)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// bp-section.tsx BpBandIdentity: in the hero box, bottom-anchored like the spotlight copy: the
/// bug and the band eyebrow, a short rule, the subject (the focused cell's title, else the band
/// title) and the line (the cell's, else the band's).
struct BandIdentityView: View {
    let band: HomeBand
    var boxHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: BP.px(9)) {
                    if let bug = band.bug { BandMark(url: bug, height: BP.px(20), maxWidth: BP.px(80)) }
                    Text(band.eyebrow).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(BP.px(1.8)).foregroundStyle(BP.inkSubtle)
                }
                Rectangle().fill(BP.edge2).frame(width: BP.px(46), height: 1).padding(.top, BP.px(6))
                Text(band.title ?? band.bandTitle)
                    .font(BP.display(34.6)).foregroundStyle(BP.ink).lineLimit(2)
                    .shadow(color: .black.opacity(0.6), radius: 16, y: 3)
                    .padding(.top, BP.px(10))
                Text(band.line ?? band.bandLine)
                    .font(BP.sans(12.5)).foregroundStyle(BP.inkMuted).lineSpacing(BP.px(5)).lineLimit(2)
                    .frame(maxWidth: BP.px(500), alignment: .leading)
                    .padding(.top, BP.px(8))
            }
            .padding(.leading, BP.gutter)
            .padding(.bottom, BP.px(26))
            .frame(height: boxHeight, alignment: .bottomLeading)
            .id(band.key)
            .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.3), value: band.key)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// A small mark sized to a height with its own aspect (no placeholder plate while it loads, and
/// nothing at all when it fails, like bp-section's BpBandBug and bp-spotlight's hero mark).
struct BandMark: View {
    let url: String
    var height: CGFloat
    var maxWidth: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image, image.size.height > 0 {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: min(maxWidth, height * image.size.width / image.size.height), height: height)
            }
        }
        .task(id: url) {
            image = nil
            guard let u = URL(string: url) else { return }
            image = await ImageLoader.shared.image(for: u)
        }
    }
}

/// bp-live-hero.tsx: the Home Live TV row's ambient preview. After HERO_DWELL_MS (1600 ms, longer
/// than the guide portal's 700 because a wrong start here is a half-screen flash) on a channel, a
/// muted mpv preview fills the art envelope (right 76 %, feathered, under FLOOR / PAGE_FADE /
/// TOP_FADE) and fades in once it plays. A channel that fails is not retried this session (the
/// shared FAILED ledger); it never mounts while the real player or any cover is up (IPTV accounts
/// often allow one connection), nor under Reduce Motion.
struct LiveHeroPreview: View {
    let channel: LiveModel.Channel?
    let suspended: Bool

    private static let dwell: Duration = .milliseconds(1600)
    private static var failed = Set<String>()

    /// The dwell is held as the channel id, not a flag, so a new channel never mounts undwelled.
    /// Anything over Home the caller cannot see (a cover, the saver, the lock, playback).
    @ObservedObject private var gate = PreviewGate.shared
    private var stopped: Bool { suspended || gate.blocked }

    @State private var armedId = ""
    @State private var playing = false
    @State private var failures = 0

    private var mountVideo: Bool {
        _ = failures
        guard let c = channel else { return false }
        return armedId == c.id && !c.url.isEmpty && !Self.failed.contains(c.id) && !stopped && !UIAccessibility.isReduceMotionEnabled
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width * 0.76
            let h = g.size.height
            if mountVideo, let c = channel, let url = URL(string: c.url) {
                ZStack {
                    // `cover`: a 16:9 player filling the envelope, cropped.
                    MPVPlayerView(url: url, headers: c.headers ?? [:], isLive: true, preview: true, onStatus: { st in
                        if st.state == "playing" { playing = true }
                        if st.state == "error" { Self.failed.insert(c.id); playing = false; failures += 1 }
                    })
                    .id(c.id)
                    .frame(width: max(w, h * 16 / 9), height: max(h, w * 9 / 16))
                    .frame(width: w, height: h)
                    .clipped()
                    // FLOOR, PAGE_FADE, TOP_FADE.
                    LinearGradient(stops: [.init(color: BP.void_, location: 0), .init(color: BP.void_.opacity(0.55), location: 0.22),
                                           .init(color: .clear, location: 0.46)], startPoint: .bottom, endPoint: .top)
                    LinearGradient(stops: [.init(color: BP.void_, location: 0), .init(color: BP.void_, location: 0.34),
                                           .init(color: BP.void_.opacity(0.78), location: 0.46), .init(color: BP.void_.opacity(0.34), location: 0.58),
                                           .init(color: .clear, location: 0.72)], startPoint: .bottom, endPoint: .top)
                    LinearGradient(stops: [.init(color: BP.void_.opacity(0.8), location: 0), .init(color: .clear, location: 0.26)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .frame(width: w, height: h)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.5), location: 0.17),
                                             .init(color: .black, location: 0.38)], startPoint: .leading, endPoint: .trailing))
                .opacity(playing ? 1 : 0)
                .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.52), value: playing)
                .frame(width: g.size.width, height: h, alignment: .trailing)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: channel?.id) {
            armedId = ""; playing = false
            guard let id = channel?.id else { return }
            try? await Task.sleep(for: Self.dwell)
            if !Task.isCancelled { armedId = id }
        }
        // Suspending unmounts the player (MPVPlayerView's dismantle stops mpv); it fades in afresh.
        .onChange(of: stopped) { _, on in if on { playing = false } }
    }
}

/// bp-collection-detail.tsx for a Home "Collections" card: the TMDB collection through the engine,
/// shown in the Collections room's overlay; "Couldn't load this collection right now." otherwise.
struct HomeCollectionView: View {
    struct Target: Identifiable { var ref: String; var name: String; var image: String?; var id: String { ref } }
    let target: Target
    let onClose: () -> Void
    @State private var card: CollectionsModel.Card?
    @State private var loaded = false
    @State private var detail: Meta?

    var body: some View {
        ZStack {
            if let card, !card.items.isEmpty {
                // A curated TMDB collection is read-only: default limits, nothing to reload on change.
                CollectionItemsOverlay(card: card, limits: CollectionsModel.Limits(collections: 24, items: 100),
                                       onClose: onClose, onChanged: { _ in }, onOpen: { item in detail = item.meta })
            } else {
                BP.void_.opacity(0.97).ignoresSafeArea()
                if let image = target.image {
                    RemoteImage(url: image).opacity(0.22).ignoresSafeArea()
                }
                VStack(alignment: .leading, spacing: BP.px(14)) {
                    Text("Collection").font(BP.sans(12, .bold)).foregroundStyle(BP.accent).textCase(.uppercase).tracking(1)
                    Text(target.name).font(BP.display(32)).foregroundStyle(BP.ink)
                    if loaded {
                        BPNote(text: "Couldn't load this collection right now.")
                    } else {
                        ProgressView().tint(BP.inkMuted)
                    }
                    Button("Close", action: onClose).buttonStyle(BPActionStyle())
                }
                .padding(.horizontal, BP.gutter).padding(.top, BP.px(60))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onExitCommand { onClose() }
            }
        }
        .task {
            let p = ProfilesStore.shared.active
            card = try? await HarborEngine.shared.call("collectionsRoom.tmdbCard", [p?.id ?? "default", p?.linked ?? true, target.ref, target.name])
            loaded = true
        }
        .fullScreenCover(item: $detail) { m in DetailView(meta: m) }
    }
}
