import SwiftUI

/// Named app-wide spring animations. Centralizing the magic numbers
/// keeps visual tuning consistent across panel toggles, switcher
/// morphs, and tab-bar transitions, and gives one place to retune
/// the whole app's feel.
extension Animation {
    /// Quick spring used by panel toggles (sidebar, split view,
    /// inspector flips). Snappy but not abrupt.
    static let appSnappyPanel   = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// Slightly longer spring used by the tab switcher morph and
    /// scene-level transitions, where the user expects to follow
    /// the motion of the moving frame.
    static let appSwitcherMorph = Animation.spring(response: 0.42, dampingFraction: 0.86)
    /// Faster spring used by the in-switcher card flips — tabs
    /// reordering / closing inside the switcher overlay.
    static let appSwitcherCard  = Animation.spring(response: 0.28, dampingFraction: 0.85)
}

/// Named durations used across the app. Keeps magic nanosecond
/// literals out of the call sites and makes timing knobs adjustable
/// in one place.
enum Timing {
    /// Delay from the first uncheckpointed edit. Further typing must
    /// not reset this timer and indefinitely postpone crash recovery.
    static let autoSaveInterval: Duration = .milliseconds(800)
    /// Coalesces native edits before publishing the buffer to SwiftUI.
    static let bufferSnapshotDebounce: Duration = .milliseconds(300)
    /// UTF-16 length ceiling for either side of the change-history comparison.
    static let changeHistoryGutterLengthLimit = 250 * 1024
    /// Brief yield before applying the post-load text so SwiftUI
    /// can paint the loading overlay first.
    static let loadOverlayHandoff: Duration = .milliseconds(100)
    /// Poll interval while waiting for an iCloud item to finish
    /// downloading.
    static let ubiquitousItemPoll: Duration = .milliseconds(200)
    /// Wait after dismissing the palette before its selected command
    /// runs. iOS sheet dismissal takes ~300-400 ms; the previous
    /// 80 ms left the sheet mid-animation when the command tried to
    /// present its own modal (Save dialog, unsaved-changes
    /// confirmation, etc.), which iOS either drops silently — data
    /// loss on the Close-Tab → unsaved warning path — or queues
    /// forever (app freeze). 500 ms is comfortable headroom without
    /// feeling laggy.
    static let paletteHandoff: Duration = .milliseconds(500)
}
