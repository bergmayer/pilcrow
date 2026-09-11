import SwiftUI

/// Per-scene reference to the active session. Menu commands that
/// need to act on the foreground window's tabs (New Tab, Close Tab,
/// Reopen Closed Tab, Next/Previous Tab, Jump to Tab, Show All
/// Tabs, etc.) read this via `@FocusedValue` so they always hit
/// the focused window's session even when `AppStateBus.scenes
/// .currentSession` lags. Each `EditorScene.onAppear` publishes
/// its own session.
struct FocusedSessionKey: FocusedValueKey {
    typealias Value = EditorSession
}

extension FocusedValues {
    var focusedSession: EditorSession? {
        get { self[FocusedSessionKey.self] }
        set { self[FocusedSessionKey.self] = newValue }
    }
}
