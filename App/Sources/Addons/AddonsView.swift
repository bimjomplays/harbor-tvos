import SwiftUI

/// views/addons.tsx on the TV: Discover (spotlight, community rail, categories), Browse
/// (stremio-addons.net by category, Top rated / Top rising / Just added, search) and Installed
/// (position, on/off switch, Manage, Remove, Reorder). Everything runs through the engine's
/// addonsManager (engine/addonsManager.ts), which keeps upstream's rules.
@MainActor
final class AddonsModel: ObservableObject {
    enum Tab: String { case discover, browse, installed }
    /// addons.tsx BROWSE_MODES, in upstream's order.
    enum BrowseMode: String, CaseIterable { case top, rising, new }
    /// community-addons-rail.tsx TABS.
    enum RailMode: String, CaseIterable { case trending, stars, createdAt }

    /// engine/addonsManager.ts AddonCard.
    struct Card: Decodable, Identifiable, Equatable {
        var key: String
        var addonId: String
        var name: String
        var description: String
        var subtitle: String
        var logo: String?
        var background: String?
        var transportUrl: String
        var configureUrl: String
        var installed: Bool
        var configurable: Bool
        @LossyArray var types: [String]   // (bug pass 2) lossy
        var stars: Double
        var rising: Double?
        var risingWindow: Double?
        var isNew: Bool
        var slug: String?
        var enabled: Bool
        var position: Int
        var id: String { key }
        enum CodingKeys: String, CodingKey {
            case key, addonId = "id", name, description, subtitle, logo, background, transportUrl, configureUrl
            case installed, configurable, types, stars, rising, risingWindow, isNew, slug, enabled, position
        }
    }
    struct Category: Decodable, Identifiable, Equatable { var name: String; var slug: String; var id: String { slug } }
    struct Spotlight: Decodable, Equatable { var addon: Card; var trending: Bool }
    struct Toast: Identifiable, Equatable { let id = UUID(); var ok: Bool; var text: String; var name: String?; var logo: String? }
    struct DetailTarget: Identifiable, Equatable { var id: String }
    /// install-modal.tsx modes plus installer-viewport.tsx: a setup page to finish on the phone
    /// (configure / manage), or a pasted link (url).
    struct ConfigureTarget: Identifiable {
        enum Mode { case configure, manage, url }
        let id = UUID()
        var mode: Mode
        var name: String
        var logo: String?
        var configureUrl: String?
        var manageId: String?
        var prefill = ""
    }

    @Published var tab: Tab = .discover
    @Published private(set) var installed: [Card] = []
    @Published private(set) var installedCount = 0
    @Published private(set) var catalogLoading = false
    @Published private(set) var catalogLoaded = false
    @Published private(set) var categories: [Category] = []
    @Published private(set) var category: String?
    @Published private(set) var mode: BrowseMode = .top
    @Published var query = ""
    @Published private(set) var items: [Card] = []
    @Published private(set) var hasMore = false
    @Published private(set) var browseLoading = false
    @Published private(set) var browseEmpty = "none"
    @Published private(set) var spotlight: Spotlight?
    @Published private(set) var spotlightFailed = false
    @Published private(set) var railMode: RailMode = .trending
    @Published private(set) var rail: [Card]?
    @Published private(set) var busy: Set<String> = []
    @Published var toast: Toast?
    /// The Search screen's install path (install(url:)) reports here.
    @Published var error: String?

    private var page = 1
    private var browseGeneration = 0
    private var catalogGeneration = 0
    private var lastQuery = ""
    private var started = false
    private var toastTask: Task<Void, Never>?

    var authKey: String? { ProfilesStore.shared.active.flatMap { ProfilesStore.shared.stremioSession(for: $0.id)?.authKey } }
    var adultAllowed: Bool { SettingsBridge.shared.slice.showAdultAddons ?? false }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    func start() async {
        guard !started else { return }
        started = true
        async let cats: Void = loadCategories()
        async let disc: Void = loadDiscover()
        await loadCatalog()
        _ = await (cats, disc)
    }

    /// useAddonsCatalog + the Installed tab's order (addons.tsx `installed`).
    func loadCatalog(fresh: Bool = false) async {
        // (addons pass) Numbered: the first visit's slow catalog read finishing after an install's
        // fresh one put the list from before the install back on the Installed tab.
        catalogGeneration += 1
        let gen = catalogGeneration
        catalogLoading = true
        struct Loaded: Decodable { @LossyArray var installed: [Card]; var installedCount: Int; var total: Int; var cached: Bool? }   // (bug pass 2) lossy
        let r: Loaded? = try? await HarborEngine.shared.call("addonsManager.load", [authKey, adultAllowed, fresh])
        guard gen == catalogGeneration else { return }
        if let r {
            installed = r.installed
            installedCount = r.installedCount
        }
        catalogLoading = false
        catalogLoaded = true
        // (addons pass) addons.tsx builds the catalog on every visit: the kept one is shown at once,
        // then read again, so an addon added or removed on another Stremio app (or the account
        // list changed elsewhere) appears here without a relaunch.
        if r?.cached == true { await loadCatalog(fresh: true) }
    }

