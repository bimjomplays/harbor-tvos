import SwiftUI

/// components/age-gate-modal.tsx: three everyday questions any adult would know (upstream's
/// English or Arabic bank, drawn by the engine's pickThree), all three right to unlock adult
/// addons. A wrong round shows the notice and deals a fresh round after 1.4 s; a pass shows
/// "You're verified" and closes after 1.7 s, as upstream.
struct AgeGateView: View {
    let onPass: () -> Void
    let onClose: () -> Void

    struct Question: Decodable, Hashable { var q: String; var options: [String]; var correct: Int }
    private struct Round: Decodable { var questions: [Question] }

    @State private var questions: [Question] = []
    @State private var picks: [Int?] = [nil, nil, nil]
    @State private var submitted = false
    @State private var verified = false

    private var allAnswered: Bool { !questions.isEmpty && picks.prefix(questions.count).allSatisfy { $0 != nil } }
    private var allCorrect: Bool { questions.enumerated().allSatisfy { i, q in picks[i] == q.correct } }

    var body: some View {
        ZStack {
            BP.void_.opacity(0.85).ignoresSafeArea()
            if verified {
                VStack(spacing: BP.px(28)) {
                    Image(systemName: "checkmark.circle").font(.system(size: BP.px(84), weight: .light)).foregroundStyle(BP.live).accessibilityHidden(true)
                    Text(T("You're verified")).font(BP.display(26, .medium)).foregroundStyle(BP.ink)
                }
                .padding(.horizontal, BP.px(60)).padding(.vertical, BP.px(56))
                .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.canvas))
            } else {
                card
            }
        }
        .ignoresSafeArea()
        .onExitCommand { if !verified { onClose() } }
        .task { await deal() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: BP.px(8)) {
                Text(T("Quick age check")).font(BP.display(28, .medium)).foregroundStyle(BP.ink)
                Text(T("A quick age check before adult add-ons unlock. Answer three everyday questions any adult would know, and you're in."))
                    .font(BP.sans(14)).foregroundStyle(BP.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(BP.px(28))
            Divider().overlay(BP.edge)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: BP.px(26)) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { qi, q in
                        VStack(alignment: .leading, spacing: BP.px(10)) {
                            HStack(alignment: .top, spacing: BP.px(12)) {
                                Text("\(qi + 1)").font(BP.sans(12, .bold)).foregroundStyle(BP.inkMuted)
                                    .frame(width: BP.px(24), height: BP.px(24)).background(Circle().fill(BP.elevated))
                                Text(q.q).font(BP.sans(15, .medium)).foregroundStyle(BP.ink).fixedSize(horizontal: false, vertical: true)
                            }
                            VStack(alignment: .leading, spacing: BP.px(8)) {
                                ForEach(Array(q.options.enumerated()), id: \.offset) { oi, opt in
                                    option(qi: qi, oi: oi, text: opt, correct: q.correct)
                                }
                            }
                            .padding(.leading, BP.px(36))
                        }
                        .focusSection()
                    }
                }
                .padding(BP.px(28))
            }
            Divider().overlay(BP.edge)
            VStack(alignment: .trailing, spacing: BP.px(10)) {
                HStack(spacing: BP.px(12)) {
                    Spacer()
                    Button(T("Cancel")) { onClose() }.buttonStyle(BPActionStyle())
                    Button(T("Continue")) { submit() }.buttonStyle(BPActionStyle(primary: true, busy: submitted)).disabled(!allAnswered)
                }
                .focusSection()
                if submitted && !allCorrect {
                    Text(T("That's not it. Try a fresh round in a moment.")).font(BP.sans(12, .medium)).foregroundStyle(BP.danger)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(BP.px(22))
        }
        .frame(width: BP.px(760))
        .frame(maxHeight: BP.px(1000))
        .background(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).fill(BP.canvas))
        .overlay(RoundedRectangle(cornerRadius: BP.rLG, style: .continuous).stroke(BP.edge2, lineWidth: 1))
    }

    private func option(qi: Int, oi: Int, text: String, correct: Int) -> some View {
        let picked = picks[qi] == oi
        let wasWrong = submitted && picked && oi != correct
        return Button {
            guard !submitted else { return }
            picks[qi] = oi
        } label: {
            HStack(spacing: BP.px(12)) {
                Image(systemName: picked ? "largecircle.fill.circle" : "circle").foregroundStyle(picked ? BP.ink : BP.inkSubtle).accessibilityHidden(true)
                Text(text).font(BP.sans(14)).foregroundStyle(wasWrong ? BP.danger : (picked ? BP.ink : BP.inkMuted)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BP.px(14)).padding(.vertical, BP.px(10))
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(wasWrong ? BP.danger.opacity(0.12) : (picked ? BP.elevated : BP.elevated.opacity(0.3))))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(wasWrong ? BP.danger.opacity(0.5) : (picked ? BP.ink : BP.edge), lineWidth: 1))
        }
        .buttonStyle(BPTileStyle(radius: BP.rSM))
        .bpSelected(picked)
    }

    private func deal() async {
        let r: Round? = try? await HarborEngine.shared.call("addonsManager.ageGate", [L10n.language])
        questions = Array((r?.questions ?? []).prefix(3))
        picks = [nil, nil, nil]
        submitted = false
    }

    private func submit() {
        guard !submitted else { return }
        submitted = true
        if allCorrect {
            verified = true
            onPass()
            Task {
                try? await Task.sleep(nanoseconds: 1_700_000_000)
                onClose()
            }
            return
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await deal()
        }
    }
}
