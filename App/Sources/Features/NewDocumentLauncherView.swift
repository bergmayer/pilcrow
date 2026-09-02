import SwiftUI
import UIKit

/// Legacy document-shell launcher retained for already-restored launcher
/// tabs. Ordinary New actions now open a blank editor; templates and
/// recovery live in their explicit picker and file-browser surfaces.
struct NewDocumentLauncherView: View {

    let onPickTemplate: (TemplateRecord) -> Void
    let onPickDraft: (DraftRecord) -> Void
    let onRestoreClosedWindow: (ClosedWindowRecord) -> Void
    let onPickOpenFile: () -> Void
    /// Seeds a fresh editor tab with the system pasteboard contents.
    /// Disabled when the pasteboard has no string payload.
    let onPickClipboard: (String) -> Void
    /// `true` when this launcher is the only tab in the window —
    /// drives the header copy ("New Window" vs "New Tab"). The
    /// distinction is purely cosmetic: the surface and the picks
    /// behave identically either way.
    let isWindowScopeLauncher: Bool
    /// Closes this launcher surface without picking anything. The
    /// scene routes it to the same close path as ⌘W — if this is
    /// the only tab the window stays open with another launcher
    /// taking its place.
    let onCancel: () -> Void
    /// `false` when this launcher is filling the window's empty
    /// state (no real tabs left) — there's nothing meaningful to
    /// cancel back to, so the Cancel chip is hidden.
    let showsCancel: Bool

    /// Refreshed on each appear — the user may have deleted a draft
    /// in another window or saved one out of the recovery pool.
    @State private var templates: [TemplateRecord] = []
    @State private var drafts: [DraftRecord] = []
    @Bindable private var closedWindows = ClosedWindowsStore.shared
    @State private var pendingRecoveryDiscard: RecoveryDiscardTarget?
    /// Snapshot of `UIPasteboard.general.hasStrings` at refresh time
    /// so the "From Clipboard" row can disable itself when there's
    /// nothing to paste.
    @State private var hasClipboardText: Bool = false