    func loadCategories() async {
        categories = (try? await HarborEngine.shared.call("addonsManager.categories", [adultAllowed])) ?? []
    }

    func loadDiscover() async {
        spotlightFailed = false
        let s: Spotlight? = try? await HarborEngine.shared.call("addonsManager.spotlight", [adultAllowed])
        spotlight = s
        spotlightFailed = s == nil
        await loadRail()
    }

    func setRailMode(_ m: RailMode) async {
        guard m != railMode else { return }
        railMode = m
        await loadRail()
    }

    private func loadRail() async {
        rail = nil
        let m = railMode
        let loaded: LossyArray<Card>? = try? await HarborEngine.shared.call("addonsManager.rail", [m.rawValue, adultAllowed])   // (bug pass 2) lossy
        let list = loaded?.wrappedValue ?? []
        guard m == railMode else { return }
        rail = list
    }

    // MARK: tabs, filters, search

    func select(_ t: Tab) {
        // addons.tsx: the Browse tab button clears the category.
        if t == .browse && (tab != .browse || category != nil) {
            tab = t
            category = nil
            Task { await reloadBrowse() }
            return
        }
        tab = t
        if t == .browse && items.isEmpty && !browseLoading { Task { await reloadBrowse() } }
    }

    /// category-grid.tsx goToCategory.
    func goToCategory(_ slug: String) {
        category = slug
        tab = .browse
        Task { await reloadBrowse() }
    }

    func setCategory(_ slug: String?) {
        guard slug != category else { return }
        category = slug
        Task { await reloadBrowse() }
    }

    func setMode(_ m: BrowseMode) {
        guard m != mode else { return }
        mode = m
        Task { await reloadBrowse() }
    }

    /// addons.tsx: typing outside Installed moves to Browse; the query replaces the category.
    func queryChanged() async {
        let q = trimmedQuery
        guard q != lastQuery else { return }
        lastQuery = q
        if !q.isEmpty && tab != .installed { tab = .browse }
        if tab == .browse { await reloadBrowse() }
    }

    func reloadBrowse() async {
        browseGeneration += 1
        page = 1
        items = []
        hasMore = true
        browseEmpty = "none"
        await loadMoreBrowse()
    }

    func loadMoreBrowse() async {
        guard !browseLoading, hasMore else { return }
        let gen = browseGeneration
        browseLoading = true
        struct Page: Decodable { @LossyArray var items: [Card]; var hasMore: Bool; var empty: String }   // (bug pass 2) lossy
        let q = trimmedQuery
        let search: String? = q.isEmpty ? nil : q
        let r: Page? = try? await HarborEngine.shared.call("addonsManager.browse", [mode.rawValue, category, search, adultAllowed, page])
        // Filters changed while this page loaded: its reload bounced off browseLoading, so it runs now (review 30).
        guard gen == browseGeneration else { browseLoading = false; await loadMoreBrowse(); return }
        browseLoading = false
        guard let r else { hasMore = false; return }
        // community-browse-list: a row already shown (same uuid) is not repeated.
        // (bug pass) Also drops repeats inside the page itself (duplicate ForEach ids).
        items = (items + r.items).uniquedById()
        hasMore = r.hasMore && !r.items.isEmpty
        browseEmpty = r.empty
        page += 1
    }

