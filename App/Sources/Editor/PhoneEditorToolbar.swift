import SwiftUI

/// Compact iPhone chrome preserves room for the document's name. File and
/// settings actions share the existing menu; undo and redo stay one tap away.
struct PhoneEditorToolbar: ToolbarContent {

    let documentTitle: String
    let showToolbarPref: Bool
    let claimFocus: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // Tappable / renameable title replaces the system
            // navigationTitle so the iPhone gets inline
            // rename without a separate sheet.
            EditableTitleView(
                title: documentTitle,
                titleFont: .headline,
                maxRenameWidth: 200
            )
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                claimFocus()
                CommandActions.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .accessibilityLabel("Undo")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                claimFocus()
                CommandActions.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .accessibilityLabel("Redo")
        }
        ToolbarItem(placement: .topBarTrailing) {
            combinedMenu
        }
    }

    @ViewBuilder
    private var combinedMenu: some View {
        let slots = ToolbarConfig.shared.slots
        Menu {
            // Core actions stay available with customized toolbar actions hidden.
            Button {
                claimFocus()
                CommandActions.presentCommandPalette()
            } label: {
                Label("Command Palette…", systemImage: "command.square")
            }
            Button {
                claimFocus()
                CommandActions.presentFileBrowser()
            } label: {
                Label("Open File…", systemImage: "folder")
            }
            Button {
                claimFocus()
                CommandActions.presentPreferences()
            } label: {
                Label("Settings…", systemImage: "gear")
            }
            if showToolbarPref, !slots.isEmpty {
                Divider()
                ForEach(slots) { slot in
                    if let cmd = CommandRegistry.lookup(id: slot.commandId) {
                        Button {
                            claimFocus()
                            if cmd.isEnabled() { cmd.action() }
                        } label: {
                            Label(cmd.title, systemImage: slot.symbol.isEmpty ? "questionmark" : slot.symbol)
                        }
                        .disabled(!cmd.isEnabled())
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.rectangle")
                .symbolRenderingMode(.hierarchical)
        }
        .accessibilityLabel("Toolbar Actions")
    }
}
