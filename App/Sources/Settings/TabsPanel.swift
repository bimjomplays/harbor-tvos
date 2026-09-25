import SwiftUI

/// Settings → Tabs: upstream's in-place sidebar editing (chrome/nav-edit.tsx: hide badge, reorder,
/// the hidden tray with "Show this tab" / "Show all" / "Reset layout") as a list the remote can
/// walk. It edits settings.navCustomization through engine/navEdit.ts, the same object the
/// desktop sidebar edits, so the top bar and the desktop follow each other per profile. Rows run
/// in bar order, hidden ones dimmed in place; Move up / Move down step past a neighbour the way
/// context-menu.tsx's nav items do (navNeighbors counts hidden items too). Home and Search stay put.
struct TabsPanel: View {
    @EnvironmentObject private var settings: SettingsBridge

    private var rows: [Room] { Room.arranged(settings.navLayout).filter(\.navEditable) }
    private var hidden: Set<String> { Set(settings.navLayout?.hidden ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: BP.px(8)) {
            BPNote(text: "Hide or reorder the tabs in the top bar. Home and Search stay put. Long-press a tab in the bar to hide it.")
            let list = rows
            ForEach(Array(list.enumerated()), id: \.element) { i, r in
                let isHidden = hidden.contains(r.rawValue)
                HStack(spacing: BP.px(8)) {
                    Image(systemName: r.icon).font(.system(size: BP.px(15), weight: .semibold))
                        .foregroundStyle(isHidden ? BP.inkSubtle : BP.ink).frame(width: BP.px(28))
                        .accessibilityHidden(true)
                    Text(T(r.label)).font(BP.sans(14, isHidden ? .regular : .semibold))
                        .foregroundStyle(isHidden ? BP.inkSubtle : BP.ink).lineLimit(1)
                        .frame(width: BP.px(300), alignment: .leading)
                    // (settings device pass) Dimmed, not disabled, at the ends: a tab moved to the
                    // first or last place disabled the arrow under the ring, which jumped off the list.
                    let top = i == 0
                    let bottom = i == list.count - 1
                    Button { if !top { Task { await settings.moveTab(r, beside: list[i - 1], after: false) } } } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(BPActionStyle(busy: top))
                        .accessibilityLabel(T("Move up"))
                    Button { if !bottom { Task { await settings.moveTab(r, beside: list[i + 1], after: true) } } } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(BPActionStyle(busy: bottom))
                        .accessibilityLabel(T("Move down"))
                    Button(T(isHidden ? "Show this tab" : "Hide this tab")) { Task { await settings.toggleTabHidden(r) } }
                        .buttonStyle(BPActionStyle(primary: isHidden))
                }
            }
            if hidden.isEmpty { BPNote(text: "Nothing hidden.") }
            HStack(spacing: BP.px(12)) {
                // Pressing it empties the hidden set: dimmed rather than disabled under the ring.
                let none = hidden.isEmpty
                Button(T("Show all tabs")) { if !none { Task { await settings.showAllTabs() } } }
                    .buttonStyle(BPActionStyle(busy: none))
                Button(T("Reset layout")) { Task { await settings.resetTabs() } }
                    .buttonStyle(BPActionStyle())
            }
        }
        .task { if settings.navLayout == nil { await settings.loadNavLayout() } }
    }
}