    /// installed-pane.tsx search: name, description or id.
    var filteredInstalled: [Card] {
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else { return installed }
        return installed.filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) || $0.addonId.lowercased().contains(q) }
    }

    // MARK: install / remove / switches

    struct Outcome: Decodable { var kind: String; var id: String?; var name: String?; var logo: String?; var toast: String?; var configureUrl: String?; var message: String? }

    /// addons.tsx onInstall: a configurable addon comes back as a setup page to open.
    func install(_ card: Card, useDefault: Bool = false) async -> ConfigureTarget? {
        guard !busy.contains(card.key) else { return nil }
        busy.insert(card.key); defer { busy.remove(card.key) }
        let fn = useDefault ? "addonsManager.installDefault" : "addonsManager.install"
        guard let o: Outcome = try? await HarborEngine.shared.call(fn, [card.addonId, card.transportUrl]) else {
            showToast(false, T("Install failed."))
            return nil
        }
        switch o.kind {
        case "configure":
            return ConfigureTarget(mode: .configure, name: o.name ?? card.name, logo: o.logo ?? card.logo, configureUrl: o.configureUrl ?? card.configureUrl)
        case "installed":
            HarborEngine.shared.emitEvent("harbor:addons-changed", detail: .object(["id": .string(o.id ?? card.addonId), "installed": .bool(true)]))
            showToast(true, o.toast ?? T("Installed"), name: o.name, logo: o.logo)
            await afterChange()
        default:
            showToast(false, o.message ?? T("Install failed."))
        }
        return nil
    }

    func uninstall(_ card: Card) async {
        guard !busy.contains(card.key) else { return }
        busy.insert(card.key); defer { busy.remove(card.key) }
        struct Removed: Decodable { var ok: Bool; var toast: String }
        let r: Removed? = try? await HarborEngine.shared.call("addonsManager.uninstall", [card.addonId, card.transportUrl])
        if r?.ok == true {
            HarborEngine.shared.emitEvent("harbor:addons-changed", detail: .object(["id": .string(card.addonId), "installed": .bool(false)]))
            showToast(true, r?.toast ?? T("Removed"), name: card.name, logo: card.logo)
            await afterChange()
        } else {
            showToast(false, r?.toast ?? T("Couldn't remove. Try again."))
        }
    }

    /// installed-pane.tsx handleToggle.
    func setEnabled(_ card: Card, _ on: Bool) async {
        _ = try? await HarborEngine.shared.callJSON("addonStore.setAddonEnabled", [.string(card.transportUrl), .bool(on)])
        HarborEngine.shared.emitEvent("harbor:addons-changed", detail: .object(["id": .string(card.addonId), "enabled": .bool(on)]))
        if let i = installed.firstIndex(where: { $0.key == card.key }) { installed[i].enabled = on }
    }

    /// After an install from a pasted or phone-sent link (configure / manage / URL).
    func installedFromLink(id: String, name: String?, logo: String?, toast text: String) async {
        HarborEngine.shared.emitEvent("harbor:addons-changed", detail: .object(["id": .string(id), "installed": .bool(true)]))
        showToast(true, text, name: name, logo: logo)
        await afterChange()
    }

    /// The Organize page saved: re-read the Installed order.
    func reordered(toast text: String) async {
        HarborEngine.shared.emitEvent("harbor:addons-changed", detail: .object(["reordered": .bool(true)]))
        showToast(true, text)
        await loadCatalog(fresh: true)
    }

    /// refetch(): the catalog, and the install flags on the lists already on screen.
    private func afterChange() async {
        await loadCatalog(fresh: true)
        let ids = Set(installed.map(\.addonId))
        for i in items.indices { items[i].installed = ids.contains(items[i].addonId) }
        if var s = spotlight { s.addon.installed = ids.contains(s.addon.addonId); spotlight = s }
        rail = rail?.filter { !ids.contains($0.addonId) }
    }

    /// addons.tsx Adult chip: on only after the age check (AgeGateView), off at once.
    func setAdult(_ on: Bool) async {
        try? await SettingsBridge.shared.patch(["showAdultAddons": .bool(on)])
        if !on && category == "nsfw" { category = nil }
        await loadCategories()
        async let disc: Void = loadDiscover()
        await loadCatalog(fresh: true)
        if tab == .browse || !items.isEmpty { await reloadBrowse() }
        _ = await disc
    }

    /// addons.tsx showToast: 3 s for a success, 5 s for an error.
    func showToast(_ ok: Bool, _ text: String, name: String? = nil, logo: String? = nil) {
        toastTask?.cancel()
        let t = Toast(ok: ok, text: text, name: name, logo: logo)
        withAnimation(BP.easeFast) { toast = t }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ok ? 3_000_000_000 : 5_000_000_000)
            guard !Task.isCancelled, let self, self.toast?.id == t.id else { return }
            withAnimation(BP.easeFast) { self.toast = nil }
        }
    }

    /// The Search screen's "hold Select to install" path: straight to installFromUrl.
    func install(url: String) async -> Bool {
        error = nil
        do {
            struct Result: Decodable { var replaced: Bool; var syncedToStremio: Bool }
            let _: Result = try await HarborEngine.shared.call("addonStore.installFromUrl", [url])
            HarborEngine.shared.emitEvent("harbor:addons-changed")
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

struct AddonsView: View {
    @StateObject private var model = AddonsModel()
    @ObservedObject private var settings = SettingsBridge.shared
    @Environment(\.dismiss) private var dismiss
    @State private var detail: AddonsModel.DetailTarget?
    @State private var configure: AddonsModel.ConfigureTarget?
    @State private var organizeOpen = false
    @State private var ageGateOpen = false
    /// (device-flow pass 4) The Installed tab's ring: "remove:<key>" on a row's Remove, "tab" on the
    /// Installed tab button. A removed row took the ring with it, and tvOS put it back at the top of
    /// the page (the Discover tab) instead of on the next row.
    @FocusState private var installedFocus: String?

    private var adult: Bool { settings.slice.showAdultAddons ?? false }

    var body: some View {
        ZStack(alignment: .bottom) {
            BPAmbientBackground()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(24)) {
                    header
                    switch model.tab {
                    case .discover: discoverPane
                    case .browse: browsePane
                    case .installed: installedPane
                    }
                    Color.clear.frame(height: BP.px(60))
                }
                .padding(.horizontal, BP.gutter).padding(.vertical, BP.px(50))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let t = model.toast { AddonToastView(toast: t).padding(.bottom, BP.px(40)).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .ignoresSafeArea()
        .task { await model.start() }
        .task(id: model.query) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await model.queryChanged()
        }
        .fullScreenCover(item: $detail) { d in
            AddonDetailView(addonId: d.id, model: model, onClose: { detail = nil })
        }
        .fullScreenCover(item: $configure) { c in
            AddonConfigureView(target: c, model: model, onClose: { configure = nil })
        }
        .fullScreenCover(isPresented: $organizeOpen) {
            AddonOrganizeView(authKey: model.authKey, onClose: { organizeOpen = false }, onSaved: { text in
                organizeOpen = false
                Task { await model.reordered(toast: text) }
            })
        }
        .fullScreenCover(isPresented: $ageGateOpen) {
            AgeGateView(onPass: { Task { await model.setAdult(true) } }, onClose: { ageGateOpen = false })
        }
    }

    // MARK: header (addons.tsx <header>)

    private var header: some View {
        VStack(alignment: .leading, spacing: BP.px(16)) {
            HStack(alignment: .firstTextBaseline) {
                Text(T("Addons")).font(BP.display(36)).foregroundStyle(BP.ink)
                Spacer()
            }
            HStack(spacing: BP.px(10)) {
                tabButton(.discover, T("Discover"))
                tabButton(.browse, T("Browse"))
                Button { model.select(.installed) } label: {
                    HStack(spacing: BP.px(8)) {
                        Image(systemName: "checkmark").font(.system(size: BP.px(13), weight: .bold)).accessibilityHidden(true)
                        Text(T("Installed"))
                        Text("\(model.installedCount)").font(BP.sans(12, .bold)).monospacedDigit()
                            .padding(.horizontal, BP.px(7)).padding(.vertical, BP.px(2))
                            .background(Capsule().fill(model.tab == .installed ? BP.canvas.opacity(0.15) : BP.edge))
                    }
                }
                .buttonStyle(BPActionStyle(primary: model.tab == .installed)).bpSelected(model.tab == .installed)
                .focused($installedFocus, equals: "tab")
                Spacer(minLength: BP.px(24))
                Button { configure = AddonsModel.ConfigureTarget(mode: .url, name: T("Add from URL")) } label: {
                    Label(T("Add from URL"), systemImage: "link")
                }
                .buttonStyle(BPActionStyle())
                // addons.tsx Adult chip: turning it on goes through the age check first.
                Button {
                    if adult { Task { await model.setAdult(false) } } else { ageGateOpen = true }
                } label: {
                    Label(T("Adult"), systemImage: adult ? "checkmark.square.fill" : "square")
                }
                .buttonStyle(BPActionStyle())
                .accessibilityLabel(adult ? T("Hide adult addons") : T("Show adult addons"))
                Button("Done") { dismiss() }.buttonStyle(BPActionStyle())
            }
            .focusSection()
            HStack(alignment: .bottom, spacing: BP.px(14)) {
                BPField(label: "Search addons", placeholder: "Search addons", text: $model.query, phone: true)
                    .frame(maxWidth: BP.px(560))
                if model.tab == .installed && !model.installed.isEmpty {
                    Button { organizeOpen = true } label: { Label(T("Reorder"), systemImage: "arrow.up.arrow.down") }
                        .buttonStyle(BPActionStyle())
                    Text(T("Change the order addons are tried in")).font(BP.sans(13)).foregroundStyle(BP.inkSubtle)
                        .padding(.bottom, BP.px(14))
                }
            }
            .focusSection()
            if model.tab == .discover {
                BPNote(text: "Popular community addons ranked by the public directory's stars. Install anything else by URL on the Browse tab.")
            }
        }
    }

    /// (sports/addons pass 2) A configurable addon's Install answers with its setup page, sometimes
    /// only after the manifest was fetched. When the viewer has opened another page meanwhile
    /// (Details, Reorder, the age check), a second cover can't present over it: the setup page
    /// never showed and the target was left set behind the page the viewer is on.
    private func offerSetup(_ target: AddonsModel.ConfigureTarget?) {
        guard let target, detail == nil, configure == nil, !organizeOpen, !ageGateOpen else { return }
        configure = target
    }

    private func tabButton(_ t: AddonsModel.Tab, _ title: String) -> some View {
        Button(title) { model.select(t) }.buttonStyle(BPActionStyle(primary: model.tab == t)).bpSelected(model.tab == t)
    }

    // MARK: Discover (discover-pane.tsx)

    private var discoverPane: some View {
        VStack(alignment: .leading, spacing: BP.px(40)) {
            if let s = model.spotlight {
                spotlightCard(s)
            } else if !model.spotlightFailed {
                RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel.opacity(0.5)).frame(height: BP.px(300))
            }
            communityRail
            categoryGrid
        }
    }

    /// addon-spotlight.tsx SpotlightCard.
    private func spotlightCard(_ s: AddonsModel.Spotlight) -> some View {
        let a = s.addon
        return ZStack(alignment: .bottomLeading) {
            if let bg = a.background { RemoteImage(url: bg).opacity(0.9) } else { LinearGradient(colors: [BP.elevated, BP.raised], startPoint: .topLeading, endPoint: .bottomTrailing) }
            LinearGradient(stops: [.init(color: .black.opacity(0.15), location: 0), .init(color: .black.opacity(0.45), location: 0.46),
                                   .init(color: .black.opacity(0.86), location: 0.82), .init(color: .black.opacity(0.95), location: 1)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.72), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.58, y: 0.5))
                .flipsForRightToLeftLayoutDirection(true)   // bp-addon-card.tsx SCRIM_RTL
            VStack(alignment: .leading, spacing: BP.px(12)) {
                Label(s.trending ? T("Trending on %@", "stremio-addons.net") : T("Top rated on %@", "stremio-addons.net"), systemImage: "chart.line.uptrend.xyaxis")
                    .font(BP.sans(11, .bold)).textCase(.uppercase).tracking(1.6).foregroundStyle(.white)
                HStack(spacing: BP.px(14)) {
                    if let logo = a.logo {
                        RemoteImage(url: logo, contentMode: .fit).frame(width: BP.px(56), height: BP.px(56)).padding(BP.px(6))
                            .background(RoundedRectangle(cornerRadius: BP.px(10)).fill(BP.canvas.opacity(0.85)))
                    }
                    VStack(alignment: .leading, spacing: BP.px(4)) {
                        Text(a.name).font(BP.display(28)).foregroundStyle(.white).lineLimit(1)
                        HStack(spacing: BP.px(6)) {
                            Image(systemName: "star.fill").foregroundStyle(BP.accent).accessibilityHidden(true)
                            Text(verbatim: "\(Int(a.stars).formatted()) \(T("stars"))")
                            if !a.types.isEmpty { Text("· " + a.types.joined(separator: " · ")).foregroundStyle(.white.opacity(0.45)) }
                        }
                        .font(BP.sans(13, .semibold)).foregroundStyle(.white.opacity(0.85))
                    }
                }
                if !a.description.isEmpty {
                    Text(a.description).font(BP.sans(14)).foregroundStyle(.white.opacity(0.75)).lineLimit(2).frame(maxWidth: BP.px(700), alignment: .leading)
                }
                HStack(spacing: BP.px(12)) {
                    if a.installed {
                        Label(T("Installed"), systemImage: "checkmark").font(BP.sans(14, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, BP.px(18)).frame(minHeight: BP.tabItem).background(Capsule().fill(.white.opacity(0.15)))
                    } else {
                        Button { Task { let setup = await model.install(a); offerSetup(setup) } } label: {
                            Label(model.busy.contains(a.key) ? T("Installing…") : T("Install"), systemImage: "plus")
                        }
                        .buttonStyle(BPActionStyle(primary: true, busy: model.busy.contains(a.key)))
                    }
                    Button(T("Details")) { detail = .init(id: a.addonId) }.buttonStyle(BPActionStyle())
                }
                .focusSection()
            }
            .padding(BP.px(30))
        }
        .frame(maxWidth: .infinity, minHeight: BP.px(300), maxHeight: BP.px(300))
        .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
    }

    /// community-addons-rail.tsx.
    private var communityRail: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    Text(T("Community index")).font(BP.sans(11, .bold)).textCase(.uppercase).tracking(2).foregroundStyle(BP.accent)
                    Text(verbatim: "\(T("From")) stremio-addons.net").font(BP.sans(24, .medium)).foregroundStyle(BP.ink)
                    Text(T("Ranked by the %@ community from their public index.", "stremio-addons.net")).font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                }
                Spacer()
                HStack(spacing: BP.px(8)) {
                    ForEach(AddonsModel.RailMode.allCases, id: \.self) { m in
                        Button(T(railLabel(m))) { Task { await model.setRailMode(m) } }.buttonStyle(BPActionStyle(primary: model.railMode == m)).bpSelected(model.railMode == m)
                    }
                }
                .focusSection()
            }
            if let rail = model.rail {
                if rail.isEmpty {
                    BPNote(text: "No addons match these filters right now.")
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: BP.trackGap) {
                            ForEach(rail) { c in
                                AddonTile(card: c) { detail = .init(id: c.addonId) }
                                    .contextMenu {
                                        Button(T("Install")) { Task { let setup = await model.install(c); offerSetup(setup) } }
                                        Button(T("Details")) { detail = .init(id: c.addonId) }
                                    }
                            }
                        }
                        .padding(.vertical, BP.px(14))
                    }
                    .scrollClipDisabled()
                    .focusSection()
                }
            } else {
                ProgressView().tint(BP.inkMuted)
            }
        }
    }

    private func railLabel(_ m: AddonsModel.RailMode) -> String {
        switch m {
        case .trending: return "Trending"
        case .stars: return "Top rated"
        case .createdAt: return "Just added"
        }
    }

    /// category-grid.tsx CATEGORY_TILES.
    private struct CategoryTile: Identifiable { var cat: String; var title: String; var blurb: String; var colors: [Color]; var icon: String; var id: String { cat } }
    private static let categoryTiles: [CategoryTile] = [
        CategoryTile(cat: "http+streams", title: "Streaming", blurb: "Where your video comes from", colors: [Color(hex: 0xf59e0b), Color(hex: 0xea580c)], icon: "play.rectangle"),
        CategoryTile(cat: "metadata", title: "Catalogs", blurb: "Posters, ratings, lists", colors: [Color(hex: 0x3b82f6), Color(hex: 0x4f46e5)], icon: "square.grid.2x2"),
        CategoryTile(cat: "subtitles", title: "Subtitles", blurb: "Captions in your language", colors: [Color(hex: 0x8b5cf6), Color(hex: 0xc026d3)], icon: "captions.bubble"),
        CategoryTile(cat: "anime", title: "Anime", blurb: "Kitsu, MAL, season-aware", colors: [Color(hex: 0xf43f5e), Color(hex: 0xdb2777)], icon: "sparkles"),
        CategoryTile(cat: "torrents", title: "Torrents", blurb: "P2P sources, debrid-ready", colors: [Color(hex: 0x10b981), Color(hex: 0x0d9488)], icon: "arrow.down.circle"),
        CategoryTile(cat: "live+tv", title: "Live TV", blurb: "OTA channels + IPTV", colors: [Color(hex: 0x06b6d4), Color(hex: 0x0284c7)], icon: "antenna.radiowaves.left.and.right"),
    ]

    private var categoryGrid: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            Text(T("Browse by category")).font(BP.display(26, .medium)).foregroundStyle(BP.ink)
            Text(T("Six places to start. Tap one and we'll filter the catalog for you.")).font(BP.sans(14)).foregroundStyle(BP.inkMuted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BP.px(14)), count: 3), spacing: BP.px(14)) {
                ForEach(Self.categoryTiles) { tile in
                    Button { model.goToCategory(tile.cat) } label: {
                        ZStack(alignment: .bottomLeading) {
                            LinearGradient(colors: tile.colors.map { $0.opacity(0.4) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                            LinearGradient(colors: [BP.canvas.opacity(0.85), BP.canvas.opacity(0.3), .clear], startPoint: .bottom, endPoint: .top)
                            Image(systemName: tile.icon).font(.system(size: BP.px(40))).foregroundStyle(BP.ink.opacity(0.55)).accessibilityHidden(true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(BP.px(16))
                            VStack(alignment: .leading, spacing: BP.px(2)) {
                                Text(T(tile.title)).font(BP.display(20, .medium)).foregroundStyle(BP.ink)
                                Text(T(tile.blurb)).font(BP.sans(12)).foregroundStyle(BP.inkMuted)
                            }
                            .padding(BP.px(18))
                        }
                        .frame(height: BP.px(120))
                        .clipShape(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous))
                    }
                    .buttonStyle(BPTileStyle(radius: BP.rMD))
                }
            }
            .focusSection()
        }
    }

    // MARK: Browse (browse-pane.tsx / community-browse-list.tsx)

    private var browsePane: some View {
        VStack(alignment: .leading, spacing: BP.px(18)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BP.px(8)) {
                    let searching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
                    Button(T("All")) { model.setCategory(nil) }.buttonStyle(BPActionStyle(primary: model.category == nil || searching)).bpSelected(model.category == nil || searching)
                    ForEach(model.categories.filter { adult || $0.slug != "nsfw" }) { c in
                        Button(c.name) { model.setCategory(c.slug) }.buttonStyle(BPActionStyle(primary: model.category == c.slug && !searching)).bpSelected(model.category == c.slug && !searching)
                    }
                    Rectangle().fill(BP.edge).frame(width: 1, height: BP.px(26)).padding(.horizontal, BP.px(4))
                    ForEach(AddonsModel.BrowseMode.allCases, id: \.self) { m in
                        Button { model.setMode(m) } label: { Label(T(modeLabel(m).label), systemImage: modeLabel(m).icon) }
                            .buttonStyle(BPActionStyle(primary: model.mode == m)).bpSelected(model.mode == m)
                    }
                }
                .padding(.vertical, BP.px(8))
            }
            .scrollClipDisabled()
            .focusSection()
            Text(T(modeLabel(model.mode).sub)).font(BP.sans(13)).foregroundStyle(BP.inkSubtle)
            LazyVStack(alignment: .leading, spacing: BP.px(12)) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { i, c in
                    communityRow(c)
                        .onAppear { if i >= model.items.count - 6 { Task { await model.loadMoreBrowse() } } }
                }
            }
            if model.browseLoading {
                ProgressView().tint(BP.inkMuted).frame(maxWidth: .infinity)
            } else if model.items.isEmpty {
                if model.browseEmpty == "velocity" {
                    VStack(alignment: .leading, spacing: BP.px(6)) {
                        Text(T("No velocity data yet")).font(BP.display(18, .medium)).foregroundStyle(BP.ink)
                        BPNote(text: "Trending tracks star growth across your Harbor visits. Open the addons page again tomorrow and the top risers will appear here.")
                    }
                } else {
                    BPNote(text: "No addons match these filters right now.")
                }
            } else if !model.hasMore {
                Text(T("You've reached the end · %lld addons", model.items.count)).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).frame(maxWidth: .infinity)
            }
        }
    }

    /// community-browse-list.tsx: "+N / 24h" for the official list, "+N / 5d" for recorded velocity.
    private static func risingText(_ delta: Double, window: Double?) -> String {
        let days = clampedInt(window ?? 1)
        return "+\(clampedInt(delta)) / " + (days <= 1 ? "24h" : "\(days)d")
    }

    private func modeLabel(_ m: AddonsModel.BrowseMode) -> (label: String, sub: String, icon: String) {
        switch m {
        case .top: return ("Top rated", "By community stars", "star")
        case .rising: return ("Top rising", "Most starred in 24 hours", "chart.line.uptrend.xyaxis")
        case .new: return ("Just added", "Freshest on stremio-addons.net", "sparkles")
        }
    }

    /// community-browse-list.tsx CommunityRow: the row opens the detail page; Install sits beside it.
    private func communityRow(_ c: AddonsModel.Card) -> some View {
        HStack(spacing: BP.px(14)) {
            Button { detail = .init(id: c.addonId) } label: {
                HStack(alignment: .top, spacing: BP.px(18)) {
                    AddonLogoView(url: c.logo, name: c.name, side: BP.px(64))
                    VStack(alignment: .leading, spacing: BP.px(6)) {
                        HStack(spacing: BP.px(8)) {
                            Text(c.name).font(BP.sans(17, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                            if c.stars > 0 { AddonBadge(text: Int(c.stars).formatted(), icon: "star.fill", tint: BP.accent) }
                            if let r = c.rising {
                                AddonBadge(text: Self.risingText(r, window: c.risingWindow), icon: "chart.line.uptrend.xyaxis", tint: Color(hex: 0xfda4af))
                            }
                            if c.isNew { AddonBadge(text: T("New"), icon: "sparkles", tint: Color(hex: 0x6ee7b7)) }
                        }
                        Text(c.description).font(BP.sans(14)).foregroundStyle(BP.inkMuted).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Image(systemName: "chevron.forward").foregroundStyle(BP.inkSubtle).accessibilityHidden(true)
                }
                .padding(BP.px(18))
                .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
                .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
            }
            .buttonStyle(BPTileStyle(radius: BP.rMD))
            if c.installed {
                Text(T("Installed")).font(BP.sans(13, .semibold)).foregroundStyle(BP.accent)
                    .padding(.horizontal, BP.px(14)).frame(minHeight: BP.tabItem).background(Capsule().fill(BP.accent.opacity(0.15)))
            } else if !c.addonId.isEmpty {
                Button { Task { let setup = await model.install(c); offerSetup(setup) } } label: {
                    Label(model.busy.contains(c.key) ? T("Installing…") : T("Install"), systemImage: "plus")
                }
                .buttonStyle(BPActionStyle(primary: true, busy: model.busy.contains(c.key)))
            }
        }
        .focusSection()
    }

    // MARK: Installed (installed-pane.tsx)

    @ViewBuilder private var installedPane: some View {
        let list = model.filteredInstalled
        if model.installed.isEmpty {
            if model.catalogLoading || !model.catalogLoaded {
                HStack(spacing: BP.px(12)) { ProgressView().tint(BP.inkMuted); Text(T("Loading the catalog")).font(BP.sans(14)).foregroundStyle(BP.inkMuted) }
            } else {
                emptyPanel(title: T("No addons installed yet"), body: T("Head to Discover. Cinemeta and OpenSubtitles cover the basics; Torrentio + a debrid key cover almost everything else."))
            }
        } else if list.isEmpty {
            emptyPanel(title: T("No installed addon matches that."), body: T("Clear the search to see all %lld installed.", model.installed.count))
        } else {
            LazyVStack(alignment: .leading, spacing: BP.px(12)) {
                ForEach(list) { c in installedRow(c) }
            }
        }
    }

    /// Remove, then the ring goes to the Remove of the row now in its place (the next row, else
    /// the one before), or to the Installed tab when the list emptied.
    private func remove(_ c: AddonsModel.Card) {
        let list: [AddonsModel.Card] = model.filteredInstalled
        var neighbour: String?
        if let i = list.firstIndex(where: { $0.key == c.key }) {
            if i + 1 < list.count { neighbour = list[i + 1].key } else if i > 0 { neighbour = list[i - 1].key }
        }
        Task {
            await model.uninstall(c)
            guard !model.installed.contains(where: { $0.key == c.key }) else { return }
            // (review 24) Only while the Installed tab is still up: a viewer who went on to Discover
            // during the uninstall holds no installedFocus either, and was pulled back to the tab.
            guard model.tab == .installed else { return }
            guard installedFocus == nil || installedFocus == "remove:" + c.key else { return }
            if let neighbour, model.filteredInstalled.contains(where: { $0.key == neighbour }) {
                installedFocus = "remove:" + neighbour
            } else {
                installedFocus = "tab"
            }
        }
    }

    private func emptyPanel(title: String, body: String) -> some View {
        VStack(spacing: BP.px(8)) {
            Text(title).font(BP.display(22, .medium)).foregroundStyle(BP.ink)
            Text(body).font(BP.sans(14)).foregroundStyle(BP.inkMuted).multilineTextAlignment(.center).frame(maxWidth: BP.px(560))
        }
        .frame(maxWidth: .infinity).padding(BP.px(48))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel.opacity(0.5)))
    }

    private func installedRow(_ c: AddonsModel.Card) -> some View {
        let busy = model.busy.contains(c.key)
        return HStack(spacing: BP.px(12)) {
            Button { detail = .init(id: c.addonId) } label: {
                HStack(spacing: BP.px(16)) {
                    Text("\(c.position)").font(BP.sans(18, .bold)).monospacedDigit().foregroundStyle(BP.inkSubtle).frame(minWidth: BP.px(32))
                    AddonLogoView(url: c.logo, name: c.name, side: BP.px(52)).opacity(c.enabled ? 1 : 0.5)
                    VStack(alignment: .leading, spacing: BP.px(3)) {
                        Text(c.name).font(BP.sans(16, .semibold)).foregroundStyle(c.enabled ? BP.ink : BP.inkMuted).lineLimit(1)
                        Text(c.enabled ? c.subtitle : T("Off · catalogs and streams hidden")).font(BP.sans(13)).foregroundStyle(BP.inkMuted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(BP.px(14))
                .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
                .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
                .opacity(busy ? 0.6 : 1)
            }
            .buttonStyle(BPTileStyle(radius: BP.rMD))
            // (addons pass) The row's buttons stay while Remove runs (installed-pane.tsx shows
            // "Uninstalling" on the button itself): swapping them for a spinner threw the focus
            // ring off the Remove the viewer had just pressed, onto the row's tile.
            Button { guard !busy else { return }; Task { await model.setEnabled(c, !c.enabled) } } label: {
                Label(c.enabled ? T("Enabled") : T("Disabled"), systemImage: c.enabled ? "togglepower" : "poweroff")
            }
            .buttonStyle(BPActionStyle(primary: c.enabled, busy: busy))
            .accessibilityLabel(c.enabled ? T("Turn %@ off", c.name) : T("Turn %@ on", c.name))
            if c.configurable {
                Button {
                    guard !busy else { return }
                    configure = AddonsModel.ConfigureTarget(mode: .manage, name: c.name, logo: c.logo, configureUrl: c.configureUrl, manageId: c.addonId)
                } label: { Label(T("Manage"), systemImage: "slider.horizontal.3") }
                .buttonStyle(BPActionStyle(busy: busy))
            }
            Button { remove(c) } label: {
                Label(busy ? T("Uninstalling") : T("Remove"), systemImage: busy ? "hourglass" : "trash")
            }
            .buttonStyle(BPActionStyle(busy: busy))
            .focused($installedFocus, equals: "remove:" + c.key)
        }
        .focusSection()
    }
}

// MARK: - shared pieces

/// components/addon-logo.tsx: the manifest logo, or the name's first letter on a plate.
struct AddonLogoView: View {
    let url: String?
    let name: String
    let side: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.22, style: .continuous).fill(BP.panel2)
            if let url, !url.isEmpty {
                RemoteImage(url: url, contentMode: .fit).padding(side * 0.08)
            } else {
                Text(String(name.prefix(1)).uppercased()).font(BP.display(side * 0.3)).foregroundStyle(BP.inkMuted)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
    }
}

struct AddonBadge: View {
    let text: String
    let icon: String
    let tint: Color
    var body: some View {
        HStack(spacing: BP.px(4)) {
            Image(systemName: icon).font(.system(size: BP.px(9), weight: .bold)).accessibilityHidden(true)
            Text(text).font(BP.sans(11, .bold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, BP.px(7)).padding(.vertical, BP.px(3))
        .background(Capsule().fill(tint.opacity(0.15)))
        .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 1))
    }
}

/// tile-card.tsx / the community rail's tiles: logo, name, stars, one line of description.
struct AddonTile: View {
    let card: AddonsModel.Card
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: BP.px(10)) {
                HStack(spacing: BP.px(10)) {
                    AddonLogoView(url: card.logo, name: card.name, side: BP.px(48))
                    VStack(alignment: .leading, spacing: BP.px(3)) {
                        Text(card.name).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                        if card.stars > 0 {
                            Label(Int(card.stars).formatted(), systemImage: "star.fill").font(BP.sans(11, .bold)).foregroundStyle(BP.accent)
                        }
                    }
                }
                Text(card.subtitle.isEmpty ? card.description : card.subtitle).font(BP.sans(12)).foregroundStyle(BP.inkMuted).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                if card.installed {
                    Label(T("Installed"), systemImage: "checkmark").font(BP.sans(11, .semibold)).foregroundStyle(BP.accent)
                }
            }
            .padding(BP.px(16))
            .frame(width: BP.px(280), height: BP.px(160), alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
            .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
        }
        .buttonStyle(BPTileStyle(radius: BP.rMD))
    }
}

/// addons/toaster.tsx.
struct AddonToastView: View {
    let toast: AddonsModel.Toast
    var body: some View {
        HStack(spacing: BP.px(12)) {
            if let logo = toast.logo { AddonLogoView(url: logo, name: toast.name ?? "", side: BP.px(32)) }
            Image(systemName: toast.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(toast.ok ? BP.live : BP.danger).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BP.px(2)) {
                Text(toast.text).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink)
                if let n = toast.name { Text(n).font(BP.sans(12)).foregroundStyle(BP.inkMuted) }
            }
        }
        .padding(.horizontal, BP.px(20)).padding(.vertical, BP.px(12))
        .background(Capsule().fill(BP.panel))
        .overlay(Capsule().stroke(BP.edge2, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        .allowsHitTesting(false)
    }
}
