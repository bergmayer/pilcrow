import UIKit

/// Single source of truth for "are we running on iPhone vs iPad".
/// iPhone is single-window by OS design, so the menu / scene routing
/// code collapses overlays and hides New Window on it. iPad gets the
/// full multi-window experience; the user can opt into per-tab
/// routing via the `openDocumentDestination` preference.
enum DeviceIdiom {

    /// Captured once at first access. `UIDevice.userInterfaceIdiom`
    /// is main-actor isolated under Swift 6 strict concurrency, but
    /// the value is constant per device — caching it via
    /// `MainActor.assumeIsolated` lets the rest of the codebase read
    /// `isPhone` from any context (SwiftUI bodies, View structs,
    /// nonisolated value types) without warnings. Call sites that
    /// might run before any UI is up must ensure they're on the
    /// main thread first.
    private static let userInterfaceIdiom: UIUserInterfaceIdiom = {
        MainActor.assumeIsolated {
            UIDevice.current.userInterfaceIdiom
        }
    }()

    /// `true` when running on iPhone (or iPhone-sized window on a
    /// device that can host one — currently no such configuration
    /// exists, but the check stays idiom-based for clarity).
    static var isPhone: Bool {
        userInterfaceIdiom == .phone
    }

    /// `true` on iPad, where multiple scenes can appear side by side.
    /// An affirmative check keeps an `.unspecified` idiom from
    /// accidentally enabling multi-window UI on iPhone.
    static var supportsMultipleWindows: Bool {
        userInterfaceIdiom == .pad
    }
}
