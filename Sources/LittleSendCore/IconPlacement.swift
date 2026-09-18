import Foundation

/// Where LittleSend shows its icon: the Dock, the menu bar, or both.
///
/// There is no "neither": with no Dock icon and no menu bar icon there would be
/// no way back into the app short of launching it again, so every case keeps at
/// least one.
public enum IconPlacement: String, CaseIterable, Codable, Sendable {
    case both
    case dock
    case menuBar

    public var displayName: String {
        switch self {
        case .both: return "Dock and menu bar"
        case .dock: return "Dock only"
        case .menuBar: return "Menu bar only"
        }
    }

    public var showsDockIcon: Bool { self != .menuBar }
    public var showsMenuBarIcon: Bool { self != .dock }
}
