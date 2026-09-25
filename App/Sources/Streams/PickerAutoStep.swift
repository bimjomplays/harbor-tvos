import SwiftUI

/// The picker's auto-play screen while instant play finds and starts a source (use-bp-stream-play
/// `autoBusy`; the picker list steps aside for it, as bp-streams.tsx returns it instead of the
/// panel). Adults get bp-stream-steps.tsx BpAutoStep; a kid profile gets
/// play-picker/auto-play-transition.tsx's kid branch (AutoPlayTransition under useActiveKid()),
/// the deep-sea plate the kid loader (KidsPlayerLoader) carries on into the player.
/// Back cancels auto, like BpAutoStep's pushBpBack → onCancel.
struct PickerAutoStep: View {
    let meta: Meta
    let episode: AnyJSON?
    /// autoAttemptIdx: the candidate being tried (0 = the first).
    let attemptIdx: Int
    /// AutoPlayTransition `resolving`: a candidate is being resolved right now.
    let resolving: Bool
    /// AutoPlayTransition `p2p`: that candidate is being fetched by the TV's torrent engine.
    let p2p: Bool
    /// useActiveKid().
    let kid: Bool
    /// auto-play-transition.tsx stubNotice: the player just sent a stub back (consumeRecentStubEvent);
    /// the picker clears it after 6 s.
    var stubNotice = false
    /// use-bp-stream-play cancelAuto: auto stops and the list is the picker again.
    let onCancel: () -> Void

    @FocusState private var seeded: Bool
    /// AutoPlayTransition p2pStage: 1 after P2P_SEARCHING_DELAY_MS (6 s), 2 after P2P_SLOW_DELAY_MS (25 s).
    @State private var p2pStage = 0
    /// .animate-loader-pulse: opacity .42 → 1 → .42 over 2.4 s.
    @State private var pulse = false

