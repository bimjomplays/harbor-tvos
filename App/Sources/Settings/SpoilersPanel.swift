import SwiftUI

/// Settings → Spoilers (views/settings/library-panel/detail-tab.tsx "Spoilers" section;
/// settings/defaults.ts:411-415 hideSpoilers/spoilerHideThumbnails/spoilerHideTitles/
/// spoilerHideDescriptions/spoilerSkipNext). The actual masking is `lib/spoilers.ts`
/// spoilerMaskFor, ported at engine/episodeWatched.ts and applied by DetailView's
/// EpisodeCell (blur lifted on focus, since a remote has no hover) and the player's
/// up-next pill (DetailModel.upNextText). This panel only lets the viewer flip the
/// settings the engine already reads; upstream's nested group shows only while
/// hideSpoilers is on.
struct SpoilersPanel: View {
    @EnvironmentObject private var settings: SettingsBridge

    private var hideSpoilers: Bool { settings.slice.hideSpoilers ?? false }
    private var hideThumbnails: Bool { settings.slice.spoilerHideThumbnails ?? true }
    private var hideTitles: Bool { settings.slice.spoilerHideTitles ?? true }
    private var hideDescriptions: Bool { settings.slice.spoilerHideDescriptions ?? true }
    private var skipNext: Bool { settings.slice.spoilerSkipNext ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(10)) {
            Text(hideSpoilers ? "On" : "Off").font(BP.sans(16, .semibold)).foregroundStyle(BP.ink)
            Text("Hides spoiler-prone episode details in episode lists until you have watched them. Focus a card to reveal it temporarily.")
                .font(BP.sans(14)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true)
            toggle("Blur spoilers", hideSpoilers, key: "hideSpoilers", testId: "spoilers-hide")
            if hideSpoilers {
                VStack(alignment: .leading, spacing: BP.px(10)) {
                    Text("What gets blurred").font(BP.sans(13, .semibold)).foregroundStyle(BP.inkMuted)
                        .padding(.top, BP.px(4))
                    HStack(spacing: BP.px(8)) {
                        toggle("Thumbnails", hideThumbnails, key: "spoilerHideThumbnails", testId: "spoilers-thumb")
                        toggle("Titles", hideTitles, key: "spoilerHideTitles", testId: "spoilers-title")
                        toggle("Descriptions", hideDescriptions, key: "spoilerHideDescriptions", testId: "spoilers-desc")
                    }
                    // "Keep the next episode visible": leave the episode you are up to clear and
                    // only blur the ones after it (use-episode-progress-map isNextUp exemption).
                    toggle("Keep the next episode visible", skipNext, key: "spoilerSkipNext", testId: "spoilers-skip-next")
                }
                .focusSection()
            }
        }
    }

    private func toggle(_ label: String, _ on: Bool, key: String, testId: String) -> some View {
        let title: String = "\(T(label)): \(T(on ? "On" : "Off"))"
        return Button(title) { patch([key: .bool(!on)]) }.buttonStyle(BPActionStyle(primary: on)).bpSelected(on)
            .accessibilityIdentifier(testId)
    }

    private func patch(_ change: [String: AnyJSON]) {
        Task { try? await settings.patch(change) }
    }
}
