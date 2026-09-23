import SwiftUI

/// bp-sports-consent.tsx with upstream's usage notice (lib/sports/usage-notice.ts), verbatim:
/// an acknowledge toggle gates "Agree and open Sports"; "Decline" hides the room.
struct SportsConsentView: View {
    let accept: () -> Void
    let decline: () -> Void
    @State private var acknowledged = false

    private let summary = "Harbor is an open-source client. Sports displays third-party metadata; it does not host event broadcasts or operate a central index of sports streams."
    private let sections: [(String, String)] = [
        ("Metadata and local matching", "Schedules, scores, statistics and artwork come from third-party services. Channel suggestions compare this information with sources you configured in Live TV. A match does not verify availability or your right to watch."),
        ("Your sources, your permission", "Use only sources and content you have permission to access. Follow the provider's terms and applicable law. Harbor does not supply subscriptions or grant viewing, copying or redistribution rights. Do not use it to bypass paywalls, DRM or access restrictions."),
        ("External services and local storage", "Opening Sports requests metadata and artwork from external services and caches information on this device. Providers, embedded players and any web proxy used by the app may receive connection data. Their terms and privacy policies apply to their services."),
    ]
    private let details = [
        "Official links and videos remain subject to the originating service's availability, regional restrictions and terms. Names and logos identify third parties and do not imply endorsement or affiliation.",
        "Market data is optional and off by default. It is informational and does not enable trading in Harbor. Reminders send event details to Discord or Telegram only when you configure a destination and request a reminder.",
        "ElfHosted provides separately hosted services. Its policies apply to those services; they do not grant rights to third-party broadcasts, metadata or artwork.",
    ]
    private let links = ["ESPN service terms: disneytermsofuse.com/english", "TheSportsDB terms: thesportsdb.com/docs_terms_of_use.php", "YouTube terms: youtube.com/t/terms", "ElfHosted terms: docs.elfhosted.com/legal/terms-of-service", "ElfHosted privacy policy: docs.elfhosted.com/legal/privacy-policy"]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: BP.px(14)) {
                Text("Before you open Sports").font(BP.display(32)).foregroundStyle(BP.ink)
                Text(summary).font(BP.sans(15)).foregroundStyle(BP.inkMuted)
                ForEach(sections, id: \.0) { s in
                    VStack(alignment: .leading, spacing: BP.px(4)) {
                        Text(s.0).font(BP.sans(15, .semibold)).foregroundStyle(BP.ink)
                        Text(s.1).font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                    }
                }
                ForEach(details, id: \.self) { Text($0).font(BP.sans(12)).foregroundStyle(BP.inkSubtle) }
                ForEach(links, id: \.self) { Text($0).font(BP.sans(12)).foregroundStyle(BP.inkSubtle) }
                Button {
                    acknowledged.toggle()
                } label: {
                    Label("I understand Sports shows third-party information and does not provide or verify access to broadcasts.", systemImage: acknowledged ? "checkmark.square.fill" : "square")
                        .font(BP.sans(14, .semibold))
                }
                .buttonStyle(BPActionStyle(primary: acknowledged))
                HStack(spacing: BP.px(10)) {
                    Button("Agree and open Sports") { accept() }.buttonStyle(BPActionStyle(primary: true)).disabled(!acknowledged)
                    Button("Decline and hide Sports") { decline() }.buttonStyle(BPActionStyle())
                }
            }
            .frame(maxWidth: BP.px(760), alignment: .leading)
            .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(20)).padding(.bottom, BP.hintHeight + BP.px(40))
        }
        .focusSection()
    }
}
