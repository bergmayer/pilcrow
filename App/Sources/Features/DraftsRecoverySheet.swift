import SwiftUI

/// A second entry point to the same normalized recovery catalog used by the
/// new-tab launcher. A recovery payload is presented exactly once: grouped
/// under a multi-tab window or as one document row.
struct DraftsRecoverySheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [DraftRecord] = []
    @State private var confirmingDeleteAll = false
    @State private var pendingDiscard: SheetRecoveryDiscard?
    @Bindable private var closedWindows = ClosedWindowsStore.shared

    private var catalog: RecoverableWorkCatalog {
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

    private var recoveryCount: Int {
        catalog.windows.count + catalog.drafts.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if catalog.isEmpty {
                    ContentUnavailableView(
                        "Nothing to recover",
                        systemImage: "tray.full",
                        description: Text(
                            "Windows and documents closed with unsaved changes will appear here."
                        )
                    )
                } else {
                    List {
                        if !catalog.windows.isEmpty {
                            Section("Closed Windows") {
                                ForEach(catalog.windows) { record in
                                    closedWindowRow(record)
                                }
                            }
                        }
                        if !catalog.drafts.isEmpty {
                            Section("Documents") {
                                ForEach(catalog.drafts) { item in
                                    draftRow(item)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Recoverable Work")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep") { dismiss() }
                }
                if !catalog.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Restore All") { restoreAll() }
                    }
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete All", role: .destructive) {
                            confirmingDeleteAll = true
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete all \(recoveryCount) recovery item\(recoveryCount == 1 ? "" : "s")?",
                isPresented: $confirmingDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    discardAll()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Recovered unsaved changes cannot be restored after deletion. Original saved files are not deleted.")
            }
            .alert(
                "Discard recovered work?",
                isPresented: Binding(
                    get: { pendingDiscard != nil },
                    set: { if !$0 { pendingDiscard = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    pendingDiscard = nil
                }
                Button("Discard", role: .destructive) {
                    discardPending()
                }
            } message: {
                Text(discardMessage)
            }
            .onAppear(perform: refresh)
            .onChange(of: closedWindows.records.map(\.id)) { _, _ in
                refresh()
            }
        }
    }

    @ViewBuilder
    private func closedWindowRow(_ record: ClosedWindowRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue Closed Window")
                        .font(.body.weight(.medium))
                    HStack(spacing: 4) {
                        Text(windowSummary(record))
                        Text("·")
                        Text(record.closedAt, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Restore") {
                    restore(record)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    pendingDiscard = .window(record)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Discard recovered window")
            }

            ForEach(Array(record.tabs.enumerated()), id: \.offset) { index, snapshot in
                let draft = snapshot.draftFilename.flatMap {
                    catalog.draftsByFilename[$0]
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: draft == nil ? "doc" : "doc.badge.clock")
                        .foregroundStyle(
                            draft == nil
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(.tint)
                        )
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tabTitle(snapshot, draft: draft))
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(tabDetail(snapshot, draft: draft))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if snapshot.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if index == record.activeIndex {
                        Text("Active")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func draftRow(_ item: RecoverableDraftItem) -> some View {
        HStack(spacing: 10) {
            Button {
                restore(item)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: item.draft.metadata?.sourceDisplay == nil
                          ? "doc.badge.plus"
                          : "doc.badge.clock")
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(draftTitle(item))
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(item.draft.preview.isEmpty
                             ? "(empty buffer)"
                             : item.draft.preview)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(draftMetadata(item.draft))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button {
                pendingDiscard = .draft(item)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Discard recovered document")
        }
        .swipeActions {
            Button("Discard", role: .destructive) {
                pendingDiscard = .draft(item)
            }
        }
    }

    private func refresh() {
        let loaded = DraftsStore.shared.loadAll()
        let normalized = RecoverableWorkCatalog(
            drafts: loaded,
            closedWindows: closedWindows.records,
            excludedDraftFilenames: openDraftFilenames
        )
        closedWindows.pruneInvalidRecords(normalized.invalidWindowIDs)
        drafts = loaded
    }

    private func restore(_ record: ClosedWindowRecord) {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: Timing.paletteHandoff)
            CommandActions.recoverClosedWindow(record)
        }
    }

    private func restore(_ item: RecoverableDraftItem) {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: Timing.paletteHandoff)
            if let record = item.closedWindow {
                CommandActions.recoverClosedWindow(record)
            } else {
                CommandActions.recoverDraft(item.draft)
            }
        }
    }

    private func restoreAll() {
        let snapshot = catalog
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: Timing.paletteHandoff)
            for record in snapshot.windows {
                CommandActions.recoverClosedWindow(record)
            }
            for item in snapshot.drafts {
                if let record = item.closedWindow {
                    CommandActions.recoverClosedWindow(record)
                } else {
                    CommandActions.recoverDraft(item.draft)
                }
            }
        }
    }

    private func discardPending() {
        guard let pendingDiscard else { return }
        switch pendingDiscard {
        case .window(let record):
            discard(record)
        case .draft(let item):
            discard(item)
        }
        self.pendingDiscard = nil
        if catalog.isEmpty { dismiss() }
    }

    private func discard(_ record: ClosedWindowRecord) {
        closedWindows.discard(record.id)
        let filenames = record.draftFilenames
        drafts.removeAll { filenames.contains($0.recoveryFilename) }
    }

    private func discard(_ item: RecoverableDraftItem) {
        if let record = item.closedWindow {
            closedWindows.discard(record.id)
        } else {
            DraftsStore.shared.discard(item.draft)
        }
        drafts.removeAll {
            $0.recoveryFilename == item.draft.recoveryFilename
        }
    }

    private func discardAll() {
        let snapshot = catalog
        var discardedWindowIDs = Set<UUID>()
        for record in snapshot.windows {
            closedWindows.discard(record.id)
            discardedWindowIDs.insert(record.id)
        }
        for item in snapshot.drafts {
            if let record = item.closedWindow {
                if discardedWindowIDs.insert(record.id).inserted {
                    closedWindows.discard(record.id)
                }
            } else {
                DraftsStore.shared.discard(item.draft)
            }
        }
        drafts.removeAll()
        dismiss()
    }

    private var discardMessage: String {
        switch pendingDiscard {
        case .some(.window):
            return "This permanently removes the recovered unsaved changes for this window. Original saved files are not deleted."
        case .some(.draft(let item)):
            return item.draft.metadata?.sourceDisplay == nil
                ? "This permanently removes this unsaved document."
                : "This permanently removes the recovered edits. The original saved file is not deleted."
        case .none:
            return "This permanently removes the selected recovery data."
        }
    }

    private func windowSummary(_ record: ClosedWindowRecord) -> String {
        let tabs = record.tabCount == 1 ? "1 tab" : "\(record.tabCount) tabs"
        let changed = record.dirtyTabCount == 1
            ? "1 with unsaved changes"
            : "\(record.dirtyTabCount) with unsaved changes"
        return "\(tabs) · \(changed)"
    }

    private func tabTitle(_ snapshot: TabSnapshot, draft: DraftRecord?) -> String {
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

    private func tabDetail(_ snapshot: TabSnapshot, draft: DraftRecord?) -> String {
        guard let draft else { return "Saved" }
        let status = draft.metadata?.sourceDisplay != nil || snapshot.fileBookmark != nil
            ? "Edited"
            : "Unsaved draft"
        return "\(status) · \(draft.preview.isEmpty ? "(empty buffer)" : draft.preview)"
    }

    private func draftTitle(_ item: RecoverableDraftItem) -> String {
        if let display = item.draft.metadata?.sourceDisplay {
            return display
        }
        if let displayName = item.closedWindow?.tabs.first?.displayName,
           !displayName.isEmpty {
            return displayName
        }
        return "Untitled — \(item.draft.modified.formatted(date: .abbreviated, time: .shortened))"
    }

    private func draftMetadata(_ draft: DraftRecord) -> String {
        let status = draft.metadata?.sourceDisplay == nil
            ? "Unsaved draft"
            : "Unsaved changes"
        let size = draft.bytes.formatted(.byteCount(style: .file))
        let when = draft.modified.formatted(date: .abbreviated, time: .shortened)
        return "\(status) · \(size) · \(when)"
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
}

private enum SheetRecoveryDiscard {
    case window(ClosedWindowRecord)
    case draft(RecoverableDraftItem)
}
