// Tab editing for the TV's top bar, on upstream's sidebar model (chrome/nav-items.tsx +
// chrome/nav-edit.tsx, "in-place sidebar editing with hide, reorder and hidden tray"):
// `settings.navCustomization` = { order, hidden, renamed } keyed by NavItemId. The TV reads the
// same object the desktop sidebar writes, so a tab hidden or moved on either follows the profile.
//  - Hide / show: toggleNavHidden. Show all: `{ ...cfg, hidden: [] }`. Reset: resetNavCustomization.
//  - Order: applyNavCustomization over the TV's tabs, so an untouched layout (`order: []`) keeps
//    the Big Picture order and a saved order is followed.
//  - Move: moveNavItem against a neighbour (context-menu.tsx "Move up" / "Move down") on the bar
//    the viewer sees; the result goes back into the shared order in the slots the TV's tabs hold
//    there (effectiveNavOrder), so desktop-only items (Catalogs, Downloads…) never shift.
// settings/load.ts `_navHideMigrateV1` already turned the retired hideContent.manga / .liveTv
// switches into hidden "manga" / "live" entries, so a viewer's earlier choice carries over.
// TV-only: Home stays first and visible (Back lands there, bp-shell popBigPicture), and a tab
// with no NavItemId (Search, a Big Picture tab) keeps its slot; the others fill the rest in order.
import { applyNavCustomization, effectiveNavOrder, moveNavItem, NAV_ITEMS, resetNavCustomization, toggleNavHidden, type NavCustomization, type NavItem } from "@/chrome/nav-items";
import { loadEffective, persistEffective } from "@/lib/settings/profile-store";
import { markSettingsPatched } from "./sync";

const NAV_BY_ID = new Map<string, NavItem>(NAV_ITEMS.map((it) => [it.id, it]));
const NAV_IDS = new Set<string>(NAV_BY_ID.keys());
const PINNED = new Set(["home"]);

/** A room the bar may hide or move: it has a NavItemId and is not pinned. */
function editable(room: string): boolean {
  return NAV_IDS.has(room) && !PINNED.has(room);
}

function cfgOf(profileId: string, linked: boolean): NavCustomization {
  const nav = loadEffective(profileId, linked).navCustomization as Partial<NavCustomization> | undefined;
  return {
    order: Array.isArray(nav?.order) ? nav.order.filter((x): x is string => typeof x === "string") : [],
    hidden: Array.isArray(nav?.hidden) ? nav.hidden.filter((x): x is string => typeof x === "string") : [],
    renamed: nav?.renamed && typeof nav.renamed === "object" ? nav.renamed : {},
  };
}

function write(profileId: string, linked: boolean, next: NavCustomization): void {
  const s = loadEffective(profileId, linked);
  persistEffective({ ...s, navCustomization: next }, profileId, linked);
  markSettingsPatched(["navCustomization"]);
  window.dispatchEvent(new CustomEvent("harbor:settings-updated", { detail: { profileId, fields: ["navCustomization"] } }));
}

export type NavLayout = {
  /** Every tab in `tabs`, in bar order. */
  order: string[];
  /** The tabs the viewer hid (never a pinned or non-nav tab). */
  hidden: string[];
};

/**
 * The bar's arrangement for `tabs` (Swift's Room.tabs, default order): pinned and non-nav tabs keep
 * their slots, the editable ones take the remaining slots in effectiveNavOrder.
 */
export function layout(tabs: string[], profileId: string, linked: boolean): NavLayout {
  const cfg = cfgOf(profileId, linked);
  const movable = movableOrder(tabs, cfg);
  let next = 0;
  const order = tabs.map((room) => (editable(room) ? movable[next++] ?? room : room));
  const hidden = tabs.filter((room) => editable(room) && cfg.hidden.includes(room));
  return { order, hidden };
}

/** The editable tabs in bar order: applyNavCustomization over them, hidden ones included. */
function movableOrder(tabs: string[], cfg: NavCustomization): string[] {
  const items = tabs.filter(editable).map((id) => NAV_BY_ID.get(id)).filter((it): it is NavItem => !!it);
  return applyNavCustomization(items, { ...cfg, hidden: [] }).map((it) => it.id);
}

/** The shared order with the TV's tabs re-laid in `tvOrder`, every other item in its slot. */
function withTvOrder(cfg: NavCustomization, tvOrder: string[]): NavCustomization {
  const full = effectiveNavOrder(cfg);
  const onTv = new Set(tvOrder);
  let next = 0;
  return { ...cfg, order: full.map((id) => (onTv.has(id) ? tvOrder[next++] ?? id : id)) };
}

/** nav-edit.tsx NavHideBadge / the tray's "Show this tab": toggleNavHidden. */
export function toggleHidden(room: string, tabs: string[], profileId: string, linked: boolean): NavLayout {
  if (editable(room)) write(profileId, linked, toggleNavHidden(cfgOf(profileId, linked), room));
  return layout(tabs, profileId, linked);
}

/**
 * context-menu.tsx "Move up" / "Move down": moveNavItem(cfg, room, neighbour, before|after). The TV
 * passes the neighbouring shown tab, so the move is one step on the bar the viewer sees.
 */
export function move(room: string, neighbour: string, position: "before" | "after", tabs: string[], profileId: string, linked: boolean): NavLayout {
  const cfg = cfgOf(profileId, linked);
  const current = movableOrder(tabs, cfg);
  if (editable(room) && editable(neighbour) && room !== neighbour && current.includes(room) && current.includes(neighbour)) {
    const onTv = new Set(current);
    const moved = moveNavItem({ ...cfg, order: current }, room, neighbour, position === "after" ? "after" : "before");
    write(profileId, linked, withTvOrder(cfg, moved.order.filter((id) => onTv.has(id))));
  }
  return layout(tabs, profileId, linked);
}

/** "Show all tabs": `{ ...cfg, hidden: [] }`. */
export function showAll(tabs: string[], profileId: string, linked: boolean): NavLayout {
  write(profileId, linked, { ...cfgOf(profileId, linked), hidden: [] });
  return layout(tabs, profileId, linked);
}

/** "Reset layout": resetNavCustomization (order, hidden and renamed all cleared). */
export function reset(tabs: string[], profileId: string, linked: boolean): NavLayout {
  write(profileId, linked, resetNavCustomization());
  return layout(tabs, profileId, linked);
}
