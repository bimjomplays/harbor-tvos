import SwiftUI

/// bp-sports-consent.tsx with upstream's usage notice (lib/sports/usage-notice.ts), verbatim:
/// an acknowledge toggle gates "Agree and open Sports"; "Decline" hides the room.
///
/// (device-flow pass) Laid out like upstream: the title stays at the top, the notice scrolls in
/// the middle ("Read the rest" pages it), and the acknowledgement and the two actions stay at the
/// bottom. It was one scroll view whose only focusable controls sat at the very end, so the first
/// focus scrolled the title and the first sections off screen and nothing could bring them back.
struct SportsConsentView: View {
    let accept: () -> Void
    let decline: () -> Void
    @State private var acknowledged = false
    /// The block "Read the rest" last scrolled to (bp-sports-consent page(): 80 % steps, then the top).
    @State private var readAt = 0

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
    // usage-notice.ts SPORTS_POLICY_LINKS: label, address.
    private let links: [(String, String)] = [
        ("ESPN service terms", "disneytermsofuse.com/english"), ("TheSportsDB terms", "thesportsdb.com/docs_terms_of_use.php"),
        ("YouTube terms", "youtube.com/t/terms"), ("ElfHosted service terms", "docs.elfhosted.com/legal/terms-of-service"),
        ("ElfHosted privacy policy", "docs.elfhosted.com/legal/privacy-policy"),
    ]

    /// Scroll targets: the summary, each section, then the policies block.
    private var blockCount: Int { sections.count + 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(12)) {
            VStack(alignment: .leading, spacing: BP.px(4)) {
                Text(T("Sports")).font(BP.sans(11, .bold)).textCase(.uppercase).tracking(1.5).foregroundStyle(BP.inkSubtle)
                Text("Before you open Sports").font(BP.display(32)).foregroundStyle(BP.ink)
            }
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: BP.px(12)) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: BP.px(12)) {
                            Text(T(summary)).font(BP.sans(15)).foregroundStyle(BP.ink).id(0)
                            ForEach(Array(sections.enumerated()), id: \.offset) { i, s in
                                VStack(alignment: .leading, spacing: BP.px(4)) {
                                    Text(T(s.0)).font(BP.sans(12, .bold)).textCase(.uppercase).tracking(1).foregroundStyle(BP.inkSubtle)
                                    Text(T(s.1)).font(BP.sans(13)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal, BP.px(16)).padding(.vertical, BP.px(12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel))
                                .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
                                .id(i + 1)
                            }
                            VStack(alignment: .leading, spacing: BP.px(6)) {
                                Text("Services, privacy and source policies").font(BP.sans(12, .bold)).textCase(.uppercase).tracking(1).foregroundStyle(BP.inkSubtle)
                                ForEach(details, id: \.self) { Text(T($0)).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).fixedSize(horizontal: false, vertical: true) }
                                ForEach(links, id: \.0) { l in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(T(l.0)).font(BP.sans(12, .semibold)).foregroundStyle(BP.ink)
                                        Text(verbatim: l.1).font(BP.sans(10.5, .medium)).foregroundStyle(BP.inkSubtle)
                                    }
                                }
                            }
                            .id(sections.count + 1)
                        }
                        .frame(maxWidth: BP.px(760), alignment: .leading)
                        .padding(.bottom, BP.px(24))
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .mask(VStack(spacing: 0) { Color.black; LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: BP.px(28)) })
                    Button("Read the rest") {
                        readAt = readAt + 1 >= blockCount ? 0 : readAt + 1
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(readAt, anchor: .top) }
                    }
                    .buttonStyle(BPActionStyle())
                }
            }
            Button {
                acknowledged.toggle()
            } label: {
                Label("I understand this notice and agree to use Sports only with sources and content I have permission to access.", systemImage: acknowledged ? "checkmark.square.fill" : "square")
                    .font(BP.sans(14, .semibold))
                    .frame(maxWidth: BP.px(760), alignment: .leading)
            }
            .buttonStyle(BPActionStyle(primary: acknowledged))
            .bpSelected(acknowledged)
            HStack(spacing: BP.px(10)) {
                Button("Agree and open Sports") { accept() }.buttonStyle(BPActionStyle(primary: true)).disabled(!acknowledged)
                Button("Decline and hide Sports") { decline() }.buttonStyle(BPActionStyle())
            }
            Text("This choice applies to this device. You can hide Sports or show this notice again in Settings.")
                .font(BP.sans(12)).foregroundStyle(BP.inkSubtle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, BP.gutter).padding(.top, BP.barHeight + BP.px(20)).padding(.bottom, BP.hintHeight + BP.px(16))
        .focusSection()
    }
}
