import SwiftUI

/// Compact iPhone chrome preserves room for the document's name. File and
/// settings actions share Tool Menu; two quick buttons are configurable.
struct PhoneEditorToolbar: ToolbarContent {

    let documentTitle: String
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
            HStack(spacing: 2) {
                QuickToolbarButtons(onInteraction: claimFocus, touchTarget: 34)
                Button {
                    claimFocus()
                    CommandActions.presentCommandPalette()
                } label: {
                    Image(systemName: EditorChrome.commandPaletteSymbol)
                            .font(.system(size: 16, weight: .regular))
                        .frame(width: 34, height: 44)
                }
                .accessibilityLabel(EditorChrome.commandPaletteTitle)
                .accessibilityIdentifier("command-palette")
                combinedMenu
                    .frame(width: 34, height: 44)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var combinedMenu: some View {
        let slots = ToolbarConfig.shared.slots
        Menu {
            // Core actions stay available alongside the configured tools.
            Button {
                claimFocus()
                CommandActions.presentCommandPalette()
            } label: {
                Label(EditorChrome.commandPaletteTitle + "…", systemImage: EditorChrome.commandPaletteSymbol)
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
            if !slots.isEmpty {
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
        .accessibilityLabel(EditorChrome.toolMenuTitle)
        .accessibilityIdentifier("tool-menu")
    }
}
