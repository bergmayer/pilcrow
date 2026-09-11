import SwiftUI

/// Renders the three-flavor stale-source alert (missing / changed
/// on adopt / changed on save) attached to `EditorView`. Lives in
/// its own file because inlining the switch-driven `Button`/`Text`
/// closures in `EditorView.body` blew the Swift type-checker's
/// expression budget.
struct StaleSourceAlertModifier: ViewModifier {

    let title: String
    @Binding var presented: Bool
    let check: SourceStaleCheck?
    let cancel: () -> Void

    func body(content: Content) -> some View {
        content.alert(
            title,
            isPresented: $presented,
            presenting: check
        ) { check in
            buttons(for: check)
        } message: { check in
            message(for: check)
        }
    }

    @ViewBuilder
    private func buttons(for check: SourceStaleCheck) -> some View {
        switch check {
        case .missing:
            Button("OK") { CommandActions.acknowledgeSourceMissing() }
        case .changedOnAdopt:
            Button("Continue Editing") { CommandActions.acceptStaleAdopt() }
            Button("Reload File", role: .destructive) { CommandActions.reloadAfterStale() }
        case .changedOnSave:
            Button("Save Anyway", role: .destructive) { CommandActions.forceSaveAfterStale() }
            Button("Reload from Disk", role: .destructive) { CommandActions.reloadAfterStale() }
            Button("Cancel", role: .cancel, action: cancel)
        }
    }

    @ViewBuilder
    private func message(for check: SourceStaleCheck) -> some View {
        switch check {
        case .missing:
            Text("\(check.displayName) is no longer at its original location. Your changes are preserved as an untitled document — use Save As to pick a new location.")
        case .changedOnAdopt:
            Text("\(check.displayName) has changed on disk since these unsaved changes were preserved. Continue editing your version, or reload the file from disk and discard the recovered changes.")
        case .changedOnSave:
            Text("\(check.displayName) has been modified on disk since you opened it. Save Anyway overwrites the disk copy; Reload discards your unsaved edits.")
        }
    }
}
