import Foundation

/// Per-window tab collection.
@MainActor
@Observable
final class EditorSession {
    let pickers = PickerIntents()

    var tabs: [TabModel]
    var selectedTabID: UUID
    var recentlyClosed: [ClosedTabRecord] { ClosedTabsStore.shared.records }
    /// Links the session to its hosting scene.
    var sceneUUID: String = ""
    /// Suppresses persistence while explicitly closing the window.
    var isClosingWindow = false
    var tabSwitcherActive: Bool = false
    /// The owning scene reviews unsaved documents for every close surface.
    @ObservationIgnored var requestClose: ((CloseTarget) -> Void)?
    /// Explicitly save every changed document, using this window's file picker.
    @ObservationIgnored var requestSaveAllAndCloseWindow: (() -> Void)?

    enum CloseTarget {
        case window
        case tabs([UUID])
    }

    /// Window closure includes inactive and pinned tabs, unlike Close All Tabs.
    var unsavedDocumentCount: Int {
        tabs.count(where: \.needsCloseConfirmation)
    }

    /// Save the selected documents before closing. The reviewed set prevents
    /// closing newly dirty tabs that were never presented for a decision.
    /// No tabs are discarded here. Cancellation or failure keeps them all open,
    /// without rolling back files already saved through this window's picker.
    func saveDocumentsBeforeClosing(
        tabIDs: [UUID]? = nil,
        discarding: Set<UUID> = [],
        reviewed: Set<UUID>? = nil,
        saveUntitled: (TabModel) async throws -> Bool
    ) async throws -> Bool {
        let candidates = tabIDs.map { ids in tabs.filter { ids.contains($0.id) } } ?? tabs
        let dirty = candidates.filter(\.needsCloseConfirmation)
        if let reviewed, !dirty.allSatisfy({ reviewed.contains($0.id) }) {
            throw WindowSaveError.changedDuringSave
        }
        let pending = dirty.filter { !discarding.contains($0.id) }
        for tab in pending {
            try Task.checkCancellation()
            guard tabs.contains(where: { $0 === tab }) else { return false }
            selectedTabID = tab.id
            tabSwitcherActive = false
            if tab.document.fileURL == nil {
                guard try await saveUntitled(tab) else { return false }
            } else {
                try await DocumentWorkflow.save(tab)
            }
            try Task.checkCancellation()
            guard tabs.contains(where: { $0 === tab }) else { return false }
        }
        let remaining = tabIDs == nil ? tabs : candidates
        guard !remaining.contains(where: { $0.needsCloseConfirmation && !discarding.contains($0.id) }) else {
            throw WindowSaveError.changedDuringSave
        }
        return true
    }

    enum WindowSaveError: LocalizedError {
        case changedDuringSave
        var errorDescription: String? {
            "Some tabs still have unsaved changes. They have been kept open."
        }
    }

    init() {
        let initial = TabModel(kind: AppPreferencesStore.shared.newWindowContent.tabKind)
        self.tabs = [initial]
        self.selectedTabID = initial.id
    }

    /// Repairs a stale selection; an empty tab list violates the session invariant.
    var activeTab: TabModel {
        if let tab = tabs.first(where: { $0.id == selectedTabID }) { return tab }
        assertionFailure("selectedTabID \(selectedTabID) not in tabs — session is out of sync")
        guard let first = tabs.first else {
            preconditionFailure("EditorSession invariant violated: tabs is empty")
        }
        selectedTabID = first.id
        return first
    }

    @discardableResult
    func newTab(kind: TabKind = AppPreferencesStore.shared.newTabContent.tabKind) -> TabModel {
        let tab = TabModel(kind: kind)
        let insertAt = newUnpinnedTabInsertionIndex()
        tabs.insert(tab, at: insertAt)
        selectedTabID = tab.id
        tabSwitcherActive = false
        return tab
    }

    private func newUnpinnedTabInsertionIndex() -> Int {
        guard let selectedIndex = tabs.firstIndex(where: {
            $0.id == selectedTabID
        }) else {
            return tabs.count
        }
        if tabs[selectedIndex].isPinned {
            return tabs.partitionPointAfterPinned()
        }
        return min(selectedIndex + 1, tabs.count)
    }

    /// "Open in New Tab" entry point. The pick callback flips kind
    /// back to `.editor` and loads the chosen URL into the same tab.
    @discardableResult
    func newFileBrowserTab() -> TabModel {
        newTab(kind: .fileBrowser)
    }

