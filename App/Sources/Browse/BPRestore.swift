import Foundation

/// bp-restore.ts: focus memory, in memory only (a relaunch starts fresh, as upstream's module
/// maps do). Two memories, deliberately separate: route entry restores one cell for the whole
/// page; entering a row restores that row's own last cell. Keys are the row's own key, never
/// its position, because rows renumber when Continue Watching or the Live row come and go.
/// The route key carries the profile, standing in for use-bp-profile-reset's clear.
@MainActor
enum BPRestore {
    struct Position: Equatable { var row: String; var cell: String }

    private static var positions: [String: Position] = [:]
    private static var rowCells: [String: String] = [:]

    private static func slot(_ route: String, _ row: String) -> String { route + "\u{0}" + row }

    static func remember(route: String, row: String, cell: String) {
        guard !route.isEmpty, !row.isEmpty, !cell.isEmpty else { return }
        positions[route] = Position(row: row, cell: cell)
        rowCells[slot(route, row)] = cell
    }

    static func position(_ route: String) -> Position? { positions[route] }
    static func rowCell(_ route: String, _ row: String) -> String? { rowCells[slot(route, row)] }
    static func forget(_ route: String) { positions[route] = nil }
}
