import Foundation

enum DocumentDestination: String, CaseIterable, Identifiable {
    case window = "window"
    case tab    = "tab"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .window: "New window"
        case .tab:    "New tab"
        }
    }

    /// Default for an immediate Open action; picker owners capture an
    /// explicit destination when the picker is presented.
    @MainActor
    static func current() -> DocumentDestination {
        DeviceIdiom.isPhone ? .tab : .window
    }
}
