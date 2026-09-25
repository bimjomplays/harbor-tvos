import SwiftUI

/// settings/webhooks-panel.tsx "Where alerts go", the two destinations a sports reminder uses
/// (settings.webhooks.discordUrl / telegramUrl for the active profile, through `sports.setWebhooks`).
/// Telegram is composed from a bot token and chat id like telegram-field.tsx.
struct SportsWebhooksPanel: View {
    var onDone: (() -> Void)? = nil
    @State private var discord = ""
    @State private var token = ""
    @State private var chatId = ""
    @State private var loaded = false
    @State private var status: String?
    @State private var busy = false
    struct Hooks: Decodable { var discordUrl: String; var telegramUrl: String }
    struct Sent: Decodable { var ok: Bool; var message: String }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            BPNote(text: "Connect Discord or Telegram and Harbor alerts you when something you follow is about to drop. Sports reminders are sent from this Apple TV while Harbor is open.")
            BPField(label: "Discord webhook URL", placeholder: "https://discord.com/api/webhooks/…", text: $discord, keyboard: .URL)
            HStack(spacing: BP.px(12)) {
                BPField(label: T("Telegram bot") + " · " + T("Bot token"), placeholder: "123456:ABC…", text: $token, phone: true)
                BPField(label: "Chat ID", placeholder: "123456789", text: $chatId)
            }
            HStack(spacing: BP.px(10)) {
                Button("Save") { Task { await save() } }.buttonStyle(BPActionStyle(primary: true, busy: busy))
                Button(T("Send test") + " · Discord") { Task { await test("discord") } }.buttonStyle(BPActionStyle(busy: busy)).disabled(discord.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(T("Send test") + " · Telegram") { Task { await test("telegram") } }.buttonStyle(BPActionStyle(busy: busy)).disabled(Self.compose(token, chatId).isEmpty)
                if let onDone { Button("Done") { onDone() }.buttonStyle(BPActionStyle()) }
            }
            if let status { BPNote(text: status) }
        }
        .task {
            guard !loaded, let h: Hooks = try? await HarborEngine.shared.call("sports.webhooks", []) else { return }
            loaded = true
            discord = h.discordUrl
            let parts = Self.parse(h.telegramUrl)
            token = parts.token; chatId = parts.chatId
        }
    }

    /// telegram-field.tsx compose / parse.
    static func compose(_ token: String, _ chatId: String) -> String {
        let t = token.trimmingCharacters(in: .whitespaces), c = chatId.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || c.isEmpty ? "" : "https://api.telegram.org/bot\(t)/sendMessage?chat_id=\(c)"
    }
    static func parse(_ url: String) -> (token: String, chatId: String) {
        guard let re = try? NSRegularExpression(pattern: "^https?://api\\.telegram\\.org/bot([^/]+)/sendMessage(?:\\?chat_id=(.+))?$"),
              let m = re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) else { return ("", "") }
        func group(_ i: Int) -> String { Range(m.range(at: i), in: url).map { String(url[$0]) } ?? "" }
        return (group(1), group(2))
    }

    private func save() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let out: Hooks? = try? await HarborEngine.shared.call("sports.setWebhooks", [discord, Self.compose(token, chatId)])
        status = out == nil ? "Could not save. Try again." : "Saved."
    }

    private func test(_ kind: String) async {
        guard !busy else { return }
        await save()
        busy = true; defer { busy = false }
        status = "Sending…"
        let r: Sent? = try? await HarborEngine.shared.call("sports.testWebhook", [kind])
        status = r?.message ?? "Failed"
    }
}

/// settings/sports-api-setting.tsx "Sports metadata": the optional API-Sports key (stored under
/// harbor.sports.api-sports.v1, which KeyValueStore keeps in the Keychain). Saving does not verify it.
struct SportsApiKeyPanel: View {
    struct Info: Decodable { var saved: Bool; var length: Int; var leagues: [String]; var notices: [String] }
    struct Saved: Decodable { var ok: Bool }
    @State private var info: Info?
    @State private var draft = ""
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            BPNote(text: T("Optional schedules and scores for selected %@ and hockey competitions. Your API-Sports plan and request limits apply.", T("Soccer")))
            if let i = info, !i.leagues.isEmpty { Text(i.leagues.joined(separator: " · ")).font(BP.sans(14)).foregroundStyle(BP.inkMuted) }
            if let i = info, i.saved { Text("Key saved on this device (\(i.length) characters)").font(BP.sans(14, .semibold)).foregroundStyle(BP.ink) }
            BPField(label: "API-Sports key", placeholder: "Paste your API-Sports key", text: $draft, secure: true)
            HStack(spacing: BP.px(10)) {
                Button("Save") { Task { await save(draft) } }.buttonStyle(BPActionStyle(primary: true)).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if info?.saved == true { Button("Clear key") { Task { draft = ""; await save("") } }.buttonStyle(BPActionStyle()) }
            }
            BPNote(text: "Saving does not verify your key. Sports uses it when loading supported competitions.")
            if let note { BPNote(text: note, tone: note.hasPrefix("The key could not") ? BP.danger : BP.inkMuted) }
            ForEach(info?.notices ?? [], id: \.self) { n in BPNote(text: n) }
        }
        .task { info = try? await HarborEngine.shared.call("sports.apiSports", []) }
    }

    private func save(_ value: String) async {
        let r: Saved? = try? await HarborEngine.shared.call("sports.setApiSportsKey", [value])
        if r?.ok == true { note = value.isEmpty ? "Key cleared." : "Saved."; draft = "" }
        else { note = "The key could not be saved. Your previous key is unchanged." }
        info = try? await HarborEngine.shared.call("sports.apiSports", [])
    }
}
