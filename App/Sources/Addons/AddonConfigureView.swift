import SwiftUI

/// installer-viewport.tsx + install-modal.tsx for a TV. Upstream opens an addon's /configure page
/// in a built-in browser and catches the install link; tvOS has no web view, so the setup page
/// opens on the phone from a QR, and the install link it produces comes back through phone typing
/// (PhoneTypingSheet) or the keyboard. The link is then read like install-modal's tryResolve
/// (new addon, update, or a re-configure that replaces the old entry) and installed with
/// installFromUrl. Mode .url is the header's "Add from URL" with no setup page.
struct AddonConfigureView: View {
    let target: AddonsModel.ConfigureTarget
    @ObservedObject var model: AddonsModel
    let onClose: () -> Void

    struct Match: Decodable {
        var url: String?
        var name: String?
        var logo: String?
        var version: String?
        var description: String?
        var matchKind: String?
        var replaceId: String?
        var replaceName: String?
        var error: String?
    }
    private enum Phase { case idle, reading, resolved(Match), installing(Match), done(replaced: Bool, name: String, logo: String?) }

    @State private var pasted = ""
    @State private var phase: Phase = .idle
    /// Cleared when this screen goes: the success card's late auto-close must not close a newer one (review 30).
    private final class Shown { var on = true }
    @State private var shown = Shown()
    @State private var error: String?
    @State private var phoneOpen = false
    @FocusState private var primaryFocused: Bool
    @FocusState private var installFocused: Bool
    @FocusState private var doneFocused: Bool

    private var hasSetupPage: Bool { target.mode != .url && (target.configureUrl?.isEmpty == false) }
    private var busy: Bool {
        switch phase { case .reading, .installing, .done: return true; default: return false }
    }

