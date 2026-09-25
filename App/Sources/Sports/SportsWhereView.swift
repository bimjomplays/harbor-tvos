import SwiftUI

/// `sports.where` (bp-sports-event-rows BpSportsWhereRow + bp-sports-extra-venue): the venue cell
/// and one tile per watch provider, with UFC.com / formula1.com guides as fallbacks. Upstream opens
/// each link in the browser (openUrl); tvOS has none, so a tile first tries the link as a universal
/// link (a provider's installed Apple TV app can claim it) and otherwise hands it to the phone.
struct SportsWhere: Decodable {
    struct Venue: Decodable { var name: String; var location: String; var image: String; var url: String; var facts: [String] }
    struct Mark: Decodable { var id: String; var name: String; var note: String; var logo: String; var url: String }
    var title: String
    var venue: Venue?
    var marks: [Mark]
    var note: String?
}

/// A link the TV hands over: open it in an app when possible, else a QR code for the phone.
struct SportsLink: Identifiable {
    let title: String
    let url: String
    /// A provider app URL scheme to try first (twitch://, youtube://).
    var app: String? = nil
    /// Try `url` itself as a universal link before showing the code.
    var universal = false
    var message = "This page opens in a web browser. Scan to open it on your phone."
    var id: String { url }
}

struct SportsWhereRowView: View {
    let game: SportsModel.Game
    @State private var data: SportsWhere?
    @State private var link: SportsLink?

    var body: some View {
        Group {
            if let w = data {
                SportsPanelRow(title: w.title, foot: w.note) {
                    if let v = w.venue { venueCell(v) }
                    ForEach(w.marks, id: \.id) { m in
                        Button { link = SportsLink(title: m.name, url: m.url, universal: true) } label: {
                            HStack(spacing: BP.px(12)) {
                                if !m.logo.isEmpty {
                                    RemoteImage(url: m.logo, contentMode: .fit).frame(width: BP.px(40), height: BP.px(40))
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.name).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                    if !m.note.isEmpty { Text(T(m.note)).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).lineLimit(1) }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right.square").font(.system(size: BP.px(16))).foregroundStyle(BP.inkSubtle).accessibilityHidden(true)
                            }
                            .padding(.horizontal, BP.px(16)).padding(.vertical, BP.px(14))
                            .frame(width: BP.px(380), alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
                            .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
                        }
                        .buttonStyle(BPTileStyle(radius: BP.rMD))
                    }
                }
            }
        }
        .task(id: game.id) { data = try? await HarborEngine.shared.call("sports.where", [game.wire]) }
        .fullScreenCover(item: $link) { l in SportsLinkView(link: l) { link = nil } }
    }

    // BpSportsVenueCell: art (track map / photo) over the name, location and facts; Select opens the page.
    @ViewBuilder private func venueCell(_ v: SportsWhere.Venue) -> some View {
        SportsPanelCell(width: BP.px(560), padded: v.image.isEmpty, action: { if !v.url.isEmpty { link = SportsLink(title: v.name, url: v.url, universal: true) } }) {
            if !v.image.isEmpty {
                RemoteImage(url: v.image).frame(width: BP.px(560), height: BP.px(315)).clipped()
                    .overlay(LinearGradient(colors: [BP.void_, .clear], startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.38)))
            }
            VStack(alignment: .leading, spacing: BP.px(6)) {
                Label("Venue", systemImage: "mappin.and.ellipse").font(BP.sans(11, .bold)).textCase(.uppercase).foregroundStyle(BP.inkSubtle)
                Text(v.name).font(BP.sans(17, .semibold)).foregroundStyle(BP.ink).lineLimit(2)
                if !v.location.isEmpty { Text(v.location).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).lineLimit(1) }
                if !v.facts.isEmpty { Text(v.facts.joined(separator: " · ")).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).lineLimit(1) }
                Text(v.url.isEmpty ? "No venue page published" : "Open venue page").font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
            }
            .padding(v.image.isEmpty ? 0 : BP.px(18))
        }
    }
}

/// The phone handoff for a link (same shape as TrailerView / ExternalLinkView), with an "Open in
/// app" button when the link names an app scheme or may be claimed as a universal link.
struct SportsLinkView: View {
    let link: SportsLink
    let onClose: () -> Void
    @State private var note: String?

