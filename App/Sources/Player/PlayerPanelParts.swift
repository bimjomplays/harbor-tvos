import SwiftUI

// bp-subtitle-parts.tsx / bp-player-sources.tsx: the pieces the in-player dialogs share.

/// bp-subtitle-parts.tsx Chip: a pill; `on` is filled with --bp-on, off is an edge hairline,
/// and focus floods it bright.
struct PlayerChipStyle: ButtonStyle {
    var on = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .font(BP.sans(14, .bold))
                .foregroundStyle(focused ? BP.canvas : BP.ink)
                .lineLimit(1)
                .opacity(enabled ? 1 : 0.45)
                .padding(.horizontal, BP.px(15))
                .frame(height: BP.px(44))
                .background(Capsule().fill(focused ? BP.ink : (on ? BP.on : Color.clear)))
                .overlay(Capsule().stroke(on || focused ? Color.clear : BP.edge2, lineWidth: 1))
                .modifier(BPFocusModifier(focused: focused, pressed: configuration.isPressed, radius: BP.px(22), lift: 1.02))
        }
    }
}

/// bp-subtitle-parts.tsx SubLine / bp-player-sources.tsx BpAudioRow: a full-width row; the
/// chosen one sits on glass, the rest on the panel with an edge.
struct PlayerLineStyle: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .foregroundStyle(BP.ink)
                .padding(.horizontal, BP.px(15))
                .padding(.vertical, BP.px(11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(focused ? BP.on : (on ? BP.glass : BP.panel)))
                .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(on || focused ? Color.clear : BP.edge, lineWidth: 1))
                .modifier(BPFocusModifier(focused: focused, pressed: configuration.isPressed, radius: BP.rMD, lift: 1.01))
        }
    }
}

/// The body of a SubLine / audio row: a round disc with a glyph, a title with badges, a detail line.
struct PlayerLineLabel: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var badges: [String] = []

    var body: some View {
        HStack(spacing: BP.px(14)) {
            // The disc's glyph (a tick on the chosen row) is drawn state: callers mark the row bpSelected.
            Image(systemName: icon)
                .font(.system(size: BP.px(17), weight: .bold))
                .frame(width: BP.px(44), height: BP.px(44))
                .background(Circle().fill(BP.panel2))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BP.px(4)) {
                HStack(spacing: BP.px(8)) {
                    Text(title).font(BP.sans(14, .semibold)).lineLimit(1)
                    ForEach(badges, id: \.self) { b in
                        Text(b).font(BP.sans(10.5, .bold)).textCase(.uppercase).tracking(1.2)
                            .padding(.horizontal, BP.px(8)).padding(.vertical, 3)
                            .background(Capsule().fill(BP.glass))
                    }
                }
                if let detail, !detail.isEmpty {
                    Text(detail).font(BP.sans(12, .medium)).opacity(0.65).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// bp-subtitle-parts.tsx LABEL: the small uppercase heading that opens a row.
struct PlayerRowLabel: View {
    let text: String
    var body: some View {
        Text(T(text)).font(BP.sans(11.5, .bold)).textCase(.uppercase).tracking(1.8).foregroundStyle(BP.inkSubtle)
            .fixedSize()
            .padding(.trailing, BP.px(6))
    }
}

/// bp-subtitle-parts.tsx Row: one horizontally scrolling rail of chips.
struct PlayerChipRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BP.px(8)) { content() }
                .padding(.vertical, BP.px(10))
                .padding(.horizontal, BP.px(8))
        }
    }
}

/// bp-player-sources.tsx BpPlayerAudio: the file's audio tracks, then one bottom lane with Back,
/// the sync offset readout, ±0.1 / ±0.5 s steps and Reset (mpv audio-delay).
struct PlayerAudioPanel: View {
    let controller: (any PlayerEngineControlling)?
    let title: String
    @Binding var audioDelay: Double
    let onClose: () -> Void

    @State private var tracks: [MPVPlayerController.Track] = []
    @FocusState private var focus: String?
    private static let delaySteps: [Double] = [-0.5, -0.1, 0.1, 0.5]
    /// bp-player-sources.tsx BpAudioLane `locked = engine === "html5"`: AVPlayer has no audio delay.
    private var locked: Bool { controller?.engineKind == .native }
    /// (player pass 2) Which engine the dialog reads; its track poll restarts with a new one.
    private var engineKey: ObjectIdentifier? { controller.map { ObjectIdentifier($0 as AnyObject) } }