    var body: some View {
        ZStack {
            BPAmbientBackground()
                .onDisappear { shown.on = false }
            BP.void_.opacity(0.7).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(26)) {
                    heading
                    if case .done(let replaced, let name, let logo) = phase {
                        doneCard(replaced: replaced, name: name, logo: logo)
                    } else {
                        HStack(alignment: .top, spacing: BP.px(40)) {
                            if hasSetupPage { setupPage }
                            pasteColumn
                        }
                    }
                }
                .padding(BP.px(48))
                .frame(maxWidth: BP.px(1500), alignment: .leading)
                .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.panel))
                .padding(.vertical, BP.px(60))
                .frame(maxWidth: .infinity)
            }
        }
        .ignoresSafeArea()
        .onExitCommand { if !isInstalling { onClose() } }
        .onAppear {
            pasted = target.prefill
            if !target.prefill.isEmpty { Task { await read() } }
        }
        // (addons bug pass) The card read from the previous link kept its Install button after the
        // link was edited, so Install put in the old addon. A changed link has to be read again.
        .onChange(of: pasted) { _, _ in
            if case .resolved = phase { phase = .idle }
        }
        .fullScreenCover(isPresented: $phoneOpen) {
            PhoneTypingSheet(label: "Manifest URL", placeholder: "stremio://… or https://…/manifest.json", text: $pasted,
                             purpose: "Scan this with your phone camera, then paste the install link from the addon's setup page. It goes straight to this TV.",
                             onSubmit: { Task { await read() } }, onClose: { phoneOpen = false })
        }
    }

    private var isInstalling: Bool { if case .installing = phase { return true }; return false }

    // MARK: pieces

    private var heading: some View {
        HStack(spacing: BP.px(14)) {
            if let logo = target.logo { AddonLogoView(url: logo, name: target.name, side: BP.px(48)) }
            VStack(alignment: .leading, spacing: BP.px(4)) {
                Text(target.mode == .manage ? T("Manage addon") : T("Install addon")).font(BP.sans(11, .bold)).textCase(.uppercase).tracking(2.4).foregroundStyle(BP.accent)
                Text(target.mode == .url ? T("Add from URL") : T("Setup · %@", target.name)).font(BP.display(30)).foregroundStyle(BP.ink).lineLimit(1)
            }
            Spacer()
            Button(T("Cancel")) { onClose() }.buttonStyle(BPActionStyle()).disabled(isInstalling)
        }
        .focusSection()
    }

    /// The setup page for the phone. Its URL can carry the addon's current settings (debrid keys
    /// in a re-configure), so only the host is printed; the QR carries the whole link.
    private var setupPage: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            Text(T("Configure on the addon's setup page")).font(BP.sans(17, .semibold)).foregroundStyle(BP.ink)
            if let url = target.configureUrl, let qr = QRCode.image(url) {
                Image(uiImage: qr).interpolation(.none).resizable().frame(width: BP.px(260), height: BP.px(260)).accessibilityLabel(Text(T("QR code")))
                    .padding(BP.px(10)).background(Color.white).clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
                Text(URL(string: url)?.host ?? "").font(BP.sans(13, .semibold)).foregroundStyle(BP.inkSubtle)
            }
            BPNote(text: "Scan this with your phone to open the setup page. Pick your options there, then send the install link it gives you back to this TV.")
                .frame(maxWidth: BP.px(420), alignment: .leading)
            if target.mode == .manage {
                BPNote(text: "Heads-up: a few addons (like AIOStatus) don't pre-fill from the URL. If the form loads blank, paste the existing manifest URL into their \"Import from URL\" field to restore your settings.", tone: BP.inkSubtle)
                    .frame(maxWidth: BP.px(420), alignment: .leading)
            }
        }
    }

    private var pasteColumn: some View {
        VStack(alignment: .leading, spacing: BP.px(16)) {
            Text(T(hasSetupPage ? "Or paste the install link manually" : "Paste manifest URL or stremio:// link")).font(BP.sans(17, .semibold)).foregroundStyle(BP.ink)
            HStack(spacing: BP.px(12)) {
                Button { phoneOpen = true } label: { Label(T("Type on your phone"), systemImage: "iphone") }
                    .buttonStyle(BPActionStyle(primary: !hasResolved))
                    .focused($primaryFocused)
                    .disabled(busy)
            }
            .focusSection()
            BPField(label: "Manifest URL", placeholder: "stremio://… or https://…/manifest.json", text: $pasted, keyboard: .URL, phone: false)
                .disabled(busy)
            HStack(spacing: BP.px(12)) {
                Button(isReading ? T("Reading") : T("Read")) { Task { await read() } }
                    .buttonStyle(BPActionStyle(busy: isReading))
                    .disabled((busy && !isReading) || pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .focusSection()
            if let error { BPNote(text: error, tone: BP.danger) }
            // (addons pass) One card for Resolved and Installing: the Install / Update the viewer
            // pressed stays (busy) instead of vanishing with the focus on it, which left nothing
            // focused until the success card.
            if let m = cardMatch { resolvedCard(m) }
            if case .installing(let m) = phase {
                HStack(spacing: BP.px(12)) {
                    ProgressView().tint(BP.inkMuted)
                    VStack(alignment: .leading, spacing: BP.px(2)) {
                        Text(m.matchKind == "fresh" ? T("Installing %@", m.name ?? T("addon")) : T("Updating %@", m.name ?? T("addon")))
                            .font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
                        Text(T("Hang tight, won't be a sec.")).font(BP.sans(13)).foregroundStyle(BP.inkSubtle)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { primaryFocused = true }
    }

    private var hasResolved: Bool { if case .resolved = phase { return true }; return false }
    private var cardMatch: Match? {
        switch phase {
        case .resolved(let m), .installing(let m): return m
        default: return nil
        }
    }
    private var isReading: Bool { if case .reading = phase { return true }; return false }

    /// install-modal.tsx: the manifest it found, the re-configure notice, Install / Update.
    private func resolvedCard(_ m: Match) -> some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            HStack(spacing: BP.px(14)) {
                AddonLogoView(url: m.logo, name: m.name ?? "", side: BP.px(52))
                VStack(alignment: .leading, spacing: BP.px(3)) {
                    HStack(spacing: BP.px(8)) {
                        Text(m.name ?? "").font(BP.sans(17, .semibold)).foregroundStyle(BP.ink)
                        if let v = m.version { Text(verbatim: "v\(v)").font(BP.sans(12)).foregroundStyle(BP.inkSubtle) }
                    }
                    if let d = m.description, !d.isEmpty { Text(d).font(BP.sans(13)).foregroundStyle(BP.inkMuted).lineLimit(2) }
                }
            }
            if m.matchKind == "hostname-match", let old = m.replaceName {
                BPNote(text: T("Looks like a re-configure of %@. We'll replace the existing entry so you don't end up with two copies.", old))
            }
            Button(m.matchKind == "fresh" ? T("Install") : T("Update")) {
                guard !isInstalling else { return }
                Task { await install(m) }
            }
            .buttonStyle(BPActionStyle(primary: true, busy: isInstalling))
            .focused($installFocused)
            // (addons pass) install-modal.tsx's footer button turns from Continue into Install /
            // Update where it is. Here the card appears below: focus moves onto it, so a link sent
            // from the phone (or a stremio:// deep link) is one press from installed.
            .onAppear { installFocused = true }
            .focusSection()
        }
        .padding(BP.px(18))
        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel2))
    }

    private func doneCard(replaced: Bool, name: String, logo: String?) -> some View {
        VStack(spacing: BP.px(16)) {
            Image(systemName: "checkmark.circle").font(.system(size: BP.px(64), weight: .light)).foregroundStyle(BP.live).accessibilityHidden(true)
            AddonLogoView(url: logo, name: name, side: BP.px(56))
            Text(replaced ? T("Updated") : T("Installed")).font(BP.display(28)).foregroundStyle(BP.ink)
            Text(verbatim: "\(name) \(replaced ? T("is now using your new configuration.") : T("is ready. Open Discover or hit Play on a title to use it."))")
                .font(BP.sans(15)).foregroundStyle(BP.inkMuted).multilineTextAlignment(.center)
            Button(T("Done")) { onClose() }.buttonStyle(BPActionStyle(primary: true))
                .focused($doneFocused)
                .onAppear { doneFocused = true }
        }
        .frame(maxWidth: .infinity)
        .padding(BP.px(30))
    }

    // MARK: actions

    private func read() async {
        let raw = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !busy else { return }
        error = nil
        phase = .reading
        let manage: AnyJSON = target.mode == .manage && target.manageId != nil
            ? .object(["id": .string(target.manageId ?? ""), "name": .string(target.name)]) : .null
        let m: Match? = try? await HarborEngine.shared.call("addonsManager.resolveUrl", [raw, manage])
        // (bug pass) The link was edited while it was being read: this card is for the old one.
        guard pasted.trimmingCharacters(in: .whitespacesAndNewlines) == raw else { phase = .idle; return }
        guard let m, m.error == nil, m.url != nil else {
            phase = .idle
            error = m?.error ?? T("Couldn't read that addon URL.")
            return
        }
        phase = .resolved(m)
    }

    private func install(_ m: Match) async {
        guard let url = m.url else { return }
        phase = .installing(m)
        struct Result: Decodable { var ok: Bool; var replaced: Bool?; var id: String?; var name: String?; var logo: String?; var toast: String?; var message: String? }
        let r: Result? = try? await HarborEngine.shared.call("addonsManager.installUrl", [url, m.replaceId])
        guard let r, r.ok else {
            phase = .resolved(m)
            error = r?.message ?? T("Install failed.")
            return
        }
        let name = r.name ?? m.name ?? T("Addon")
        phase = .done(replaced: r.replaced ?? false, name: name, logo: r.logo ?? m.logo)
        await model.installedFromLink(id: r.id ?? "", name: name, logo: r.logo, toast: r.toast ?? T("Installed"))
        // installer-viewport.tsx: the success card closes itself after two seconds.
        let screen = shown   // held before the wait: @State read after the view is gone isn't reliable
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        // Only if this success card is still what's showing (Done may have closed it already) (review 30).
        guard screen.on else { return }
        onClose()
    }
}
