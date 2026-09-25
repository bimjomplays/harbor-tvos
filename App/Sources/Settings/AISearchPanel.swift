import SwiftUI

/// views/settings/ai-search-section.tsx on the TV (Settings → Setup → AI search): the provider tab
/// (OpenRouter / Groq), that provider's key, its model list, a custom model id, and the live web
/// context (Jina Reader). Keys are typed on the phone (BPField phone:) and kept in the Keychain by
/// engine/aiSearch.ts; the panel only ever sees a masked tail of a saved key.
struct AISearchPanel: View {
    let onClose: () -> Void

    @State private var state: AISearchModel.State?
    @State private var models: AISearchModel.Models?
    @State private var keyDraft = ""
    @State private var jinaDraft = ""
    @State private var customDraft = ""
    /// ai-search-section.tsx savedFlags: "Saved" flashes for 1.8 s after a save.
    @State private var flash = false

    private var profile: (id: String, linked: Bool) {
        let p = ProfilesStore.shared.active
        return (p?.id ?? "default", p?.linked ?? true)
    }
    private var groq: Bool { state?.tab == "groq" }
    private var tabModels: [AISearchModel.ModelRow] { (groq ? models?.groq : models?.openrouter) ?? [] }

    var body: some View {
        ZStack {
            BP.void_.opacity(0.95).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(22)) {
                    HStack {
                        Text("AI search").font(BP.display(32)).foregroundStyle(BP.ink)
                        Spacer()
                        Button("Close") { onClose() }.buttonStyle(BPActionStyle())
                    }
                    providerRow
                    keyRow
                    modelRows
                    customRow
                    webRows
                }
                .padding(.horizontal, BP.px(60)).padding(.vertical, BP.px(50))
                .frame(width: BP.px(980), alignment: .leading)
            }
        }
        .onExitCommand { onClose() }
        .task { await load() }
    }

    // MARK: rows

    /// SettingRow "Provider" + Segmented (OpenRouter / Groq).
    private var providerRow: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            sectionLabel(T("Provider"))
            Text(T("Type what you want in plain language and let a model find it. Bring your own API key from either service."))
                .font(BP.sans(14)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: BP.px(8)) {
                ForEach(["openrouter", "groq"], id: \.self) { tab in
                    Button { Task { await setProvider(tab) } } label: {
                        Text(verbatim: tab == "groq" ? "Groq" : "OpenRouter").frame(minWidth: BP.px(140))
                    }
                    .buttonStyle(BPActionStyle(primary: (state?.tab ?? "openrouter") == tab))
                    .accessibilityIdentifier("ai-provider-\(tab)")
                    .bpSelected((state?.tab ?? "openrouter") == tab)
                }
            }
        }
        .focusSection()
    }

    /// KeyField: the chosen provider's key, typed on the phone; Save writes the trimmed draft.
    private var keyRow: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            BPField(label: groq ? "AI Search · Groq LPU inference" : "AI Search · natural-language search",
                    placeholder: groq ? "Groq API key (gsk-...)" : "OpenRouter API key (sk-or-...)",
                    text: $keyDraft, secure: true, phone: true)
            HStack(spacing: BP.px(10)) {
                // (settings device pass) Dimmed, not disabled, while the draft is empty: a save
                // clears the draft, and disabling the focused button threw the ring off it.
                let keyEmpty = keyDraft.trimmingCharacters(in: .whitespaces).isEmpty
                Button(T("Save")) {
                    guard !keyEmpty else { return }
                    Task { await saveKey(groq ? "groq" : "openrouter", keyDraft) }
                }
                    .buttonStyle(BPActionStyle(primary: true, busy: keyEmpty))
                    .accessibilityIdentifier("ai-key-save")
                if let mask = groq ? state?.saved.groq : state?.saved.openrouter {
                    Button(T("Remove")) { Task { await saveKey(groq ? "groq" : "openrouter", "") } }
                        .buttonStyle(BPActionStyle())
                    Text(verbatim: "\(T("Saved")) · \(mask)").font(BP.sans(13, .semibold))
                        .foregroundStyle(flash ? BP.accent : BP.inkSubtle)
                }
            }
            Text(verbatim: help).font(BP.sans(13)).foregroundStyle(BP.inkSubtle).fixedSize(horizontal: false, vertical: true)
        }
        .focusSection()
    }

    /// The KeyField help line, links as plain addresses (the TV has no browser).
    private var help: String {
        let lead = T("Adds an \"Ask AI\" button to search, so you can type things like a plain-language request.")
        if groq {
            return "\(lead) \(T("Get a key at")) console.groq.com/keys. \(T("Groq runs open-source models on its LPU hardware with a generous free tier; every model listed below runs on the free tier."))"
        }
        return "\(lead) \(T("Get a key at")) openrouter.ai/keys. \(T("It only runs when you tap that button, so it never costs anything unless you ask."))"
    }

    /// AiModelSelect: the tab's models (pruned to the provider's live catalog), tags and maker.
    private var modelRows: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            sectionLabel(T("AI model"))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: BP.px(8)), GridItem(.flexible(), spacing: BP.px(8))], spacing: BP.px(8)) {
                ForEach(tabModels) { m in
                    Button { Task { await setModel(m.id) } } label: { modelCell(m, on: m.id == state?.model) }
                        .buttonStyle(BPTileStyle(radius: BP.rSM))
                        .bpSelected(m.id == state?.model)
                }
            }
        }
        .focusSection()
    }

    private func modelCell(_ m: AISearchModel.ModelRow, on: Bool) -> some View {
        HStack(spacing: BP.px(10)) {
            VStack(alignment: .leading, spacing: BP.px(4)) {
                Text(verbatim: m.label).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                HStack(spacing: BP.px(6)) {
                    if m.recommended { tag(T("Recommended")) }
                    if m.free { tag(m.provider == "groq" ? T("Free tier") : T("Free")) }
                    Text(verbatim: m.providerName).font(BP.sans(10, .bold)).textCase(.uppercase).tracking(1).foregroundStyle(BP.inkSubtle)
                }
            }
            Spacer(minLength: 0)
            if on { Image(systemName: "checkmark").font(.system(size: BP.px(14), weight: .bold)).foregroundStyle(BP.accent).accessibilityHidden(true) }
        }
        .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(on ? BP.on : BP.panel))
        .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).strokeBorder(on ? .clear : BP.edge, lineWidth: 1))
    }

    private func tag(_ text: String) -> some View {
        Text(verbatim: text).font(BP.sans(9, .bold)).textCase(.uppercase).foregroundStyle(BP.accent)
            .padding(.horizontal, BP.px(6)).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: BP.px(5), style: .continuous).fill(BP.accent.opacity(0.15)))
    }

    /// SettingRow "Custom model id": any id the provider serves.
    private var customRow: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            BPField(label: "Custom model id", placeholder: groq ? "llama-3.3-70b-versatile" : "vendor/model-name:free", text: $customDraft, phone: true)
            Text(T(groq ? "Any model id from console.groq.com/docs/models works here." : "Any model id from openrouter.ai/models works here, including :free variants."))
                .font(BP.sans(13)).foregroundStyle(BP.inkSubtle)
            Button(T("Use model")) {
                let id = customDraft.trimmingCharacters(in: .whitespaces)
                Task { await setModel(id) }
            }
            .buttonStyle(BPActionStyle())
            .disabled(customDraft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .focusSection()
    }

    /// Section "Live web": Jina Reader, the aiWebSearch toggle, the optional Jina key.
    private var webRows: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            sectionLabel(T("Live web"))
            Text(verbatim: "\(T("Augments AI picks with current web results before asking the model. Powered by")) Jina Reader. \(T("Works without a key at low volume; add a key for higher quotas."))")
                .font(BP.sans(13)).foregroundStyle(BP.inkSubtle).fixedSize(horizontal: false, vertical: true)
            Button { Task { await setWebSearch(!(state?.webSearch ?? false)) } } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("Use live web context")).font(BP.sans(15, .semibold))
                        Text(T("Fetches DuckDuckGo results and feeds top hits into the model prompt.")).font(BP.sans(11)).foregroundStyle(BP.inkMuted)
                    }
                    Spacer()
                    Text(T(state?.webSearch == true ? "On" : "Off")).font(BP.sans(14, .bold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(BPActionStyle(primary: state?.webSearch == true)).bpSelected(state?.webSearch == true)
            BPField(label: "Jina API key (optional)", placeholder: "jina_...", text: $jinaDraft, secure: true, phone: true)
            HStack(spacing: BP.px(10)) {
                let jinaEmpty = jinaDraft.trimmingCharacters(in: .whitespaces).isEmpty
                Button(T("Save")) {
                    guard !jinaEmpty else { return }
                    Task { await saveKey("jina", jinaDraft) }
                }
                    .buttonStyle(BPActionStyle(busy: jinaEmpty))
                if let mask = state?.saved.jina {
                    Button(T("Remove")) { Task { await saveKey("jina", "") } }.buttonStyle(BPActionStyle())
                    Text(verbatim: "\(T("Saved")) · \(mask)").font(BP.sans(13, .semibold)).foregroundStyle(BP.inkSubtle)
                }
            }
            Text(verbatim: "\(T("Get a key at")) jina.ai/reader \(T("for higher rate limits; leave blank for the free anonymous tier."))")
                .font(BP.sans(13)).foregroundStyle(BP.inkSubtle).fixedSize(horizontal: false, vertical: true)
        }
        .focusSection()
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(verbatim: text.uppercased()).font(BP.sans(11, .bold)).tracking(1.5).foregroundStyle(BP.inkSubtle)
    }

    // MARK: engine (engine/aiSearch.ts)

    private func load() async {
        let p = profile
        state = try? await HarborEngine.shared.call("aiSearch.state", [p.id, p.linked])
        models = try? await HarborEngine.shared.call("aiSearch.models", [p.id, p.linked])
    }

    private func saveKey(_ slot: String, _ value: String) async {
        let p = profile
        guard let s: AISearchModel.State = try? await HarborEngine.shared.call("aiSearch.saveKey", [slot, value, p.id, p.linked]) else { return }
        state = s
        if slot == "jina" { jinaDraft = "" } else { keyDraft = "" }
        if !value.isEmpty {
            flash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { flash = false }
        }
        // A Groq key lets the live catalog prune Groq's list (ai-mode-button useGroqCatalog).
        if slot == "groq" { models = try? await HarborEngine.shared.call("aiSearch.models", [p.id, p.linked]) }
    }

    private func setProvider(_ tab: String) async {
        let p = profile
        if let s: AISearchModel.State = try? await HarborEngine.shared.call("aiSearch.setProvider", [tab, p.id, p.linked]) {
            state = s
            keyDraft = ""
        }
    }

    /// ai-search-section.tsx setModel: `update({ aiSearchModel: id, aiSearchProvider: tab })`.
    private func setModel(_ id: String) async {
        guard !id.isEmpty else { return }
        let p = profile
        let tab: String? = state?.tab
        if let s: AISearchModel.State = try? await HarborEngine.shared.call("aiSearch.setModel", [id, tab, p.id, p.linked]) {
            // (settings device pass) ai-search-section.tsx keeps the custom id in its field; clearing
            // it disabled the focused Use model button and threw the ring off it.
            state = s
        }
    }

    private func setWebSearch(_ on: Bool) async {
        let p = profile
        if let s: AISearchModel.State = try? await HarborEngine.shared.call("aiSearch.setWebSearch", [on, p.id, p.linked]) { state = s }
    }
}