    /// `episode?.still || meta.background || meta.poster`.
    private var backdrop: String? {
        [episode?["still"]?.string, meta.background, meta.poster].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// `S{imdbSeason ?? season} · E{02}{ · name}` (both components print it the same way).
    private var episodeLine: String? {
        guard let s = episode?["imdbSeason"]?.number ?? episode?["season"]?.number,
              let e = episode?["imdbEpisode"]?.number ?? episode?["episode"]?.number else { return nil }
        var line = "S\(Int(s)) · E" + String(format: "%02d", Int(e))
        if let name = episode?["name"]?.string, !name.isEmpty { line += " · " + name }
        return line
    }

    var body: some View {
        Group {
            if kid { kidStep } else { adultStep }
        }
        .ignoresSafeArea()
        .onAppear {
            // BpAutoStep seeds its one button (setBpFocus(seedRef)).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { seeded = true }
        }
        .onExitCommand { onCancel() }
        // AutoPlayTransition: the P2P stages restart with each attempt and only run while a P2P
        // source is resolving (kid branch only here; BpAutoStep has no P2P captions).
        .task(id: "\(attemptIdx)|\(p2p)|\(resolving)") {
            p2pStage = 0
            guard kid, resolving, p2p else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            p2pStage = 1
            try? await Task.sleep(for: .seconds(19))
            guard !Task.isCancelled else { return }
            p2pStage = 2
        }
    }

    // MARK: bp-stream-steps.tsx BpAutoStep

    private var adultStep: some View {
        ZStack {
            BP.void_
            if let backdrop {
                RemoteImage(url: backdrop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: BP.px(28), opaque: true)
                    .opacity(0.25)
            }
            // `bg-[color-mix(in_oklab,var(--bp-void)_72%,transparent)]`.
            BP.void_.opacity(0.72)
            VStack(spacing: BP.px(20)) {
                VStack(spacing: BP.px(14)) {
                    if let logo = meta.logo, !logo.isEmpty {
                        // The bare logo (no loading plate), same view the kid screens use.
                        KidsLogoImage(url: logo)
                            .frame(maxWidth: BP.px(638), maxHeight: BP.px(90))
                            .shadow(color: .black.opacity(0.75), radius: BP.px(17), y: BP.px(8))
                    } else {
                        Text(verbatim: meta.name)
                            .font(BP.display(33)).foregroundStyle(BP.ink)
                            .multilineTextAlignment(.center).lineLimit(2)
                            .frame(maxWidth: BP.px(750))
                    }
                    if let episodeLine {
                        Text(verbatim: episodeLine)
                            .font(BP.sans(12.5, .bold)).textCase(.uppercase).tracking(BP.px(3.5))
                            .foregroundStyle(BP.inkSubtle).lineLimit(1)
                    }
                    HStack(spacing: BP.px(9)) {
                        ProgressView().tint(BP.inkSubtle)
                        Text(attemptIdx > 0 ? T("Trying source %lld", attemptIdx + 1) : T("Connecting"))
                            .font(BP.sans(14, .semibold)).foregroundStyle(BP.inkSubtle)
                    }
                    // BpAutoStep has no stub notice; auto-play-transition.tsx (the desktop's auto
                    // screen, and the kid branch below) shows it under the loader.
                    if stubNotice { stubNoticeText }
                }
                Button(action: onCancel) {
                    HStack(spacing: BP.px(7)) {
                        Image(systemName: "xmark").font(.system(size: BP.px(15), weight: .bold)).accessibilityHidden(true)
                        Text("Choose a source instead")
                    }
                }
                .buttonStyle(BPActionStyle())
                .focused($seeded)
                .focusSection()
            }
            .padding(.horizontal, BP.gutter)
        }
    }

    /// auto-play-transition.tsx stubNotice: `max-w-md text-[13px] leading-relaxed text-amber-200/80`.
    private var stubNoticeText: some View {
        Text("Last source wasn't actually cached on your debrid yet. Trying another.")
            .font(BP.sans(13)).foregroundStyle(Color(red: 0.992, green: 0.902, blue: 0.541).opacity(0.8))
            .multilineTextAlignment(.center).lineSpacing(BP.px(4))
            .frame(maxWidth: BP.px(448))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: auto-play-transition.tsx, kid branch

    private var kidCaption: String {
        if p2pStage == 2 { return "P2P · " + T("Stream is taking a while") }
        if p2pStage == 1 { return "P2P · " + T("Searching sources…") }
        if attemptIdx > 0 { return T("Trying source %lld", attemptIdx + 1) }
        return T("Connecting")
    }

    private var kidStep: some View {
        ZStack {
            // `bg-[#0c4a6e]`, the art `opacity-20 blur-[36px] saturate-150`, the sky-to-sea veil at
            // 85/88/94 %, seven bubbles, both octopuses and the orange star.
            KidsPlayerColors.ink
            if let backdrop {
                RemoteImage(url: backdrop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .saturation(1.5)
                    .blur(radius: BP.px(36), opaque: true)
                    .opacity(0.2)
            }
            KidsSeaBackdrop(bubbles: [8, 22, 38, 55, 70, 84, 93], bubbleStep: 6, veil: (0.85, 0.88, 0.94),
                            octoRed: (0.14, 0.10, 96, 0.85), octoPurple: (0.12, 0.12, 80, 0.75), orangeStar: true)
            VStack(spacing: BP.px(28)) {
                // LogoOrText with the loader pulse.
                Group {
                    if let logo = meta.logo, !logo.isEmpty {
                        KidsLogoImage(url: logo)
                            .frame(maxWidth: BP.px(900), maxHeight: BP.px(176))
                            .shadow(color: .black.opacity(0.65), radius: 30, y: 24)
                    } else {
                        Text(verbatim: meta.name)
                            .font(KidsTheme.font(64, .medium)).foregroundStyle(.white)
                            .multilineTextAlignment(.center).lineLimit(2)
                            .shadow(color: .black.opacity(0.7), radius: 22, y: 18)
                    }
                }
                .opacity(pulse ? 1 : 0.42)
                if let episodeLine {
                    Text(verbatim: episodeLine)
                        .font(BP.sans(12.5, .semibold)).textCase(.uppercase).tracking(BP.px(4))
                        .foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                // HarborLoader size="md" with its caption.
                VStack(spacing: BP.px(12)) {
                    ProgressView().tint(.white)
                    Text(verbatim: kidCaption)
                        .font(BP.sans(12.5, .medium)).textCase(.uppercase).tracking(BP.px(2.25))
                        .foregroundStyle(.white.opacity(0.7))
                }
                if p2pStage == 2 {
                    Text("This source is slow. Try another.")
                        .font(BP.sans(13)).foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center).frame(maxWidth: BP.px(448))
                }
                if stubNotice { stubNoticeText }
            }
            .frame(maxWidth: BP.px(1100))
            .padding(.horizontal, BP.gutter)
            VStack {
                Spacer()
                // The bottom Cancel ("Choose another source" once the P2P source is slow), in the
                // kids pill so the ring reads on the sea plate, as KidsPlayerLoader's.
                Button(action: onCancel) {
                    HStack(spacing: BP.px(10)) {
                        Image(systemName: "xmark").font(.system(size: BP.px(18), weight: .heavy)).accessibilityHidden(true)
                        Text(T(p2pStage == 2 ? "Choose another source" : "Cancel")).font(KidsTheme.font(18, .heavy))
                    }
                }
                .buttonStyle(KidsPillStyle(fill: .white.opacity(0.15), focusedFill: .white.opacity(0.25), ink: .white, height: BP.px(60)))
                .focused($seeded)
                .padding(.bottom, BP.px(56))
            }
            .focusSection()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
