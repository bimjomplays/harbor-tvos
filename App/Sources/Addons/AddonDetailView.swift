import SwiftUI

/// views/addons/addon-detail.tsx (with addons.tsx RemoteOrLocalDetail): header with logo, stars,
/// "Community · Streams", rising badge and description; Install / Configure & install /
/// Install default / Installed + Remove / Reconfigure; documentation from stremio-addons.net;
/// the manifest facts ("Project information"); the masked manifest URL with Reveal; More like
/// this and Recommended for you. tvOS has no browser or clipboard, so the site links and the
/// setup page go to the phone by QR.
struct AddonDetailView: View {
    let addonId: String
    @ObservedObject var model: AddonsModel
    let onClose: () -> Void

    struct Detail: Decodable {
        struct Catalog: Decodable, Hashable { var name: String; var type: String }
        struct Stat: Decodable, Hashable { var label: String; var value: String; var mono: Bool }
        struct Community: Decodable { var stars: Double; var slug: String; var siteUrl: String; var rateUrl: String }
        var card: AddonsModel.Card
        var eyebrow: String
        var version: String?
        var types: [String]
        var resources: [String]
        var catalogs: [Catalog]
        var stats: [Stat]
        var configurable: Bool
        var configurationRequired: Bool
        var adult: Bool
        var configureUrl: String
        var stremioUrl: String
        var maskedUrl: String
        var community: Community?
        var risingStars: Double?
        var documentation: String?
        var related: [AddonsModel.Card]
        var recommended: [AddonsModel.Card]
    }
    private struct External: Identifiable { var url: String; var id: String { url } }

    /// The ids this page walked through (a related tile opens in place; Back returns).
    @State private var stack: [String] = []
    @State private var detail: Detail?
    @State private var loading = true
    @State private var busy: String?
    @State private var revealed = false
    @State private var docOpen = false
    @State private var configure: AddonsModel.ConfigureTarget?
    @State private var external: External?
    /// The id whose page `detail` holds (a re-read of it keeps the page's open sections).
    @State private var shownId: String?
    /// (sports/addons pass 2) Cleared when the viewer closes the page. A Remove's re-read landing
    /// after Back found nothing and "went back" again: that onClose shut the next addon's page the
    /// viewer had opened meanwhile. A class, read after the wait (a gone view's @State isn't).
    private final class Alive { var on = true }
    @State private var alive = Alive()
    /// (sports/addons pass 2) A new page opens on its action pill; the first focus took the star
    /// count at the top left, whose Select opens the rating page's QR code.
    @FocusState private var actionFocused: Bool

    private var currentId: String { stack.last ?? addonId }

