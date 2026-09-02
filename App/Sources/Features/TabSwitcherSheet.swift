import SwiftUI

/// Safari-style tab switcher (the "expose" view) presented inline by
/// `EditorScene` — not as a sheet. The active tab's card shares a
/// `matchedGeometryEffect` namespace with the editor stack, so toggling
/// the switcher visibly shrinks the editor into its grid card and grows
/// it back out on dismiss.
///
/// Footer mirrors Safari: tab count on the left, `+` button (long-press
/// for recently-closed) in the middle, Done (✓) on the right.
struct TabSwitcherView: View {

    @Bindable var session: EditorSession
    let namespace: Namespace.ID
    /// The match id paired with `EditorScene.editorStack` so the
    /// active card and the editor frame are the same animated geometry.
    let matchID: String
    let onDismiss: () -> Void

    /// Adaptive grid: ~160pt cards. iPhone portrait yields 2 columns,
    /// iPad lands 3–5 depending on width. Matches Safari's density.
    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            gridScroll
            footer
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Spacer()
            Text(title)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder
    private var gridScroll: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(session.tabs) { tab in
                    card(for: tab)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            plusMenu
            Spacer()
            Button {
                AppStateBus.shared.scenes.claimFocus(session: session)
                onDismiss()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Done")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var title: String {
        let n = session.tabs.count
        return "\(n) Tab\(n == 1 ? "" : "s")"
    }

    @ViewBuilder
    private func card(for tab: TabModel) -> some View {
        baseCard(for: tab)
            .matchedGeometryEffect(
                id: matchedID(for: tab),
                in: namespace,
                properties: .frame,
                isSource: tab.id == session.selectedTabID
            )
    }

    @ViewBuilder
    private func baseCard(for tab: TabModel) -> some View {
        TabCard(
            tab: tab,
            isActive: tab.id == session.selectedTabID,
            // A single-tab session is closeable when that tab has
            // real content (`.editor` / `.fileBrowser`) — closing
            // spawns a fresh launcher in its place. The exception
            // is a lone launcher tab: closing it would just spawn
            // another launcher, so we hide the X to avoid the
            // pointless gesture.
            canClose: session.tabs.count > 1 || tab.kind != .launcher,
            onSelect: { activate(tab) },
            onClose:  { CommandActions.requestCloseTab(tab.id, in: session) },
            onPin:    { session.togglePinned(tab.id) },
            onCloseOthers: { CommandActions.requestCloseOtherTabs(except: tab.id, in: session) },
            onCloseRight:  { CommandActions.requestCloseTabsToRight(of: tab.id, in: session) }
        )
    }

    /// Active tab gets the shared match id (paired with the editor
    /// stack). Other tabs get unique ids so they animate in/out
    /// independently — they don't morph from the editor.
    private func matchedID(for tab: TabModel) -> String {
        tab.id == session.selectedTabID ? matchID : "tab-card-\(tab.id)"
    }

    @ViewBuilder
    private var plusMenu: some View {
        Menu {
            Button {
                onDismiss()
                Task { @MainActor in
                    try? await Task.sleep(for: Timing.paletteHandoff)
                    CommandActions.newFromTemplate()
                }
            } label: {
                Label("New from Template…", systemImage: "doc.badge.plus")
            }
            Divider()
            if session.recentlyClosed.isEmpty {
                Text("No Recently Closed Tabs")
            } else {
                Section("Recently Closed") {
                    ForEach(session.recentlyClosed) { record in
                        Button {
                            CommandActions.reopenClosedTab(record)
                            onDismiss()
                        } label: {
                            Label(record.displayName, systemImage: record.fileURL == nil ? "doc.text" : "doc")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 36, height: 36)
        } primaryAction: {
            // Dismiss the switcher first so the blank editor appears
            // after the switcher animation completes.
            AppStateBus.shared.scenes.claimFocus(session: session)
            onDismiss()
            Task { @MainActor in
                try? await Task.sleep(for: Timing.paletteHandoff)
                CommandActions.newTab()
            }
        }
        .menuOrder(.fixed)
        .accessibilityLabel("New Tab")
    }

    private func activate(_ tab: TabModel) {
        session.selectedTabID = tab.id
        onDismiss()
    }

    private func close(_ tab: TabModel) {
        // Dirty close → dismiss the switcher first, then trigger
        // the close on the next runloop so the unsaved-changes
        // dialog can present on the editor underneath. iOS only
        // hosts one modal at a time per scene; firing the dialog
        // while this sheet is up either drops the dialog silently
        // (so the close goes through without a prompt — data loss
        // risk) or wedges the app waiting for a modal it can't
        // present. Clean tabs skip the dismissal so the user can
        // keep killing them in sequence.
        if CommandActions.tabNeedsCloseConfirmation(tab) {
            onDismiss()
            DispatchQueue.main.async {
                CommandActions.requestCloseTab(tab.id, in: session)
            }
        } else {
            CommandActions.requestCloseTab(tab.id, in: session)
        }
    }
}

// MARK: - Card

private struct TabCard: View {

    @Bindable var tab: TabModel
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onPin: () -> Void
    let onCloseOthers: () -> Void
    let onCloseRight: () -> Void

    /// Horizontal drag offset, used for the swipe-to-close gesture.
    @State private var dragOffset: CGFloat = 0
    /// Width the card must travel left of centre before a release
    /// commits the close. Less than this springs back.
    private let swipeCommit: CGFloat = 80

    var body: some View {
        cardChrome
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .offset(x: dragOffset)
            .opacity(1 - min(1, abs(dragOffset) / 240))
            .contentShape(.rect)
            .onTapGesture { onSelect() }
            .gesture(swipeGesture)
            .contextMenu { contextMenu }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var cardChrome: some View {
        VStack(spacing: 0) {
            thumbnail
            footer
        }
        .background(cardBackground)
        .overlay(cardBorder)
        .overlay(alignment: .topLeading) { closeOverlay }
        .overlay(alignment: .topTrailing) { pinOverlay }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isActive ? Color.accentColor : .clear, lineWidth: 2)
    }

    @ViewBuilder
    private var closeOverlay: some View {
        if canClose {
            closeButton.padding(6)
        }
    }

    @ViewBuilder
    private var pinOverlay: some View {
        if tab.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tint)
                .padding(8)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if tab.kind == .launcher {
            launcherThumbnail
        } else if tab.kind == .fileBrowser {
            fileBrowserThumbnail
        } else {
            textThumbnail
        }
    }

    /// Mirrors `NewDocumentLauncherView` at thumbnail scale so the
    /// user immediately recognizes a tab parked on the new-document
    /// surface in the expose grid.
    @ViewBuilder
    private var launcherThumbnail: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 26, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text("New Document")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Templates · Drafts · Open File")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
        .padding(.top, 16)
        .background(Color(.secondarySystemBackground))
        .disabled(true)
    }

    @ViewBuilder
    private var fileBrowserThumbnail: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 26, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text("Open File")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
        .padding(.top, 16)
        .background(Color(.secondarySystemBackground))
        .disabled(true)
    }

    @ViewBuilder
    private var textThumbnail: some View {
        // Plain-text preview: first ~16 lines. Truncated mid-line so
        // long files don't visually dominate. Extra top padding (28pt)
        // keeps the first line clear of the close-button overlay in
        // the top-leading corner.
        let preview = preview(of: tab.document.text)
        ScrollView(.vertical, showsIndicators: false) {
            Text(preview.isEmpty ? "(empty)" : preview)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(preview.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 28)
                .padding(.bottom, 10)
        }
        .frame(height: 160)
        .background(Color(.systemBackground))
        .disabled(true)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: footerIconName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(displayName)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if tab.document.isDirty || tab.document.fileURL == nil {
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.primary)
                .padding(5)
                .background(.thinMaterial, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close \(displayName)")
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            onSelect()
        } label: {
            Label("Switch to Tab", systemImage: "arrow.up.right.square")
        }
        Button {
            onPin()
        } label: {
            Label(tab.isPinned ? "Unpin Tab" : "Pin Tab",
                  systemImage: tab.isPinned ? "pin.slash" : "pin")
        }
        Divider()
        if canClose {
            Button(role: .destructive, action: onClose) {
                Label("Close Tab", systemImage: "xmark")
            }
        }
        Button(role: .destructive, action: onCloseOthers) {
            Label("Close Other Tabs", systemImage: "rectangle.stack.badge.minus")
        }
        Button(role: .destructive, action: onCloseRight) {
            Label("Close Tabs to the Right", systemImage: "rectangle.righthalf.inset.filled.arrow.right")
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // Only honour leftward swipes; rightward stays put.
                dragOffset = min(0, value.translation.width)
            }
            .onEnded { value in
                if canClose, value.translation.width < -swipeCommit {
                    withAnimation(.appSwitcherCard) {
                        dragOffset = -400
                    }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(180))
                        onClose()
                    }
                } else {
                    withAnimation(.appSwitcherCard) {
                        dragOffset = 0
                    }
                }
            }
    }

    private var displayName: String {
        switch tab.kind {
        case .launcher:   return "New"
        case .fileBrowser: return "New Tab"
        case .editor:     return tab.document.displayName
        }
    }

    private var footerIconName: String {
        switch tab.kind {
        case .launcher:   return "doc.badge.plus"
        case .fileBrowser: return "folder.fill"
        case .editor:     return tab.document.fileURL == nil ? "doc.text" : "doc"
        }
    }

    private var accessibilityLabel: String {
        let pinned = tab.isPinned ? "Pinned. " : ""
        let dirty = (tab.document.isDirty || tab.document.fileURL == nil) ? "Unsaved. " : ""
        return "\(pinned)\(dirty)\(displayName)"
    }

    private func preview(of text: String) -> String {
        // Cap to 16 lines × 60 chars so very large files don't blow
        // up layout. SwiftUI text rendering of 100k+ chars is slow.
        var lines: [Substring] = []
        var iterator = text.split(separator: "\n", maxSplits: 16, omittingEmptySubsequences: false).makeIterator()
        while lines.count < 16, let next = iterator.next() {
            lines.append(next.prefix(60))
        }
        return lines.joined(separator: "\n")
    }
}
