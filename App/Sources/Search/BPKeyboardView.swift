import SwiftUI

/// bp-keyboard.tsx: four rows of keys (letters or symbols), then Space / Backspace / Clear / set toggle.
struct BPKeyboardView: View {
    let onChar: (String) -> Void
    let onBackspace: () -> Void
    let onClear: () -> Void
    @State private var symbols = false

    private static let letters = ["1234567890", "qwertyuiop", "asdfghjkl'", "zxcvbnm,.-"].map { $0.map(String.init) }
    private static let symbolRows = ["!@#$%^&*()", "+=/\\|~`°£€", ":;\"?<>[]{}", "éèáàöüñçåø"].map { $0.map(String.init) }
    private let keySize = BP.px(44)

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            ForEach(Array((symbols ? Self.symbolRows : Self.letters).enumerated()), id: \.offset) { _, row in
                HStack(spacing: BP.px(8)) {
                    ForEach(row, id: \.self) { ch in
                        Button { onChar(ch) } label: { Text(ch).font(BP.sans(17, .semibold)).frame(width: keySize, height: keySize) }
                            .buttonStyle(BPKeyStyle())
                            .accessibilityIdentifier("key-\(ch)")
                    }
                }
            }
            HStack(spacing: BP.px(8)) {
                Button { onChar(" ") } label: { Label("Space", systemImage: "space").font(BP.sans(15, .semibold)).frame(width: keySize * 5 + BP.px(32), height: keySize) }
                    .buttonStyle(BPKeyStyle()).accessibilityIdentifier("key-space")
                Button(action: onBackspace) { Label("Backspace", systemImage: "delete.left").font(BP.sans(15, .semibold)).frame(width: keySize * 2 + BP.px(8), height: keySize) }
                    .buttonStyle(BPKeyStyle()).accessibilityIdentifier("key-backspace")
                Button(action: onClear) { Label("Clear", systemImage: "xmark").font(BP.sans(15, .semibold)).frame(width: keySize * 2 + BP.px(8), height: keySize) }
                    .buttonStyle(BPKeyStyle()).accessibilityIdentifier("key-clear")
                Button { symbols.toggle() } label: { Text(symbols ? "abc" : "?#+").font(BP.sans(15, .semibold)).frame(width: keySize * 1.5, height: keySize) }
                    .buttonStyle(BPKeyStyle()).accessibilityIdentifier("key-toggle")
            }
        }
        .focusSection()
    }
}

struct BPKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .foregroundStyle(BP.ink)
                .background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(focused ? BP.on : BP.panel2))
                .overlay(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).stroke(focused ? BP.focusStroke : BP.edge2, lineWidth: focused ? 3 : 1))
                .scaleEffect(focused ? (configuration.isPressed ? 1.0 : 1.05) : 1)
                .animation(BP.easeFast, value: focused)
        }
    }
}