    var body: some View {
        // Outer wash sets the chrome backdrop; the actual launcher
        // floats as a centered card with its own padding so the
        // surface feels contained within the tab rather than
        // taking over the whole pane.
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                recoverySection
                openExistingSection
                templatesSection
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear(perform: refresh)
        .onChange(of: closedWindows.records.map(\.id)) { _, _ in
            refreshRecovery()
        }
        .alert(
            "Discard recovered work?",
            isPresented: Binding(
                get: { pendingRecoveryDiscard != nil },
                set: { if !$0 { pendingRecoveryDiscard = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingRecoveryDiscard = nil
            }
            Button("Discard", role: .destructive) {
                discardPendingRecovery()
            }
        } message: {
            Text(discardMessage)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isWindowScopeLauncher ? "New Window" : "New Tab")
                    .font(.title2.weight(.semibold))
                Text("Recover recent work, pick a template, or open an existing file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if showsCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Recoverable work

    private var recoveryCatalog: RecoverableWorkCatalog {
        RecoverableWorkCatalog(
            drafts: drafts,
            closedWindows: closedWindows.records,
            excludedDraftFilenames: openDraftFilenames
        )
    }

    private var openDraftFilenames: Set<String> {
        Set(AppStateBus.shared.scenes.allOpenSessions.flatMap { session in
            session.tabs.flatMap(\.document.liveRecoveryFilenames)
        })
    }

    @ViewBuilder
    private var recoverySection: some View {
        sectionHeader("Recoverable Work", systemImage: "tray.full")
        if recoveryCatalog.isEmpty {
            emptyCard(
                "Nothing to recover",
                detail: "Windows and documents closed with unsaved changes will appear here."
            )
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(recoveryCatalog.windows) { record in
                    closedWindowCard(record)
                }
                if !recoveryCatalog.drafts.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(recoveryCatalog.drafts.enumerated()), id: \.element.id) { index, item in
                            draftRow(item)
                            if index < recoveryCatalog.drafts.count - 1 {
                                Divider().padding(.leading, 54)
                            }
                        }
                    }
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    @ViewBuilder
    private func closedWindowCard(_ record: ClosedWindowRecord) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack.badge.clock")
                    .font(.system(size: 20))
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue Closed Window")
                        .font(.body.weight(.medium))
                    HStack(spacing: 4) {
                        Text(windowSummary(for: record))
                        Text("·")
                        Text(record.closedAt, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Restore") {
                    onRestoreClosedWindow(record)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    pendingRecoveryDiscard = .window(record)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Discard recovered window")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().padding(.leading, 54)

            ForEach(Array(record.tabs.enumerated()), id: \.offset) { index, snapshot in
                recoveredTabRow(
                    snapshot,
                    isActive: index == record.activeIndex
                )
                if index < record.tabs.count - 1 {
                    Divider().padding(.leading, 54)
                }
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func recoveredTabRow(_ snapshot: TabSnapshot, isActive: Bool) -> some View {
        let draft = snapshot.draftFilename.flatMap {
            recoveryCatalog.draftsByFilename[$0]
        }
        HStack(spacing: 12) {
            Image(systemName: tabSymbol(for: snapshot, draft: draft))
                .font(.system(size: 16))
                .foregroundStyle(
                    draft == nil
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(.tint)
                )
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(tabTitle(for: snapshot, draft: draft))
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(tabDetail(for: snapshot, draft: draft))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if snapshot.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
            if isActive {
                Text("Active")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func windowSummary(for record: ClosedWindowRecord) -> String {
        let tabs = record.tabCount == 1 ? "1 tab" : "\(record.tabCount) tabs"
        let changed = record.dirtyTabCount == 1
            ? "1 with unsaved changes"
            : "\(record.dirtyTabCount) with unsaved changes"
        return "\(tabs) · \(changed)"
    }

    private func tabTitle(for snapshot: TabSnapshot, draft: DraftRecord?) -> String {
        if let display = draft?.metadata?.sourceDisplay {
            return display
        }
        if let displayName = snapshot.displayName, !displayName.isEmpty {
            return displayName
        }
        if let bookmark = snapshot.fileBookmark,
           let url = resolveBookmark(bookmark) {
            return url.lastPathComponent
        }
        return draft == nil ? "Saved Document" : "Untitled"
    }

    private func tabDetail(for snapshot: TabSnapshot, draft: DraftRecord?) -> String {
        guard let draft else { return "Saved" }
        let status = draft.metadata?.sourceDisplay != nil || snapshot.fileBookmark != nil
            ? "Edited"
            : "Unsaved draft"
        let preview = draft.preview.isEmpty ? "(empty buffer)" : draft.preview
        return "\(status) · \(preview)"
    }

    private func tabSymbol(for snapshot: TabSnapshot, draft: DraftRecord?) -> String {
        if draft == nil { return "doc" }
        return draft?.metadata?.sourceDisplay != nil || snapshot.fileBookmark != nil
            ? "doc.badge.clock"
            : "doc.badge.plus"
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    private func refresh() {
        templates = TemplatesStore.shared.loadAll()
        hasClipboardText = UIPasteboard.general.hasStrings
        refreshRecovery()
    }

    private func refreshRecovery() {
        let loaded = DraftsStore.shared.loadAll()
        let catalog = RecoverableWorkCatalog(
            drafts: loaded,
            closedWindows: closedWindows.records,
            excludedDraftFilenames: openDraftFilenames
        )
        closedWindows.pruneInvalidRecords(catalog.invalidWindowIDs)
        drafts = loaded
    }

    // MARK: Templates

    @ViewBuilder
    private var templatesSection: some View {
        sectionHeader("Templates", systemImage: "doc.badge.plus")
        if templates.isEmpty {
            emptyCard(
                "No templates yet",
                detail: "Drop files into the Documents/Templates folder via Files.app to add your own."
            )
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110), spacing: 8)],
                spacing: 8
            ) {
                ForEach(templates) { template in
                    Button {
                        onPickTemplate(template)
                    } label: {
                        templateCard(template)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func templateCard(_ template: TemplateRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: template.symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(template.displayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(template.url.lastPathComponent)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
    }

    @ViewBuilder
    private func draftRow(_ item: RecoverableDraftItem) -> some View {
        let draft = item.draft
        HStack(spacing: 12) {
            Button {
                if let window = item.closedWindow {
                    onRestoreClosedWindow(window)
                } else {
                    onPickDraft(draft)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: draft.metadata?.sourceDisplay == nil
                          ? "doc.badge.plus"
                          : "doc.badge.clock")
                        .font(.system(size: 20))
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draftTitle(for: item))
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(draft.preview.isEmpty ? "(empty buffer)" : draft.preview)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(draftMetadataLine(for: draft))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button {
                pendingRecoveryDiscard = .draft(item)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard recovered document")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func draftTitle(for item: RecoverableDraftItem) -> String {
        if let display = item.draft.metadata?.sourceDisplay {
            return display
        }
        if let displayName = item.closedWindow?.tabs.first?.displayName,
           !displayName.isEmpty {
            return displayName
        }
        let when = item.draft.modified.formatted(
            date: .abbreviated,
            time: .shortened
        )
        return "Untitled — \(when)"
    }

    private func draftMetadataLine(for draft: DraftRecord) -> String {
        let size = draft.bytes.formatted(.byteCount(style: .file))
        let when = draft.modified.formatted(date: .abbreviated, time: .shortened)
        let status = draft.metadata?.sourceDisplay == nil
            ? "Unsaved draft"
            : "Unsaved changes"
        return "\(status) · \(size) · \(when)"
    }

    private var discardMessage: String {
        switch pendingRecoveryDiscard {
        case .some(.window):
            return "This permanently removes the recovered unsaved changes for this window. Original saved files are not deleted."
        case .some(.draft(let item)):
            if item.draft.metadata?.sourceDisplay != nil {
                return "This permanently removes the recovered edits. The original saved file is not deleted."
            }
            return "This permanently removes this unsaved document."
        case .none:
            return "This permanently removes the selected recovery data."
        }
    }

    private func discardPendingRecovery() {
        guard let pendingRecoveryDiscard else { return }
        switch pendingRecoveryDiscard {
        case .window(let record):
            closedWindows.discard(record.id)
            let filenames = record.draftFilenames
            drafts.removeAll { filenames.contains($0.recoveryFilename) }
        case .draft(let item):
            if let window = item.closedWindow {
                closedWindows.discard(window.id)
            } else {
                DraftsStore.shared.discard(item.draft)
            }
            drafts.removeAll {
                $0.recoveryFilename == item.draft.recoveryFilename
            }
        }
        self.pendingRecoveryDiscard = nil
    }

    // MARK: Open existing

    @ViewBuilder
    private var openExistingSection: some View {
        VStack(spacing: 0) {
            openFileRow
            Divider().padding(.leading, 54)
            clipboardRow
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var openFileRow: some View {
        Button(action: onPickOpenFile) {
            actionRow(
                symbol: "folder",
                title: "Open File…",
                detail: "Browse the Files app for an existing document.",
                enabled: true
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var clipboardRow: some View {
        Button {
            // Read live at tap time — `hasClipboardText` only gates
            // the row's enabled state; the actual bytes may differ
            // if another app copied something between refresh and
            // the user's tap.
            guard let text = UIPasteboard.general.string,
                  !text.isEmpty else { return }
            onPickClipboard(text)
        } label: {
            actionRow(
                symbol: "doc.on.clipboard",
                title: "From Clipboard",
                detail: hasClipboardText
                    ? "Start a tab seeded with the current clipboard text."
                    : "Copy text in any app, then come back here.",
                enabled: hasClipboardText
            )
        }
        .buttonStyle(.plain)
        .disabled(!hasClipboardText)
    }

    @ViewBuilder
    private func actionRow(symbol: String, title: String, detail: String, enabled: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(enabled ? .primary : .secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    // MARK: Shared chrome

    @ViewBuilder
    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    @ViewBuilder
    private func emptyCard(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private enum RecoveryDiscardTarget {
    case window(ClosedWindowRecord)
    case draft(RecoverableDraftItem)
}