    var body: some View {
        ZStack {
            BP.void_.opacity(0.94).ignoresSafeArea()
            HStack(alignment: .center, spacing: BP.px(48)) {
                VStack(alignment: .leading, spacing: BP.px(14)) {
                    Text(link.title).font(BP.display(30)).foregroundStyle(BP.ink).lineLimit(2)
                    Text(T(link.message)).font(BP.sans(15)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: BP.px(10)) {
                        if link.app != nil || link.universal {
                            Button { open() } label: { Label("Open in app", systemImage: "arrow.up.forward.app") }.buttonStyle(BPActionStyle(primary: true))
                        }
                        Button("Close") { onClose() }.buttonStyle(BPActionStyle(primary: link.app == nil && !link.universal))
                    }
                    if let note { BPNote(text: note) }
                }
                .frame(maxWidth: BP.px(620), alignment: .leading)
                VStack(spacing: BP.px(10)) {
                    if let qr = QRCode.image(link.url) {
                        Image(uiImage: qr).interpolation(.none).resizable().frame(width: BP.px(220), height: BP.px(220)).accessibilityLabel(Text(T("QR code")))
                            .padding(BP.px(10)).background(Color.white).clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
                    }
                    Text("Scan to open on your phone").font(BP.sans(13, .semibold)).foregroundStyle(BP.ink)
                    Text(link.url.replacingOccurrences(of: "https://", with: "")).font(BP.sans(11)).foregroundStyle(BP.inkSubtle).lineLimit(2).frame(maxWidth: BP.px(320))
                }
            }
            .padding(BP.gutter)
        }
        .onExitCommand { onClose() }
    }

    private func open() {
        Task { @MainActor in
            if let s = link.app, let app = URL(string: s), await UIApplication.shared.open(app) { return }
            if link.universal || link.app != nil, let web = URL(string: link.url), await UIApplication.shared.open(web) { return }
            note = "No app on this Apple TV opens this link. Scan the code to open it on your phone."
        }
    }
}

/// bp-sports-broadcast-picker's broadcast half + bp-sports-broadcast-stage: the official
/// Twitch / YouTube / Kick broadcasts for this event. Upstream plays them in an embedded web
/// player; the TV has no web view and upstream never extracts a native stream, so each one opens
/// the provider's Apple TV app (Twitch, YouTube) or goes to the phone by QR code (Kick, others).
struct SportsBroadcastsView: View {
    let fixture: String
    let broadcasts: [SportsEventModel.Broadcast]
    let onAir: Bool
    /// Picker actions kept from bp-sports-broadcast-picker: channels, addon sources, Live TV setup.
    var channels: (() -> Void)? = nil
    var addons: (() -> Void)? = nil
    var setup: (() -> Void)? = nil
    let onClose: () -> Void
    @State private var link: SportsLink?

    var body: some View {
        ZStack {
            BP.void_.opacity(0.94).ignoresSafeArea()
            VStack(alignment: .leading, spacing: BP.px(14)) {
                Text("Where to watch").font(BP.display(32)).foregroundStyle(BP.ink)
                Text(fixture).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted).lineLimit(1)
                if onAir { Text("Live").font(BP.sans(10, .bold)).foregroundStyle(BP.canvas).padding(.horizontal, BP.px(6)).padding(.vertical, BP.px(2)).background(Capsule().fill(BP.live)) }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: BP.px(10)) {
                        ForEach(broadcasts) { b in
                            Button { link = SportsLink(title: b.title, url: b.url, app: b.app, message: T("Official broadcast. It plays in the %@ app, or scan to watch on your phone.", b.platformLabel)) } label: {
                                HStack(spacing: BP.px(14)) {
                                    Image(systemName: b.platform == "youtube" ? "play.rectangle.fill" : b.platform == "twitch" ? "tv.fill" : "dot.radiowaves.left.and.right")
                                        .font(.system(size: BP.px(20), weight: .semibold)).foregroundStyle(BP.inkMuted)
                                        .frame(width: BP.px(44), height: BP.px(44)).background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(b.title).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                                        Text(T(b.platformLabel)).font(BP.sans(11)).foregroundStyle(BP.inkMuted)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: b.app != nil ? "arrow.up.forward.app" : "qrcode").foregroundStyle(BP.inkSubtle).accessibilityHidden(true)
                                }
                                .padding(.horizontal, BP.px(16)).padding(.vertical, BP.px(12))
                                .frame(width: BP.px(760), alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
                            }
                            .buttonStyle(BPTileStyle(radius: BP.rMD))
                        }
                    }
                    .padding(.vertical, BP.px(8))
                }
                .scrollClipDisabled()
                .focusSection()
                HStack(spacing: BP.px(10)) {
                    if let channels { Button { channels() } label: { Label("Search your channels", systemImage: "magnifyingglass") }.buttonStyle(BPActionStyle()) }
                    if let addons { Button { addons() } label: { Label("Addon sources", systemImage: "powerplug") }.buttonStyle(BPActionStyle()) }
                    if let setup { Button(T("Set up Live TV")) { setup() }.buttonStyle(BPActionStyle()) }
                    Button("Close") { onClose() }.buttonStyle(BPActionStyle())
                }
                .focusSection()
            }
            .frame(maxWidth: BP.px(1000), alignment: .leading)
            .padding(BP.gutter).padding(.top, BP.px(30))
        }
        .onExitCommand { onClose() }
        .fullScreenCover(item: $link) { l in SportsLinkView(link: l) { link = nil } }
    }
}
