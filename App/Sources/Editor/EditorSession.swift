import Foundation

/// Per-window tab collection.
@MainActor
@Observable
final class EditorSession {
    var tabs: [TabModel]
    var selectedTabID: UUID
    var recentlyClosed: [ClosedTabRecord] { ClosedTabsStore.shared.records }
    /// Links the session to its hosting scene.
    var sceneUUID: String = ""
    /// Suppresses persistence while explicitly closing the window.
    var isClosingWindow = false
    var tabSwitcherActive: Bool = false

    init() {
        let initial = TabModel()
        initial.kind = .editor
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
    func newTab(kind: TabKind = .editor) -> TabModel {
        let tab = TabModel()
        tab.kind = kind
        let insertAt = newUnpinnedTabInsertionIndex()
        tabs.insert(tab, at: insertAt)
        selectedTabID = tab.id
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

    /// Always succeeds. When the last tab closes, a fresh blank editor
    /// takes its place so the window keeps a renderable surface. To
    /// destroy the window outright, use ⌘⇧W from the menu.
    @discardableResult
    func closeTab(_ id: UUID, disposition: CloseDisposition = .archive) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let tab = tabs[idx]
        if disposition == .archive {
            recordClosure(of: tab)
        }
        let wasActive = (selectedTabID == id)
        tabs.remove(at: idx)
        if tabs.isEmpty {
            let fresh = TabModel()
            fresh.kind = .editor
            tabs.append(fresh)
            selectedTabID = fresh.id
        } else if wasActive {
            selectedTabID = tabs[max(0, idx - 1)].id
        }
        return true
    }

    /// Keeps pinned tabs — Safari semantics. Selection snaps to the
    /// pivot. Returns count of tabs closed.
    @discardableResult
    func closeOtherTabs(except id: UUID) -> Int {
        let victims = tabs.filter { $0.id != id && !$0.isPinned }
        guard !victims.isEmpty else { return 0 }
        let victimIDs = Set(victims.map(\.id))
        for tab in victims { recordClosure(of: tab) }
        tabs.removeAll { victimIDs.contains($0.id) }
        selectedTabID = id
        return victims.count
    }

    /// Pinned tabs are exempt. Selection snaps to the pivot.
    @discardableResult
    func closeTabsToRight(of id: UUID) -> Int {
        guard let pivot = tabs.firstIndex(where: { $0.id == id }) else { return 0 }
        let victims = tabs[(pivot + 1)...].filter { !$0.isPinned }
        guard !victims.isEmpty else { return 0 }
        let victimIDs = Set(victims.map(\.id))
        for tab in victims { recordClosure(of: tab) }
        tabs.removeAll { victimIDs.contains($0.id) }
        selectedTabID = id
        return victims.count
    }

    func selectNextTab() {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = tabs[(idx + 1) % tabs.count].id
    }

    func selectPreviousTab() {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = tabs[(idx - 1 + tabs.count) % tabs.count].id
    }

    /// Safari quirk: ⌘9 jumps to the last tab regardless of count.
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
        if tab.isPinned {
            // Append to end of the pinned block.
            tabs.insert(tab, at: tabs.partitionPointAfterPinned())
        } else {
            // Drop at the front of the unpinned block.
            tabs.insert(tab, at: tabs.partitionPointAfterPinned())
        }
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
        let insertAt = tabs.partitionPointAfterPinned()
        tabs.insert(tab, at: insertAt)
        selectedTabID = tab.id
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
