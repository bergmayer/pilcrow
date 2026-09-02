import SwiftUI

/// Long-press menu attached to the "show all tabs" button — both
/// the iPad chrome's `showAllTabsButton` in `TabBarView` and the
/// iPhone status bar's `phoneTabsButton`. Tap on the button still
/// opens the expose-style switcher; this menu carries the tab-
/// management actions that don't fit in the switcher itself.
/// Keeping the entries here means the two surfaces stay in
/// lockstep instead of drifting as new commands land.
struct TabOverviewContextMenu: View {

    /// The window that owns the long-pressed button. Injected —
    /// re-claiming the bus's `currentSession` was a no-op, so a
    /// long-press in window A while focus pointed at window B sent
    /// the Close commands to window B.
    let session: EditorSession

    var body: some View {
        Button {
            claimFocus()
            CommandActions.newTab()
        } label: {
            Label("Open New Tab", systemImage: "plus.square")
        }
        Button {
            claimFocus()
            CommandActions.newFromTemplate()
        } label: {
            Label("New from Template…", systemImage: "doc.badge.plus")
        }
        Divider()
        Button(role: .destructive) {
            claimFocus()
            CommandActions.requestCloseTab(session.selectedTabID, in: session)
        } label: {
            Label("Close This Tab", systemImage: "xmark")
        }
        Button(role: .destructive) {
            claimFocus()
            CommandActions.requestCloseOtherTabs(except: session.selectedTabID, in: session)
        } label: {
            Label("Close Other Tabs", systemImage: "rectangle.stack.badge.minus")
        }
        Button(role: .destructive) {
            claimFocus()
            CommandActions.requestCloseTabsToRight(of: session.selectedTabID, in: session)
        } label: {
            Label("Close Tabs to the Right", systemImage: "rectangle.righthalf.inset.filled.arrow.right")
        }
        Button(role: .destructive) {
            claimFocus()
            CommandActions.requestCloseAllTabs(in: session)
        } label: {
            Label("Close All Tabs", systemImage: "xmark.square.fill")
        }
    }

    /// Pin the owning session as the current scene before firing
    /// the action so the dialog / close lands in this window.
    private func claimFocus() {
        AppStateBus.shared.scenes.claimFocus(session: session)
    }
}
