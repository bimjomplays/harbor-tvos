import SwiftUI

/// The channel list the two live overlays share: the in-player TV Guide
/// (components/player/live-channel-overlay/overlay.tsx) and the Multiview tile picker
/// (views/multiview/channel-picker.tsx). A category rail (Favorites, All channels, the source's
/// groups), a search field, and one row per channel with what is on now.
struct LiveChannelBrowser: View {
    /// Which upstream screen's copy the empty states use.
    enum Copy { case playerGuide, multiview }
    static let favKey = "__FAVS__"

    let channels: [LiveModel.Channel]
    /// Group names in the source's order (relevance-sorted by the engine).
    let groups: [String]
    let guide: [String: LiveModel.NowNext]
    let currentId: String?
    let copy: Copy
    /// nil = All channels, `favKey` = Favorites, else a group name.
    @Binding var group: String?
    @Binding var query: String
    var loading = false
    /// Fetch now/next for the rows on screen (the engine answers per id list).
    var loadGuide: (([String]) async -> Void)? = nil
    let onPick: (LiveModel.Channel) -> Void

    /// channel-picker.tsx RENDER_CAP; the player guide virtualises instead, so it shows every row.
    private static let renderCap = 240
    @FocusState private var focused: String?
    /// Channels whose now/next was asked for by a row coming on screen.
    @State private var asked: Set<String> = []

    /// (live sources device pass) use-channel-filter is a useMemo over (channels, group, query). Here
    /// the whole source was filtered again, every name lowercased, on each render, and the list
    /// renders on every now/next merge as rows scroll in (6,000 channels, a few times a second).
    /// The result is kept until one of the three changes; an unchanged `channels` array compares
    /// by storage in O(1).
    private final class FilterMemo {
        var channels: [LiveModel.Channel] = []
        var group: String?
        var query = ""
        var built = false
        var result: [LiveModel.Channel] = []
        var favorites = 0
    }
    @State private var memo = FilterMemo()

    private var favoriteCount: Int { _ = filtered; return memo.favorites }

    /// use-channel-filter / channel-picker filtered: the rail choice, then the query on name or group.
    private var filtered: [LiveModel.Channel] {
        if memo.built, memo.group == group, memo.query == query, memo.channels == channels { return memo.result }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let out: [LiveModel.Channel] = channels.filter { c in
            if group == Self.favKey && !c.favorite { return false }
            if let g = group, g != Self.favKey, (c.group ?? "Uncategorized") != g { return false }
            // (open-items sweep) use-channel-filter: arabicAwareMatch over "name group".
            if !q.isEmpty && !ArabicMatch.matches(c.name + " " + (c.group ?? ""), q) { return false }
            return true
        }
        var favorites = 0
        for c in channels where c.favorite { favorites += 1 }
        memo.channels = channels
        memo.group = group
        memo.query = query
        memo.result = out
        memo.favorites = favorites
        memo.built = true
        return out
    }