    var body: some View {
        ZStack {
            BP.canvas.ignoresSafeArea()
            if let d = detail {
                content(d)
            } else if loading {
                ProgressView().tint(BP.inkMuted)
            }
            // (addons pass) RemoteOrLocalDetail renders the toaster too: Install / Remove report
            // through the Addons screen's toast, which was drawn under this cover, so a failed
            // install or remove said nothing at all.
            if let t = model.toast {
                AddonToastView(toast: t)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, BP.px(40))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .task(id: currentId) { await load() }
        .onExitCommand { back() }
        .fullScreenCover(item: $configure) { c in
            AddonConfigureView(target: c, model: model, onClose: { configure = nil; Task { await load() } })
        }
        .fullScreenCover(item: $external) { e in ExternalLinkView(url: e.url, onClose: { external = nil }) }
    }

    private func back() {
        // (addons pass) Back to the previous addon: its page used to keep showing the one just
        // left (Install included, acting on that addon) until the previous one had loaded again.
        if stack.count > 1 { detail = nil; shownId = nil; stack.removeLast() } else { alive.on = false; onClose() }
    }

    private func load() async {
        if stack.isEmpty { stack = [addonId] }
        loading = true; defer { loading = false }
        let asked = currentId
        // (addons pass) A re-read of the page on screen (after Install / Remove / a setup, or when
        // a QR cover closes and `.task` runs again) keeps the expanded documentation and the
        // revealed URL; only a new addon starts folded.
        let again = shownId == asked && detail != nil
        if !again { revealed = false; docOpen = false }
        let life = alive
        let d: Detail? = try? await HarborEngine.shared.call("addonsManager.detail", [asked, model.authKey, model.adultAllowed])
        // (bug pass) A related tile (or Back) changed the page while this loaded: the engine call is
        // not cancelled with the task, so a late answer would show (or, failing, pop) the wrong addon.
        guard life.on, asked == currentId else { return }
        // RemoteOrLocalDetail: nothing resolved → go back. Not on a re-read of a page already up
        // (a flaky read when a QR cover closed shut the page), except after a Remove: an addon
        // known only from its install has nothing left to show, as upstream.
        guard let d else {
            if !again || busy == "remove" { back() }
            return
        }
        detail = d
        shownId = asked
        if !again { DispatchQueue.main.async { actionFocused = true } }
    }

    private func open(_ c: AddonsModel.Card) {
        guard c.addonId != currentId else { return }
        detail = nil
        shownId = nil
        stack.append(c.addonId)
    }

    private func content(_ d: Detail) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: BP.px(36)) {
                header(d)
                if let doc = d.documentation { documentation(doc) }
                projectInformation(d)
                rail(T("More like this"), d.related)
                rail(T("Recommended for you"), d.recommended)
                Color.clear.frame(height: BP.px(40))
            }
            .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(60))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(alignment: .top) {
            // DetailHeaderBackdrop: the manifest background at 55 % under a fade to the canvas.
            ZStack {
                LinearGradient(colors: [BP.elevated, BP.canvas, BP.canvas], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let bg = d.card.background { RemoteImage(url: bg).opacity(0.55) }
                LinearGradient(colors: [BP.canvas.opacity(0.2), BP.canvas], startPoint: .top, endPoint: .bottom)
            }
            .frame(height: BP.px(520)).clipped()
        }
    }

    // MARK: header

    private func header(_ d: Detail) -> some View {
        let c = d.card
        return HStack(alignment: .top, spacing: BP.px(36)) {
            VStack(spacing: BP.px(14)) {
                AddonLogoView(url: c.logo, name: c.name, side: BP.px(150))
                if let comm = d.community {
                    Button { external = External(url: comm.rateUrl) } label: {
                        Label(Int(comm.stars).formatted(), systemImage: "star.fill").font(BP.sans(26, .semibold))
                    }
                    .buttonStyle(BPActionStyle())
                    .accessibilityLabel(T("Rate on stremio-addons.net"))
                }
            }
            VStack(alignment: .leading, spacing: BP.px(10)) {
                Text(d.eyebrow).font(BP.sans(11, .bold)).textCase(.uppercase).tracking(3).foregroundStyle(BP.inkSubtle)
                Text(c.name).font(BP.display(36, .medium)).foregroundStyle(BP.ink)
                if let r = d.risingStars {
                    AddonBadge(text: clampedInt(r) == 1 ? T("Rising · +%lld star in 24h", clampedInt(r)) : T("Rising · +%lld stars in 24h", clampedInt(r)),
                               icon: "chart.line.uptrend.xyaxis", tint: Color(hex: 0xfda4af))
                }
                if !c.description.isEmpty {
                    Text(c.description).font(BP.sans(16)).foregroundStyle(BP.inkMuted).lineLimit(6).frame(maxWidth: BP.px(900), alignment: .leading)
                }
                actions(d).padding(.top, BP.px(8))
                HStack(spacing: BP.px(8)) {
                    if d.adult { AddonBadge(text: T("Adult"), icon: "exclamationmark.triangle", tint: BP.inkMuted) }
                    if d.configurable { AddonBadge(text: T("Configurable"), icon: "slider.horizontal.3", tint: BP.inkSubtle) }
                }
            }
        }
    }

    @ViewBuilder private func actions(_ d: Detail) -> some View {
        let c = d.card
        VStack(alignment: .leading, spacing: BP.px(12)) {
            HStack(spacing: BP.px(12)) {
                if c.installed && busy == nil {
                    Label(T("Installed"), systemImage: "checkmark").font(BP.sans(15, .semibold)).foregroundStyle(BP.accent)
                        .padding(.horizontal, BP.px(16)).frame(minHeight: BP.tabItem).background(Capsule().fill(BP.accent.opacity(0.15)))
                }
                // (addons pass) addon-detail.tsx keeps one pill in this place through Install →
                // Installing → Installed/Remove and back. The TV swapped the pressed button for a
                // plain label, so the focus ring jumped off it (down to Reveal, scrolling the page,
                // when the addon had no stremio-addons.net links); one button now changes in place.
                Button { primaryAction(d) } label: { primaryLabel(d) }
                    .buttonStyle(BPActionStyle(primary: busy == "install" || (busy == nil && !c.installed), busy: busy != nil))
                    .focused($actionFocused)
                if busy == nil && c.installed && d.configurable {
                    Button { configure = target(d, mode: .manage) } label: { Label(T("Reconfigure"), systemImage: "slider.horizontal.3") }
                        .buttonStyle(BPActionStyle())
                }
                // addon-detail.tsx shows Install default beside Configure & install on the desktop
                // app. An addon that requires configuration has nothing sensible to install by default.
                if busy == nil && !c.installed && d.configurable && !d.configurationRequired {
                    Button(T("Install default")) { Task { await install(c, useDefault: true) } }.buttonStyle(BPActionStyle())
                }
            }
            .focusSection()
            if let comm = d.community {
                HStack(spacing: BP.px(12)) {
                    Button { external = External(url: comm.siteUrl) } label: { Label(T("On Stremio-Addons"), systemImage: "arrow.up.right.square") }
                        .buttonStyle(BPActionStyle())
                    Button { external = External(url: comm.rateUrl) } label: { Label(T("Rate"), systemImage: "star") }
                        .buttonStyle(BPActionStyle())
                }
                .focusSection()
            }
        }
    }

    private func target(_ d: Detail, mode: AddonsModel.ConfigureTarget.Mode) -> AddonsModel.ConfigureTarget {
        AddonsModel.ConfigureTarget(mode: mode, name: d.card.name, logo: d.card.logo, configureUrl: d.configureUrl,
                                    manageId: mode == .manage ? d.card.addonId : nil)
    }

    /// The action pill: Remove when installed, else Configure & install / Install; nothing while busy.
    private func primaryAction(_ d: Detail) {
        guard busy == nil else { return }
        let c = d.card
        if c.installed { Task { await remove(c) } }
        else if d.configurable { configure = target(d, mode: .configure) }
        else { Task { await install(c, useDefault: false) } }
    }

    @ViewBuilder private func primaryLabel(_ d: Detail) -> some View {
        if busy == "remove" {
            Label(T("Removing"), systemImage: "hourglass")
        } else if busy == "install" {
            Label(T("Installing"), systemImage: "hourglass")
        } else if d.card.installed {
            Label(T("Remove"), systemImage: "trash")
        } else if d.configurable {
            Label(T("Configure & install"), systemImage: "slider.horizontal.3")
        } else {
            Label(T("Install"), systemImage: "plus")
        }
    }

    // (addons pass) Busy until the page has read the addon again: clearing it first showed the
    // old Install (or Remove) again, pressable, for as long as that read took.
    private func install(_ c: AddonsModel.Card, useDefault: Bool) async {
        guard busy == nil else { return }
        busy = "install"
        let setup = await model.install(c, useDefault: useDefault)
        if let setup { busy = nil; configure = setup; return }
        await load()
        busy = nil
    }

    private func remove(_ c: AddonsModel.Card) async {
        guard busy == nil else { return }
        busy = "remove"
        await model.uninstall(c)
        await load()
        busy = nil
    }

    // MARK: documentation, project information

    private func documentation(_ doc: String) -> some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            HStack(alignment: .firstTextBaseline) {
                Text(T("Documentation")).font(BP.display(22, .medium)).foregroundStyle(BP.ink)
                Spacer()
                Text(T("From stremio-addons.net")).font(BP.sans(11)).textCase(.uppercase).tracking(2).foregroundStyle(BP.inkSubtle)
            }
            Text(Self.markdown(doc)).font(BP.sans(15)).foregroundStyle(BP.inkMuted)
                .lineLimit(docOpen ? nil : 14).frame(maxWidth: BP.px(1100), alignment: .leading)
            Button(docOpen ? T("Show less") : T("Show full documentation")) { docOpen.toggle() }.buttonStyle(BPActionStyle())
        }
        .focusSection()
    }

    /// react-markdown with skipHtml, reduced to what Text draws: inline styles, line breaks kept.
    private static func markdown(_ s: String) -> AttributedString {
        let stripped = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "", options: .regularExpression)
        return (try? AttributedString(markdown: stripped, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(stripped)
    }

    private func projectInformation(_ d: Detail) -> some View {
        VStack(alignment: .leading, spacing: BP.px(18)) {
            HStack(alignment: .firstTextBaseline) {
                Text(T("Project information")).font(BP.display(22, .medium)).foregroundStyle(BP.ink)
                Spacer()
                Text(T("Pulled from manifest")).font(BP.sans(11)).textCase(.uppercase).tracking(2).foregroundStyle(BP.inkSubtle)
            }
            HStack(alignment: .top, spacing: BP.px(48)) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(d.stats, id: \.self) { s in
                        HStack(alignment: .firstTextBaseline) {
                            Text(s.label).font(BP.sans(12)).textCase(.uppercase).tracking(1.5).foregroundStyle(BP.inkSubtle)
                            Spacer(minLength: BP.px(20))
                            Text(s.value).font(s.mono ? .system(size: BP.px(12), design: .monospaced) : BP.sans(14)).foregroundStyle(BP.ink).multilineTextAlignment(.trailing)
                        }
                        .padding(.vertical, BP.px(10))
                        Divider().overlay(BP.edge)
                    }
                    if !d.catalogs.isEmpty {
                        Text(d.catalogs.prefix(12).map { "\($0.name) · \($0.type)" }.joined(separator: "   "))
                            .font(BP.sans(12)).foregroundStyle(BP.inkMuted).padding(.top, BP.px(10))
                    }
                }
                .frame(maxWidth: BP.px(760))
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    HStack {
                        Text(T("Manifest URL")).font(BP.sans(12)).textCase(.uppercase).tracking(1.5).foregroundStyle(BP.inkSubtle)
                        Spacer()
                        Button { revealed.toggle() } label: { Label(revealed ? T("Hide") : T("Reveal"), systemImage: revealed ? "eye.slash" : "eye") }
                            .buttonStyle(BPActionStyle())
                    }
                    Text(revealed ? d.card.transportUrl : d.maskedUrl)
                        .font(.system(size: BP.px(13), design: .monospaced)).foregroundStyle(BP.inkMuted)
                        .padding(BP.px(14)).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel))
                    if revealed, let qr = QRCode.image(d.card.transportUrl) {
                        Image(uiImage: qr).interpolation(.none).resizable().frame(width: BP.px(180), height: BP.px(180)).accessibilityLabel(Text(T("QR code")))
                            .padding(BP.px(8)).background(Color.white).clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
                    }
                    if !revealed {
                        BPNote(text: "Hidden by default. Manifest paths often carry API keys (debrid tokens, OMDB keys, etc.) you don't want over a shoulder.")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .focusSection()
        }
    }

    // MARK: rails (detail-rail.tsx)

    @ViewBuilder private func rail(_ title: String, _ items: [AddonsModel.Card]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: BP.px(12)) {
                Text(title).font(BP.display(22, .medium)).foregroundStyle(BP.ink)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: BP.trackGap) {
                        ForEach(items) { c in AddonTile(card: c) { open(c) } }
                    }
                    .padding(.vertical, BP.px(14))
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }
}