    var body: some View {
        ZStack {
            BP.void_.opacity(0.5).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: BP.px(5)) {
                    Label("Audio", systemImage: "character.bubble").font(BP.display(26)).foregroundStyle(BP.ink)
                    Text("\(title) · \(tracks.count) tracks").font(BP.sans(13, .medium)).foregroundStyle(BP.inkSubtle).lineLimit(1)
                }
                .padding(.horizontal, BP.px(30)).padding(.top, BP.px(30))

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: BP.px(10)) {
                        if tracks.isEmpty {
                            Text("This file has one audio track.").font(BP.sans(14, .medium)).foregroundStyle(BP.inkSubtle)
                        }
                        ForEach(tracks) { t in
                            Button {
                                controller?.select(track: t, type: "audio")
                                // bp-ten-foot onAudio: the track's language becomes the show's audio language.
                                controller?.rememberAudio(t)
                                onClose()
                            } label: {
                                PlayerLineLabel(icon: t.selected ? "checkmark" : "character.bubble", title: lines(t).0, detail: lines(t).1)
                            }
                            .buttonStyle(PlayerLineStyle(on: t.selected))
                            .focused($focus, equals: "track-\(t.id)")
                            .bpSelected(t.selected)
                        }
                    }
                    .padding(.horizontal, BP.px(30)).padding(.vertical, BP.px(18))
                }

                lane
            }
            .frame(width: BP.px(1049), height: BP.px(551), alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.void_))
            .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge, lineWidth: 1))
            .focusSection()
        }
        .onAppear {
            tracks = (controller?.tracks() ?? []).filter { $0.type == "audio" }
            let seed = tracks.first { $0.selected } ?? tracks.first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { focus = seed.map { "track-\($0.id)" } ?? "back" }
        }
        // (player pass 2) The list follows the file, like upstream's snapshot: opened before the
        // file (or AVPlayer's audio group) was read, it said "one audio track" for good.
        // Keyed to the engine: a reload under the dialog hands it a new one to read.
        .task(id: engineKey) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                let now = (controller?.tracks() ?? []).filter { $0.type == "audio" }
                if now != tracks { tracks = now }
            }
        }
    }

    /// One bottom lane, so Left and Right walk Back through to Reset without leaving the row.
    private var lane: some View {
        HStack(spacing: BP.px(10)) {
            Button("Back") { onClose() }
                .buttonStyle(BPActionStyle())
                .focused($focus, equals: "back")
            Text("Sync Offset").font(BP.sans(12.5, .bold)).textCase(.uppercase).tracking(1.4).foregroundStyle(BP.inkSubtle)
                .padding(.leading, BP.px(6))
                .opacity(locked ? 0.45 : 1)
            Text(String(format: "%@%.2fs", audioDelay > 0 ? "+" : "", audioDelay))
                .font(.system(size: BP.px(16), weight: .bold, design: .monospaced))
                .foregroundStyle(audioDelay != 0 ? BP.ink : BP.inkSubtle)
                .opacity(locked ? 0.45 : 1)
            // BpAudioLane: html5 cannot offset audio, so the cells are disabled and focus steps over them.
            ForEach(Self.delaySteps, id: \.self) { step in
                Button(String(format: "%@%gs", step > 0 ? "+" : "", step)) { setDelay(audioDelay + step) }
                    .buttonStyle(BPActionStyle())
                    .focused($focus, equals: "step\(step)")
                    .disabled(locked)
            }
            if audioDelay != 0 {
                Button { setDelay(0) } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(BPActionStyle())
                    .focused($focus, equals: "reset")
                    .disabled(locked)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BP.px(30)).padding(.vertical, BP.px(16))
        .overlay(alignment: .top) { Rectangle().fill(BP.edge).frame(height: 1) }
        .focusSection()
    }

    private func setDelay(_ value: Double) {
        let v = (value * 100).rounded() / 100
        audioDelay = v
        controller?.setAudioDelay(v)
    }

    /// bp-player-sources.tsx trackLines: the track's own name (or its language), then language · codec · channels · Default.
    private func lines(_ t: MPVPlayerController.Track) -> (String, String) {
        // (open-items sweep) Through languageName's 639-2 aliases ("ger" → German, not "GER").
        let lang = t.lang.map { TrackLanguage.englishName($0) ?? $0.uppercased() } ?? ""
        let trimmed = t.title?.trimmingCharacters(in: .whitespaces) ?? ""
        let named = (trimmed.isEmpty || trimmed == t.lang) ? "" : trimmed
        let detail = [lang, t.codec?.uppercased() ?? "", t.channels ?? "", t.isDefault ? T("Default") : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        let head = !named.isEmpty ? named : (!lang.isEmpty ? lang : T("Track"))
        return (head, detail)
    }
}

/// (open-items sweep) The chrome's second line for a channel tuned in the player: what is on now,
/// else its group. PlayerScreen does not observe the Live model, so the line kept the answer from
/// the tune (usually the group, before now/next landed) until something else redrew the player.
struct TunedChannelSubtitle: View {
    @ObservedObject var live: LiveModel
    let channel: LiveModel.Channel

    var body: some View {
        let line: String? = live.guide[channel.id]?.now?.title ?? channel.group
        if let line {
            Text(line).font(BP.sans(15, .semibold)).foregroundStyle(BP.inkMuted)
        }
    }
}