    /// `.discard` is required from the unsaved-changes dialog's
    /// Discard path so a deliberately-thrown-away buffer can't be
    /// resurrected by ⇧⌘T.
    enum CloseDisposition {
        case archive
        case discard
    }

    /// When the last tab closes, return to the window's start screen. To
    /// destroy the window outright, use ⌘⇧W from the menu.
    @discardableResult
    func closeTab(_ id: UUID, disposition: CloseDisposition = .archive) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let tab = tabs[idx]
        if disposition == .archive {
            recordClosure(of: tab)
        }
        // Detached tabs keep their work; closed tabs must not publish a
        // late load or recreate a recovery shadow after Discard.
        tab.state.loadTask?.cancel()
        tab.state.loadTask = nil
        tab.state.loadGeneration &+= 1
        tab.state.transformTask?.cancel()
        tab.secondaryState?.transformTask?.cancel()
        tab.state.autoSaveTask?.cancel()
        tab.state.autoSaveTask = nil
        tab.state.liveSpellTask?.cancel()
        tab.state.liveSpellTask = nil
        if disposition == .discard { tab.document.deleteScratchFile() }
        let wasActive = (selectedTabID == id)
        tabs.remove(at: idx)
        if tabs.isEmpty {
            let fresh = TabModel(kind: .launcher)
            tabs.append(fresh)
            selectedTabID = fresh.id
            tabSwitcherActive = false
        } else if wasActive {
            selectedTabID = tabs[max(0, idx - 1)].id
        }
        persistRestorationRecord()
        return true
    }

    /// Store window membership independently of lifecycle notifications, which
    /// may never arrive after a crash. Loading tabs retain the preceding record
    /// until all of their source/recovery reads have finished.
    func persistRestorationRecord() {
        guard !sceneUUID.isEmpty, !isClosingWindow,
              !tabs.contains(where: { $0.document.isLoading }) else { return }
        let record = SessionRecord(scene: sceneUUID, session: self)
        if record.tabs.isEmpty {
            SessionsStore.shared.remove(forScene: sceneUUID)
        } else {
            SessionsStore.shared.save(record)
        }
    }

    /// Lifecycle checkpoints belong to this window. Recheck membership after
    /// each asynchronous write: a close/discard can run while I/O is suspended.
    func checkpointDocuments() async throws {
        try await DraftsStore.shared.withCapEnforcementSuspended {
            for tab in tabs where tab.document.isDirty {
                guard !isClosingWindow else { return }
                guard tabs.contains(where: { $0 === tab }) else { continue }
                if let live = tab.state.textView?.text { tab.document.text = live }
                try await tab.document.commitRecoverySnapshot()
            }
        }
    }

    /// The close decision is explicit. Stop publishers before invalidating
    /// recovery writes so a queued checkpoint cannot resurrect discarded text.
    func prepareForWindowClose(discardChanges: Bool) -> Bool {
        guard !isClosingWindow else { return false }
        for tab in tabs {
            tab.state.textView?.resignFirstResponder()
            tab.secondaryState?.textView?.resignFirstResponder()
        }
        guard discardChanges || unsavedDocumentCount == 0 else { return false }
        isClosingWindow = true
        SessionsStore.shared.remove(forScene: sceneUUID)
        for tab in tabs {
            tab.state.loadTask?.cancel()
            tab.state.loadTask = nil
            tab.state.loadGeneration &+= 1
            tab.document.isLoading = false
            tab.state.transformTask?.cancel()
            tab.secondaryState?.transformTask?.cancel()
            tab.state.autoSaveTask?.cancel()
            tab.state.autoSaveTask = nil
            tab.state.liveSpellTask?.cancel()
            tab.state.liveSpellTask = nil
            if tab.document.fileURL != nil, !tab.needsCloseConfirmation {
                ClosedTabsStore.shared.record(Self.snapshotRecord(of: tab))
            }
            tab.document.deleteScratchFile()
        }
        return true
    }

    func selectNextTab() {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = tabs[(idx + 1) % tabs.count].id
    }

    func selectPreviousTab() {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = tabs[(idx - 1 + tabs.count) % tabs.count].id
    }

    /// ⌘9 jumps to the last tab regardless of count.
    func selectTab(at position: Int) {
        guard !tabs.isEmpty else { return }
        let idx = (position == 9) ? tabs.count - 1 : min(max(position - 1, 0), tabs.count - 1)
        selectedTabID = tabs[idx].id
    }

    /// Pinning re-homes the tab so the `[pinned…, unpinned…]`
    /// partition invariant stays intact.
    func togglePinned(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        tab.isPinned.toggle()
        tabs.remove(at: idx)
        tabs.insert(tab, at: tabs.partitionPointAfterPinned())
    }

    /// Drag-and-drop reorder. Clamps so a pinned tab can't cross
    /// into the unpinned region (or vice versa) — partition stays
    /// intact.
    func moveTab(id: UUID, to destination: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[from]
        let pinnedCount = tabs.partitionPointAfterPinned()
        // Pinned: [0, pinnedCount-1]. Unpinned: [pinnedCount, count-1].
        let lowerBound = tab.isPinned ? 0 : pinnedCount
        let upperBound = tab.isPinned ? max(0, pinnedCount - 1) : max(0, tabs.count - 1)
        let clamped = min(max(destination, lowerBound), upperBound)
        guard clamped != from else { return }
        tabs.remove(at: from)
        tabs.insert(tab, at: min(clamped, tabs.count))
    }

    /// Shared by the strip and overview. A cross-window move transfers
    /// the existing buffer and undo history instead of opening a copy.
    func acceptTabDrop(_ items: [String], onto targetID: UUID? = nil) -> Bool {
        guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
        let destination: Int
        if let targetID {
            guard let index = tabs.firstIndex(where: { $0.id == targetID }) else { return false }
            destination = index
        } else {
            destination = tabs.count
        }
        if !tabs.contains(where: { $0.id == id }) {
            guard let source = AppStateBus.shared.scenes.session(containing: id),
                  let tab = source.detachTab(id) else { return false }
            attachTab(tab)
        }
        moveTab(id: id, to: destination)
        return true
    }

    func popRecentlyClosed() -> ClosedTabRecord? {
        ClosedTabsStore.shared.popFirst()
    }

    /// Appends a tab without claiming focus — placeholder for an
    /// eventual "Open in Background" gesture.
    func insertTab(_ tab: TabModel, activate: Bool = true) {
        let insertAt = tabs.partitionPointAfterPinned()
        tabs.insert(tab, at: insertAt)
        if activate { selectedTabID = tab.id }
    }

    /// Hands the tab back so the caller can re-home it (cross-window
    /// drag, new window). Returns nil if removing would violate the
    /// ≥ 1 tab invariant.
    func detachTab(_ id: UUID) -> TabModel? {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: idx)
        if selectedTabID == id {
            selectedTabID = tabs[max(0, idx - 1)].id
        }
        return tab
    }

    /// Adopt a detached tab. `id` is preserved so subsequent drags
    /// resolve through `session(containing:)`.
    func attachTab(_ tab: TabModel) {
        insertTab(tab)
    }

    private func recordClosure(of tab: TabModel) {
        ClosedTabsStore.shared.record(Self.snapshotRecord(of: tab))
    }

    /// Shared by the scene-close path, which snapshots every still-
    /// open tab when the window goes away.
    static func snapshotRecord(of tab: TabModel) -> ClosedTabRecord {
        // `document.text` lags the engine by ~300 ms — pull the
        // live buffer when the engine view is still around, or a
        // close inside the debounce window archives pre-edit text.
        let liveText = tab.state.textView?.text ?? tab.document.text
        let shouldSnapshot: Bool
        if tab.document.fileURL == nil {
            shouldSnapshot = !liveText.isEmpty
        } else {
            // Clean file-backed tabs need only a bookmark. Dirty files,
            // including an intentional empty buffer, need exact contents.
            shouldSnapshot = tab.document.isDirty
        }
        return ClosedTabRecord(
            displayName: tab.document.displayName,
            fileURL: tab.document.fileURL,
            unsavedSnapshot: shouldSnapshot ? liveText : nil,
            draftFilename: tab.document.draftURL?.lastPathComponent
        )
    }
}

private extension Array where Element == TabModel {
    /// Insertion point that keeps `[pinned…, unpinned…]` partitioned.
    @MainActor
    func partitionPointAfterPinned() -> Int {
        firstIndex(where: { !$0.isPinned }) ?? count
    }
}
