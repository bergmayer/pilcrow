import SwiftUI

/// Tappable, renameable document title used by both the iPad
/// `WindowToolbar` and the iPhone nav-bar principal item.
///
/// Display mode: tap fires save-as for an untitled document, or
/// enters inline rename mode for a saved one. Long-press shows a
/// context menu with Rename / Duplicate / Save (a Copy) options.
///
/// Rename mode: a focused `TextField` replaces the label; ⏎ commits
/// via `CommandActions.renameCurrentFile(to:)`, ✕ cancels.
struct EditableTitleView: View {

    let title: String
    let subtitle: String
    let titleFont: Font
    let subtitleFont: Font
    let maxRenameWidth: CGFloat
    /// Optional closure the hosting toolbar installs to "claim
    /// focus" — i.e. update `AppStateBus.shared.scenes.currentEditor`
    /// + `currentSession` to the scene that owns *this* title.
    /// Every action in this view must fire it before invoking
    /// CommandActions, otherwise a tap on the title in window A can
    /// surface its save dialog / rename inside whichever window
    /// happens to be `currentEditor` on the bus (typically the most
    /// recently activated one — i.e. **NOT** the one the user just
    /// tapped). The `?` accommodates the iPhone nav-bar caller,
    /// which is single-window and doesn't need the dance.
    let onInteraction: (() -> Void)?

    @State private var renameDraft: String?
    @FocusState private var renameFocus: Bool

    init(
        title: String,
        subtitle: String = "",
        titleFont: Font = .system(size: 17, weight: .semibold),
        subtitleFont: Font = .caption,
        maxRenameWidth: CGFloat = 260,
        onInteraction: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.titleFont = titleFont
        self.subtitleFont = subtitleFont
        self.maxRenameWidth = maxRenameWidth
        self.onInteraction = onInteraction
    }

    var body: some View {
        Group {
            if renameDraft != nil {
                renameField
            } else {
                displayTitle
            }
        }
        // Dismiss the rename field when focus is taken by another
        // view (i.e. the user tapped outside the field). Discard the
        // draft rather than commit — ⏎ remains the explicit save
        // gesture; "tap somewhere else" is the cancel gesture, same
        // as Finder. The `renameDraft != nil` guard prevents this
        // from firing when `commitRename()` itself clears focus.
        .onChange(of: renameFocus) { _, focused in
            if !focused && renameDraft != nil {
                renameDraft = nil
            }
        }
    }

    @ViewBuilder
    private var displayTitle: some View {
        Button(action: handleTap) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(subtitleFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(currentFileURL == nil
            ? "Untitled. Double-tap to save."
            : "Double-tap to rename. Press and hold for more options."
        )
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var renameField: some View {
        HStack(spacing: 6) {
            TextField("Filename", text: Binding(
                get: { renameDraft ?? "" },
                set: { renameDraft = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .focused($renameFocus)
            .font(titleFont)
            .frame(maxWidth: maxRenameWidth)
            .onSubmit { commitRename() }
            .submitLabel(.done)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            // Hardware-keyboard ESC cancels the rename. iPad users with
            // a Magic Keyboard expect this; the on-screen keyboard's
            // ⏎ key still commits via `.onSubmit`.
            .onKeyPress(.escape) {
                renameDraft = nil
                return .handled
            }
            Button {
                renameDraft = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel rename")
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            onInteraction?()
            CommandActions.saveFileAs()
        } label: {
            Label("Save As…", systemImage: "square.and.arrow.down")
        }
        Menu {
            Button("Share Text…") { onInteraction?(); CommandActions.shareText() }
            Button("Share File…") { onInteraction?(); CommandActions.shareFile() }
        } label: { Label("Share", systemImage: "square.and.arrow.up") }
        Button { onInteraction?(); CommandActions.printDocument() } label: {
            Label("Print…", systemImage: "printer")
        }
        Button {
            onInteraction?()
            CommandActions.duplicateCurrentTab()
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
    }

    private func handleTap() {
        // Claim foreground on the bus FIRST. The title sits in a
        // per-window toolbar; without this, tapping the title in
        // window A while window B was the most-recently-active
        // surfaced the Save / rename UI in B (whichever owned
        // `currentEditor`). The closure mutates the bus to point
        // at this window's session + state, so every subsequent
        // CommandActions call lands here.
        onInteraction?()
        if currentFileURL == nil {
            CommandActions.saveFileAs()
        } else {
            beginRename()
        }
    }

    private func beginRename() {
        guard let url = currentFileURL else { return }
        renameDraft = url.deletingPathExtension().lastPathComponent
        // One-tick defer so the TextField is in the hierarchy before
        // focus is requested — without this, SwiftUI sometimes drops
        // the focus binding on the first present.
        DispatchQueue.main.async { renameFocus = true }
    }

    private func commitRename() {
        defer { renameDraft = nil; renameFocus = false }
        guard let draft = renameDraft?.trimmingCharacters(in: .whitespacesAndNewlines),
              !draft.isEmpty else { return }
        onInteraction?()
        CommandActions.renameCurrentFile(to: draft)
    }

    private var currentFileURL: URL? {
        AppStateBus.shared.scenes.currentSession?.activeTab.document.fileURL
    }

    private var currentTab: TabModel? {
        AppStateBus.shared.scenes.currentSession?.activeTab
    }
}
