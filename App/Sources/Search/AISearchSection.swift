import SwiftUI

/// components/search/ai-search-section.tsx in AI mode: the add-a-key note, "Searches when you stop
/// typing", the thinking state (ai-thinking.tsx), the retry card, and the picks (ai-picks-header.tsx +
/// ai-result-list.tsx). Select on a pick opens its detail page (an episode pick on that episode).
struct AISearchSection: View {
    @ObservedObject var ai: AISearchModel
    let query: String
    let onOpen: (AISearchModel.Result) -> Void
    /// (detail/search pass 2) Ask AI / the retry card turn into the thinking state, which has nothing
    /// to focus: the page puts the ring back on its keyboard (upstream's focus stays in the field).
    var onRun: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(14)) {
            if ai.state?.hasKey != true {
                note(ai.state?.tab == "groq"
                     ? T("Add your Groq API key in Settings, AI search to use this model.")
                     : T("Add your OpenRouter API key in Settings, AI search to use this model."))
            } else {
                switch ai.status {
                case .idle:
                    VStack(spacing: BP.px(12)) {
                        Text(T("Searches when you stop typing")).font(BP.sans(19, .medium)).foregroundStyle(BP.accent)
                        // search-overlay.tsx: Enter searches now; the phone sheet's Go does the same.
                        Button { onRun?(); ai.runNow() } label: { Label(T("Ask AI"), systemImage: "sparkles") }
                            .buttonStyle(BPActionStyle(primary: true))
                            .accessibilityIdentifier("search-ai-run")
                        Text(T("Hold Select on AI search to choose a model"))
                            .font(BP.sans(12, .medium)).foregroundStyle(BP.inkSubtle)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BP.px(40))
                case .loading:
                    AIThinkingView(label: ai.state?.label.isEmpty == false ? (ai.state?.label ?? "") : T("AI search"), phrases: ai.thinkingPhrases)
                case .error:
                    Button { onRun?(); ai.runNow() } label: {
                        VStack(alignment: .leading, spacing: BP.px(4)) {
                            Text(T("AI search failed. Tap to retry.")).font(BP.sans(14, .semibold)).foregroundStyle(BP.ink)
                            Text(ai.errorMessage ?? T("AI search failed.")).font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                            if let d = ai.errorDetail, !d.isEmpty {
                                Text(d).font(BP.sans(12)).foregroundStyle(BP.inkSubtle).lineLimit(2)
                            }
                        }
                        .padding(.horizontal, BP.px(20)).padding(.vertical, BP.px(14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.danger.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.danger.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(BPTileStyle(radius: BP.rMD))
                case .done:
                    if ai.ranQuery == query {
                        if ai.results.isEmpty {
                            note(T("AI didn't find anything for that. Try rephrasing."))
                        } else {
                            header
                            ForEach(ai.results) { r in
                                Button { onOpen(r) } label: { AIResultRow(result: r) }
                                    .buttonStyle(BPTileStyle(radius: BP.rMD))
                            }
                        }
                    }
                }
            }
        }
        .focusSection()
    }

    /// ai-picks-header.tsx: "AI picks", the model and its maker, the count.
    private var header: some View {
        HStack(spacing: BP.px(10)) {
            Image(systemName: "sparkles").foregroundStyle(BP.accent).accessibilityHidden(true)
            Text(T("AI picks")).font(BP.sans(12, .semibold)).textCase(.uppercase).tracking(2.4).foregroundStyle(BP.inkSubtle)
            if let s = ai.state {
                Text(verbatim: "\(s.label) · \(s.providerName)").font(BP.sans(12)).foregroundStyle(BP.inkSubtle).lineLimit(1)
            }
            Spacer()
            Text(verbatim: "\(ai.results.count)").font(BP.sans(12)).monospacedDigit().foregroundStyle(BP.inkSubtle)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(BP.sans(14)).foregroundStyle(BP.inkMuted)
            .padding(.horizontal, BP.px(20)).padding(.vertical, BP.px(16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).fill(BP.panel.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: BP.rMD, style: .continuous).stroke(BP.edge, lineWidth: 1))
    }
}

/// ai-result-list.tsx AiResultRow: poster, an S · E badge for an episode pick, the title (the
/// episode's own for an episode), the show, year and rating, and the overview for a title.
struct AIResultRow: View {
    let result: AISearchModel.Result

    var body: some View {
        let meta = result.meta
        HStack(spacing: BP.px(16)) {
            RemoteImage(url: meta.poster)
                .frame(width: BP.px(64), height: BP.px(96))
                .clipShape(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge, lineWidth: 1))
            VStack(alignment: .leading, spacing: BP.px(4)) {
                if result.isEpisode {
                    Text(T("S%lld · E%lld", result.season ?? 0, result.episode ?? 0))
                        .font(BP.sans(10.5, .bold)).textCase(.uppercase).tracking(1.2).foregroundStyle(BP.accent)
                        .padding(.horizontal, BP.px(8)).padding(.vertical, BP.px(2))
                        .background(Capsule().fill(BP.accent.opacity(0.15)))
                }
                Text(result.isEpisode ? (result.episodeTitle ?? meta.name) : meta.name)
                    .font(BP.sans(16, .semibold)).foregroundStyle(BP.ink).lineLimit(1)
                HStack(spacing: BP.px(8)) {
                    if result.isEpisode { Text(meta.name).lineLimit(1) }
                    if let y = meta.releaseInfo, !y.isEmpty { Text(y) }
                    if let r = meta.imdbRating, !r.isEmpty {
                        HStack(spacing: BP.px(3)) {
                            Image(systemName: "star.fill").font(.system(size: BP.px(10))).foregroundStyle(BP.accent)
                            Text(r).foregroundStyle(BP.ink)
                        }
                        // The star is IMDb's score: "IMDb 7.8", not "Star, 7.8".
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: "IMDb \(r)"))
                    }
                }
                .font(BP.sans(12.5)).foregroundStyle(BP.inkMuted)
                if !result.isEpisode, let d = meta.description, !d.isEmpty {
                    Text(d).font(BP.sans(12.5)).foregroundStyle(BP.inkSubtle).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BP.px(12)).padding(.vertical, BP.px(10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// ai-thinking.tsx: the model's name over a status line that changes every 1.4 s, then four
/// skeleton rows where the picks will land.
struct AIThinkingView: View {
    let label: String
    let phrases: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(16)) {
            HStack(spacing: BP.px(14)) {
                ProgressView().tint(BP.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(BP.sans(11, .semibold)).textCase(.uppercase).tracking(2).foregroundStyle(BP.accent)
                    TimelineView(.periodic(from: .now, by: 1.4)) { ctx in
                        Text(phrases.isEmpty ? "" : phrases[Int(ctx.date.timeIntervalSinceReferenceDate / 1.4) % phrases.count] + "…")
                            .font(BP.sans(13)).foregroundStyle(BP.inkMuted)
                    }
                }
            }
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: BP.px(16)) {
                    RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2).frame(width: BP.px(64), height: BP.px(96))
                    VStack(alignment: .leading, spacing: BP.px(8)) {
                        Capsule().fill(BP.panel2).frame(width: BP.px(260), height: BP.px(14))
                        Capsule().fill(BP.panel2.opacity(0.8)).frame(width: BP.px(360), height: BP.px(12))
                    }
                }
                .padding(.horizontal, BP.px(12))
            }
        }
    }
}
