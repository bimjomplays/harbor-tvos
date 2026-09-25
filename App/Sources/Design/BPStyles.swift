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
    /// Its own action is running: dimmed like a disabled button but still focusable, so the ring
    /// stays on the button the viewer pressed (a disabled button drops focus on tvOS). The action
    /// guards re-entry itself.
    var busy = false
    @Environment(\.isEnabled) private var enabled
    /// Theme button styles (index.css html[data-theme-button]): crunch sets .bg-ink bold with
    /// 0.02em tracking; glossy lays a top shine over .bg-ink. Flat (the default) adds nothing.
    private var style: String { BPThemeState.current.buttonStyle }
    func makeBody(configuration: Configuration) -> some View {
        BPFocusReader { focused in
            configuration.label
                .opacity(enabled && !busy ? 1 : 0.45)
                .font(BP.sans(15, primary && style == "crunch" ? .bold : .semibold))
                .tracking(primary && style == "crunch" ? BP.px(15) * 0.02 : 0)
                .foregroundStyle(primary ? BP.canvas : BP.ink)
                .padding(.horizontal, BP.px(18))
                .frame(minHeight: BP.tabItem)
                .background(
                    RoundedRectangle(cornerRadius: BP.rSM, style: .continuous)
                        .fill(primary ? (focused ? BP.ink : BP.ink.opacity(0.9)) : (focused ? BP.on : BP.panel2))
                )
                .overlay {
                    if primary && style == "glossy" {
                        RoundedRectangle(cornerRadius: BP.rSM, style: .continuous)
                            .fill(LinearGradient(stops: [.init(color: BP.ink.opacity(0.22), location: 0), .init(color: BP.ink.opacity(0), location: 0.55)],
                                                 startPoint: .top, endPoint: .bottom))
                            .allowsHitTesting(false)
                    }
                }
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
///
/// Long text (every URL field, plus any field that passes `phone: true`) also gets a phone
/// button: decision 7, long text is typed on the phone (PhoneTypingSheet, bp-phone-typing.tsx).
struct BPField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var secure = false
    var keyboard: UIKeyboardType = .default
    /// nil: offered for URL fields only. Secret fields never get it unless a caller asks.
    var phone: Bool? = nil
    /// (review 24) Optional: binds the text field's focus, so a caller can hand it the ring (a
    /// Clear beside it that leaves with the query it clears). nil leaves the field as it was.
    var focus: FocusState<Bool>.Binding? = nil
    @State private var phoneOpen = false

    private var offersPhone: Bool { phone ?? (keyboard == .URL && !secure) }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(6)) {
            Text(T(label)).font(BP.sans(13, .semibold)).foregroundStyle(BP.inkMuted)
            HStack(spacing: BP.px(8)) {
                Group {
                    if secure { SecureField(T(placeholder), text: $text) } else { TextField(T(placeholder), text: $text) }
                }
                .font(BP.sans(17))
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .modifier(BPFieldFocus(focus: focus))
                .padding(.horizontal, BP.px(14))
                .frame(height: BP.px(50))
                .background(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).fill(BP.panel2))
                .overlay(RoundedRectangle(cornerRadius: BP.rSM, style: .continuous).stroke(BP.edge2, lineWidth: 1))
                if offersPhone {
                    Button { phoneOpen = true } label: {
                        Image(systemName: "iphone").font(.system(size: BP.px(18), weight: .semibold))
                    }
                    .buttonStyle(BPActionStyle())
                    .accessibilityLabel("Type on your phone")
                }
            }
        }
        .fullScreenCover(isPresented: $phoneOpen) {
            PhoneTypingSheet(label: label, placeholder: placeholder, text: $text, secure: secure,
                             purpose: "Scan this with your phone camera, then type straight into “\(label)” on your phone.",
                             onClose: { phoneOpen = false })
        }
    }
}

/// BPField's optional focus binding: applied only when a caller passes one.
private struct BPFieldFocus: ViewModifier {
    let focus: FocusState<Bool>.Binding?
    @ViewBuilder func body(content: Content) -> some View {
        if let focus { content.focused(focus) } else { content }
    }
}

struct BPNote: View {
    let text: String
    var tone: Color = BP.inkMuted
    var body: some View { Text(T(text)).font(BP.sans(14)).foregroundStyle(tone).fixedSize(horizontal: false, vertical: true) }
}

/// index.css html[data-theme-card="glass"] on a surface panel: an ink sheen from the top and an
/// inset highlight on the top edge, painted behind the content (apply it before the panel fill).
/// Every other card style leaves the panel as drawn.
struct BPThemeCardFace: ViewModifier {
    var radius: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        if BPThemeState.current.cardStyle == "glass" {
            content.background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [BP.ink.opacity(0.05), BP.ink.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .top) {
                        Rectangle().fill(BP.ink.opacity(0.14)).frame(height: 1).padding(.horizontal, radius)
                    }
                    .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

extension View {
    /// VoiceOver's "selected" for a chip, tab or option that draws its picked state (aria-pressed /
    /// data-bp-tab-on upstream). A Bool in, so busy view bodies stay cheap to type-check.
    func bpSelected(_ on: Bool) -> some View {
        accessibilityAddTraits(on ? .isSelected : [])
    }

    /// VoiceOver's value for a drawn progress bar (a resume bar, a now-playing programme): upstream's
    /// "{n}% watched" by default. Nothing is read outside 1–99 %, where no bar is drawn.
    func bpProgressValue(_ fraction: Double?, key: String = "%lld%% watched") -> some View {
        let pct = clampedInt(((fraction ?? 0) * 100).rounded())
        let text: String = pct >= 1 && pct <= 99 ? T(key, pct) : ""
        return accessibilityValue(Text(verbatim: text))
    }
}
