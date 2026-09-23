import SwiftUI

/// Focus treatment from bp-tokens.ts:501-573: the tile comes forward (1.03 lift, near-white
/// ring over a void gap, soft contact shadow); the ring snaps, only the grow animates.
struct BPFocusModifier: ViewModifier {
    let focused: Bool
    let pressed: Bool
    var radius: CGFloat = BP.rXS
    var lift: CGFloat = BP.focusLift

    func body(content: Content) -> some View {
        content
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                        .inset(by: -3)
                        .stroke(BP.void_, lineWidth: 3)
                    RoundedRectangle(cornerRadius: radius + 7, style: .continuous)
                        .inset(by: -7)
                        .stroke(BP.focusStroke, lineWidth: 5)
                }
            }
            .shadow(color: .black.opacity(focused ? 0.8 : 0), radius: focused ? 34 : 0, y: focused ? 26 : 0)
            .scaleEffect(focused ? (pressed ? lift * BP.press : lift) : 1)
            .animation(pressed ? .timingCurve(0.5, 0, 0.75, 0, duration: 0.09) : BP.ease, value: focused)
            .animation(.timingCurve(0.5, 0, 0.75, 0, duration: 0.09), value: pressed)
    }
}

/// Card-like tile (posters, profile faces, choice cards).
struct BPTileStyle: ButtonStyle {
    var radius: CGFloat = BP.rXS
    /// bp-settings-parts.tsx onCellFocus: runs when the tile takes focus.
    var onFocus: (() -> Void)? = nil
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader(onFocus: onFocus) { focused in
            configuration.label
                .modifier(BPFocusModifier(focused: focused, pressed: configuration.isPressed, radius: radius))
        }
    }
}

/// Text action button: panel face, edge border, brightens to `on` when focused.
struct BPActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .opacity(enabled ? 1 : 0.45)
                .font(BP.sans(15, .semibold))
                .foregroundStyle(primary ? BP.canvas : BP.ink)
                .padding(.horizontal, BP.px(18))
                .frame(minHeight: BP.tabItem)
                .background(
                    RoundedRectangle(cornerRadius: BP.rSM, style: .continuous)
                        .fill(primary ? (focused ? BP.ink : BP.ink.opacity(0.9)) : (focused ? BP.on : BP.panel2))
                )
                .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge2, lineWidth: 1))
                .modifier(BPFocusModifier(focused: focused, pressed: configuration.isPressed, radius: BP.rSM, lift: 1.02))
        }
    }
}

/// Icon-only top-bar tab: square, `on` face when active, no ring, just brightness.
struct BPTabStyle: ButtonStyle {
    var active: Bool
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .foregroundStyle(active || focused ? BP.ink : BP.inkSubtle)
                .frame(width: BP.tabItem, height: BP.tabItem)
                .background(RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).fill(active ? BP.on : (focused ? BP.glass : .clear)))
                .overlay {
                    if focused { RoundedRectangle(cornerRadius: BP.rXS, style: .continuous).stroke(BP.focusStroke, lineWidth: 3) }
                }
                .scaleEffect(focused ? 1.06 : 1)
                .animation(BP.easeFast, value: focused)
        }
    }
}

/// Lets a ButtonStyle body read the focus state of the button it decorates. Every focus it
/// gains plays the theme's hover (use-bp-focus.ts moveFocus: SFX.hover()).
struct BPFocusReader<Content: View>: View {
    @Environment(\.isFocused) private var focused
    let onFocus: (() -> Void)?
    let content: (Bool) -> Content
    init(onFocus: (() -> Void)? = nil, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.onFocus = onFocus
        self.content = content
    }
    var body: some View {
        content(focused)
            .onChange(of: focused) { _, now in
                guard now else { return }
                onFocus?()
                BPSound.shared.hover()
            }
    }
}

/// Text field styled as a Big Picture input. Focusing does not start editing;
/// pressing Select opens the tvOS keyboard, which is exactly upstream's rule.
struct BPField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var secure = false
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            Text(label).font(BP.sans(13, .semibold)).foregroundStyle(BP.inkMuted)
            Group {
                if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
            }
            .font(BP.sans(17))
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.plain)
            .padding(.horizontal, BP.px(14))
            .frame(height: BP.px(50))
            .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
            .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge2, lineWidth: 1))
        }
    }
}

struct BPNote: View {
    let text: String
    var tone: Color = BP.inkMuted
    var body: some View { Text(text).font(BP.sans(14)).foregroundStyle(tone).fixedSize(horizontal: false, vertical: true) }
}