    var body: some View {
        let all = filtered
        let shown = copy == .multiview ? Array(all.prefix(Self.renderCap)) : all
        HStack(alignment: .top, spacing: BP.px(24)) {
            rail
                .frame(width: BP.px(300))
            VStack(alignment: .leading, spacing: BP.px(10)) {
                if loading && channels.isEmpty {
                    HStack(spacing: BP.px(10)) {
                        ProgressView().tint(BP.inkMuted)
                        Text("Loading channels…").font(BP.sans(14)).foregroundStyle(BP.inkMuted)
                    }
                    .padding(.top, BP.px(20))
                } else if shown.isEmpty {
                    BPNote(text: emptyText).padding(.top, BP.px(20))
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: BP.px(6)) {
                                ForEach(Array(shown.enumerated()), id: \.element.id) { i, ch in
                                    // (bug pass) Only the first 120 rows were ever asked for now/next;
                                    // a row further down (the playing channel, a scroll) said "Live".
                                    row(ch).id(ch.id).onAppear { askGuide(shown, from: i) }
                                }
                                if shown.count < all.count {
                                    // channel-picker.tsx: the cap note under the list.
                                    BPNote(text: T("Showing %lld of %lld. Refine the search to see more.", shown.count, all.count))
                                        .padding(.top, BP.px(8))
                                }
                            }
                            .padding(.vertical, BP.px(8)).padding(.horizontal, BP.px(10))
                            .padding(.bottom, BP.px(40))
                        }
                        .focusSection()
                        .onAppear {
                            // The ring lands on the playing channel (or the first row), never on the
                            // search field; a lazy row far down is scrolled into being first.
                            let playing = currentId.flatMap { id in shown.contains(where: { $0.id == id }) ? id : nil }
                            let target = playing ?? shown.first?.id
                            if let playing { proxy.scrollTo(playing, anchor: .center) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = target }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(group ?? "")|\(query)|\(channels.count)") {
            // Typing settles for a moment before the guide is asked (the task restarts per key).
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            await loadGuide?(shown.prefix(120).map(\.id))
        }
    }

    /// Now/next for a row that came on screen without it, and the rows after it (40 per ask).
    private func askGuide(_ list: [LiveModel.Channel], from i: Int) {
        guard let loadGuide, i >= 0, i < list.count, guide[list[i].id] == nil, !asked.contains(list[i].id) else { return }
        let ids = list[i..<min(list.count, i + 40)].map(\.id).filter { guide[$0] == nil && !asked.contains($0) }
        asked.formUnion(ids)
        Task { await loadGuide(ids) }
    }

    private var emptyText: String {
        switch copy {
        case .playerGuide:
            if group == Self.favKey && favoriteCount == 0 { return "No favorites yet. Star a channel to pin it here." }
            return "No channels match. Try a different category or clear the search."
        case .multiview:
            if group == Self.favKey { return "No favorites yet. Star channels to pin them here." }
            return "No channels match. Try another group or paste a URL."
        }
    }

    // category-sidebar.tsx / channel-picker RailItem: Favorites, All channels, then each group.
    private var rail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: BP.px(6)) {
                railItem(key: Self.favKey, label: T("Favorites"), count: favoriteCount, star: true)
                railItem(key: nil, label: T("All channels"), count: channels.count, star: false)
                ForEach(groups, id: \.self) { g in
                    railItem(key: g, label: g, count: nil, star: false)
                }
            }
            .padding(.vertical, BP.px(8)).padding(.horizontal, BP.px(8))
        }
        .focusSection()
    }

    private func railItem(key: String?, label: String, count: Int?, star: Bool) -> some View {
        let active = group == key
        return Button {
            group = key
        } label: {
            HStack(spacing: BP.px(8)) {
                if star { Image(systemName: (count ?? 0) > 0 ? "star.fill" : "star").accessibilityHidden(true) }
                Text(label).lineLimit(1)
                Spacer(minLength: 0)
                if let count, count > 0 { Text("\(count)").opacity(0.55) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(BPActionStyle(primary: active))
        .bpSelected(active)
    }

    private func row(_ ch: LiveModel.Channel) -> some View {
        let nn = guide[ch.id]
        let isCurrent = ch.id == currentId
        return Button { onPick(ch) } label: {
            HStack(spacing: BP.px(14)) {
                RemoteImage(url: ch.logo, contentMode: .fit)
                    .frame(width: BP.px(72), height: BP.px(40))
                    .background(RoundedRectangle(cornerRadius: BP.px(6), style: .continuous).fill(BP.void_.opacity(0.6)))
                VStack(alignment: .leading, spacing: BP.px(2)) {
                    HStack(spacing: BP.px(6)) {
                        if ch.favorite { Image(systemName: "star.fill").font(.system(size: BP.px(10))).foregroundStyle(BP.inkMuted).accessibilityLabel(Text(T("Favorite"))) }
                        Text(ch.shownName).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                        if let b = ch.badge {
                            Text(b).font(BP.sans(9, .bold)).foregroundStyle(BP.inkMuted)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(BP.edge2, lineWidth: 1))
                        }
                    }
                    if let g = ch.groupLabel ?? ch.group { Text(g).font(BP.sans(10)).foregroundStyle(BP.inkSubtle).lineLimit(1) }
                }
                .frame(width: BP.px(240), alignment: .leading)
                HStack(spacing: BP.px(8)) {
                    Circle().fill(BP.live).frame(width: BP.px(6), height: BP.px(6))
                    Text(nn?.now?.title ?? T(nn?.known == true ? "No program info" : "Live"))
                        .font(BP.sans(13, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                    if let p = nn?.now { Text(LiveChannelRow.range(p)).font(BP.sans(11)).foregroundStyle(BP.inkMuted).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(BP.accent).accessibilityLabel(Text(T("Now playing")))
                }
            }
            .padding(.horizontal, BP.px(12)).padding(.vertical, BP.px(8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(isCurrent ? BP.on : BP.panel2))
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM))
        .focused($focused, equals: ch.id)
    }
}

/// components/player/live-channel-overlay/overlay.tsx on the TV: the in-player TV Guide. Close,
/// the playing channel's card (current-channel-info.tsx), a search field, then the shared list.
/// Picking a channel switches the stream in place (use-live-channel-overlay switchChannel).
struct LivePlayerGuidePanel: View {
    @ObservedObject var model: LiveModel
    let current: LiveModel.Channel?
    let onPick: (LiveModel.Channel) -> Void
    let onClose: () -> Void

    @State private var group: String?
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// overlay.tsx defaultedGroupRef: open on the playing channel's group, else Favorites.
    /// (player/live device pass) Chosen before the first render: set in onAppear it came after the
    /// list had already scrolled to the playing channel in All channels and asked for its ring, so
    /// the swap to the group's list left the ring short of the playing channel (or off the list).
    @MainActor
    init(model: LiveModel, current: LiveModel.Channel?, onPick: @escaping (LiveModel.Channel) -> Void, onClose: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.current = current
        self.onPick = onPick
        self.onClose = onClose
        var start: String? = nil
        if let g = current?.group, model.groups.contains(where: { $0.name == g }) { start = g }
        else if model.channels.contains(where: \.favorite) { start = LiveChannelBrowser.favKey }
        _group = State(initialValue: start)
    }

    private var groupNames: [String] { model.groups.map(\.name) }

    // overlay.tsx search placeholder: the favourites count in Favorites, else the source's channels.
    private var searchPlaceholder: String {
        if group == LiveChannelBrowser.favKey {
            let n = model.favoriteCount
            return n == 1 ? T("Search %lld favorite", n) : T("Search %lld favorites", n)
        }
        return T("Search %lld channels", model.channels.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(16)) {
            HStack(alignment: .top, spacing: BP.px(16)) {
                Button(action: onClose) { Label("Close", systemImage: "xmark") }
                    .buttonStyle(BPActionStyle())
                LiveCurrentChannelInfo(channel: current, nowNext: current.flatMap { model.guide[$0.id] })
            }
            .focusSection()
            HStack(spacing: BP.px(12)) {
                LiveSearchField(placeholder: searchPlaceholder, text: $query)
                    .frame(maxWidth: BP.px(620))
                    .focused($searchFocused)
                // (device-flow pass 4) Clear leaves with the query it clears: the ring goes to the field.
                if !query.isEmpty { Button("Clear") { searchFocused = true; query = "" }.buttonStyle(BPActionStyle()) }
            }
            .focusSection()
            LiveChannelBrowser(channels: model.channels, groups: groupNames, guide: model.guide, currentId: current?.id,
                               copy: .playerGuide, group: $group, query: $query, loading: model.loading,
                               loadGuide: { ids in await model.refreshNowNext(ids: ids) }, onPick: onPick)
        }
        .padding(.horizontal, BP.gutter).padding(.top, BP.px(40))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BP.canvas.opacity(0.95).ignoresSafeArea())
    }
}

/// current-channel-info.tsx: logo, name, the "Live" label, what is on now with minutes left.
struct LiveCurrentChannelInfo: View {
    let channel: LiveModel.Channel?
    let nowNext: LiveModel.NowNext?

    var body: some View {
        HStack(spacing: BP.px(14)) {
            if let channel {
                RemoteImage(url: channel.logo, contentMode: .fit)
                    .frame(width: BP.px(96), height: BP.px(54))
                    .background(RoundedRectangle(cornerRadius: BP.px(6), style: .continuous).fill(BP.void_.opacity(0.6)))
                VStack(alignment: .leading, spacing: BP.px(4)) {
                    HStack(spacing: BP.px(8)) {
                        Text(channel.shownName).font(BP.sans(18, .bold)).foregroundStyle(BP.ink).lineLimit(1)
                        HStack(spacing: BP.px(5)) {
                            Circle().fill(BP.live).frame(width: BP.px(6), height: BP.px(6))
                            Text("Live").font(BP.sans(10, .bold)).textCase(.uppercase).tracking(1).foregroundStyle(BP.live)
                        }
                    }
                    if let p = nowNext?.now {
                        let now = Date().timeIntervalSince1970 * 1000
                        let left = max(0, Int(((p.endMs - now) / 60_000).rounded(.up)))
                        HStack(spacing: BP.px(8)) {
                            Text(p.title).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                            Text(LiveChannelRow.range(p)).font(BP.sans(12)).foregroundStyle(BP.inkMuted)
                            Text("\(left)m left").font(BP.sans(12)).foregroundStyle(BP.inkMuted).monospacedDigit()
                        }
                    } else {
                        Text("No program info available").font(BP.sans(12.5)).foregroundStyle(BP.inkSubtle)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A Big Picture search input without a caption; Select opens the tvOS keyboard (BPField's rule).
struct LiveSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: BP.px(10)) {
            Image(systemName: "magnifyingglass").foregroundStyle(BP.inkSubtle).accessibilityHidden(true)
            TextField(T(placeholder), text: $text)
                .font(BP.sans(17))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, BP.px(14))
        .frame(height: BP.px(50))
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
        .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge2, lineWidth: 1))
    }
}

/// (open-items sweep) lib/iptv/rtl.ts arabicAwareMatch: a plain lowercase match first; when either
/// side has Arabic, both are normalized (NFKC, no invisible marks or harakat/tatweel, alef/teh
/// marbuta/alef maksura/hamza seats folded, Arabic-Indic digits to ASCII, spaces collapsed) so a
/// query typed without diacritics or with another alef still finds the channel.
enum ArabicMatch {
    private static func within(_ c: UInt32, _ lo: UInt32, _ hi: UInt32) -> Bool { c >= lo && c <= hi }

    /// rtl.ts ARABIC_RANGE.
    static func hasArabic(_ s: String) -> Bool {
        for v in s.unicodeScalars {
            let c: UInt32 = v.value
            if within(c, 0x0600, 0x06FF) || within(c, 0x0750, 0x077F) || within(c, 0x08A0, 0x08FF) { return true }
            if within(c, 0xFB50, 0xFDFF) || within(c, 0xFE70, 0xFEFF) { return true }
        }
        return false
    }

    /// rtl.ts normalizeArabic.
    static func normalize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var lastSpace = false
        for v in s.precomposedStringWithCompatibilityMapping.unicodeScalars {
            let c: UInt32 = v.value
            // INVISIBLE, then HARAKAT (U+064B–U+0652, superscript alef, tatweel).
            if within(c, 0x200B, 0x200F) || within(c, 0x202A, 0x202E) || within(c, 0x2066, 0x2069) || c == 0xFEFF { continue }
            if within(c, 0x064B, 0x0652) || c == 0x0670 || c == 0x0640 { continue }
            var mapped: Unicode.Scalar = v
            switch c {
            case 0x0623, 0x0625, 0x0622, 0x0671: mapped = "\u{0627}"
            case 0x0629: mapped = "\u{0647}"
            case 0x0649, 0x0626: mapped = "\u{064A}"
            case 0x0624: mapped = "\u{0648}"
            default:
                if within(c, 0x0660, 0x0669) || within(c, 0x06F0, 0x06F9) {
                    mapped = Unicode.Scalar(0x30 + (c & 0xF)) ?? v
                }
            }
            if mapped.properties.isWhitespace {
                if !lastSpace { out.append(" ") }
                lastSpace = true
                continue
            }
            lastSpace = false
            out.append(mapped)
        }
        return String(out).lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// rtl.ts arabicAwareMatch(haystack, needleLower).
    static func matches(_ haystack: String, _ needleLower: String) -> Bool {
        if haystack.lowercased().contains(needleLower) { return true }
        if !hasArabic(haystack) && !hasArabic(needleLower) { return false }
        return normalize(haystack).contains(normalize(needleLower))
    }
}
