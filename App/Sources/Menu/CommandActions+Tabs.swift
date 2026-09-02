import Foundation
import UIKit
import FileEncoding

extension CommandActions {

    // MARK: - Move / detach

    /// Detaches the tab and lands it in a fresh editor scene via
    /// `pending.adoptedTab`. `toNewWindow:` is the only mode today;
    /// the parameter leaves room for a "Move to Other Window" picker.
    static func moveTab(_ tabID: UUID, toNewWindow: Bool) {
        guard DeviceIdiom.supportsMultipleWindows,
              let source = Self.context.scenes.session(containing: tabID),
              source.tabs.count > 1,
              let tab = source.detachTab(tabID)
        else { return }
        Self.context.pending.adoptedTab = tab
        Self.context.scenes.requestOpenWindow(.editor)
        Self.context.scenes.openWindow?(.editor)
    }

    // MARK: - Close / confirm

    /// ⌘W closes the active tab. Closing the final tab now leaves the
    /// window with a fresh launcher tab instead of destroying it —
    /// matching Safari iPad's "Start Page". Use `closeWindow()`
    /// (⌘⇧W) when the user actually wants the window gone.
    static func closeActiveTab() {
        guard let session = Self.session else { return }
        requestCloseTab(session.selectedTabID, in: session)
    }

    /// Tear down the scene hosting `session` (default: the focused
    /// session). iPad-only; iPhone is single-window and the system
    /// request is a no-op there.
    static func closeWindow(session: EditorSession? = nil) {
        let target = session ?? Self.session
        Task { @MainActor in
            if let target,
               let scene = SessionsStore.shared.scene(forSceneUUID: target.sceneUUID) {
                await closeWindow(target, scene: scene)
            } else {
                await destroyForegroundWindowScene()
            }
        }
    }

    private static func closeWindow(_ target: EditorSession, scene: UIScene) async {
        target.isClosingWindow = true
        target.tabs.forEach { $0.state.textView?.resignFirstResponder() }
        let closeArchive: ([ClosedTabRecord], ClosedWindowRecord?)
        do {
            closeArchive = try await archiveWindowBeforeClosing(target)
        } catch {
            target.isClosingWindow = false
            Self.context.presentation.openErrorMessage =
                "Couldn't preserve the window before closing: \(error.localizedDescription)"
            return
        }
        let closedRecords = closeArchive.0
        let archivedWindow = closeArchive.1
        SessionsStore.shared.remove(forScene: target.sceneUUID)
        Self.context.scenes.focusSurvivingSession(excludingSceneUUID: target.sceneUUID)
        UIApplication.shared.requestSceneSessionDestruction(
            scene.session,
            options: nil,
            errorHandler: { error in
                Task { @MainActor in
                    target.isClosingWindow = false
                    Self.context.scenes.claimFocus(session: target)
                    SessionsStore.shared.save(
                        SessionRecord(scene: target.sceneUUID, session: target)
                    )
                    if let archivedWindow {
                        ClosedWindowsStore.shared.cancelArchive(archivedWindow.id)
                    }
                    closedRecords.forEach { ClosedTabsStore.shared.remove($0.id) }
                    Self.context.presentation.openErrorMessage =
                        "Couldn't close the window: \(error.localizedDescription)"
                }
            }
        )
    }

    /// Last-resort fallback when the acting session's scene isn't
    /// registered yet. With several windows visible, multiple scenes
    /// are simultaneously `.foregroundActive` and `connectedScenes`
    /// is unordered — this can pick the wrong window, so callers
    /// should go through `closeWindow(session:)`.
    static func destroyForegroundWindowScene() async {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) else { return }
        let target = Self.context.scenes.allOpenSessions.first(where: {
            SessionsStore.shared.scene(forSceneUUID: $0.sceneUUID) === scene
        })
        let closeArchive: ([ClosedTabRecord], ClosedWindowRecord?)
        do {
            if let target {
                target.isClosingWindow = true
                target.tabs.forEach { $0.state.textView?.resignFirstResponder() }
                closeArchive = try await archiveWindowBeforeClosing(target)
            } else {
                closeArchive = ([], nil)
            }
        } catch {
            target?.isClosingWindow = false
            Self.context.presentation.openErrorMessage =
                "Couldn't preserve the window before closing: \(error.localizedDescription)"
            return
        }
        let closedRecords = closeArchive.0
        let archivedWindow = closeArchive.1
        if let target {
            Self.context.scenes.focusSurvivingSession(
                excludingSceneUUID: target.sceneUUID
            )
        }
        SessionsStore.shared.removeRecord(
            forPersistentIdentifier: scene.session.persistentIdentifier
        )
        UIApplication.shared.requestSceneSessionDestruction(
            scene.session,
            options: nil,
            errorHandler: { error in
                Task { @MainActor in
                    if let target {
                        target.isClosingWindow = false
                        Self.context.scenes.claimFocus(session: target)
                        SessionsStore.shared.save(
                            SessionRecord(scene: target.sceneUUID, session: target)
                        )
                        if let archivedWindow {
                            ClosedWindowsStore.shared.cancelArchive(archivedWindow.id)
                        }
                        closedRecords.forEach { ClosedTabsStore.shared.remove($0.id) }
                    }
                    Self.context.presentation.openErrorMessage =
                        "Couldn't close the window: \(error.localizedDescription)"
                }
            }
        )
    }

    /// Pull exact live buffers and await their recovery writes before asking
    /// UIKit to destroy the scene. Encoding and disk I/O run on the recovery
    /// writer actor, not the main actor.
    private static func archiveWindowBeforeClosing(
        _ target: EditorSession
    ) async throws -> ([ClosedTabRecord], ClosedWindowRecord?) {
        try await DraftsStore.shared.withCapEnforcementSuspended {
            for tab in target.tabs where tab.document.isDirty {
                if let live = tab.state.textView?.text {
                    tab.document.text = live
                }
                try await tab.document.commitRecoverySnapshot()
            }
        }

        let closedRecords = target.tabs.map(EditorSession.snapshotRecord(of:))
        closedRecords.forEach { ClosedTabsStore.shared.record($0) }
        let sessionRecord = SessionRecord(scene: target.sceneUUID, session: target)
        let archivedWindow = ClosedWindowsStore.shared.archive(
            sessionRecord,
            closedTabRecordIDs: closedRecords.map(\.id)
        )
        DraftsStore.shared.enforceCapNow()
        return (closedRecords, archivedWindow)
    }

    /// Single entry point so every UI surface (pill ×, swipe-to-
    /// close, context menu, ⌘W) gets the same unsaved-changes warning.
    static func requestCloseTab(_ tabID: UUID, in session: EditorSession) {
        guard let tab = session.tabs.first(where: { $0.id == tabID }) else { return }
        if shouldWarnBeforeClose(tab) {
            Self.context.presentation.pendingClose = PendingClose(
                sessionID: ObjectIdentifier(session),
                tabID: tabID,
                displayName: tab.document.displayName,
                isUntitled: tab.document.fileURL == nil
            )
        } else {
            _ = session.closeTab(tabID)
        }
    }

    /// `.discard` disposition so the buffer is NOT archived to
    /// ClosedTabsStore — a deliberate throw-away mustn't be
    /// resurrectable via ⇧⌘T. Drops the scratch shadow too.
    static func confirmDiscardAndClose(_ pending: PendingClose) {
        defer { Self.context.presentation.pendingClose = nil }
        guard let (session, tab) = Self.resolveSession(for: pending) else { return }
        tab.document.deleteScratchFile()
        session.closeTab(pending.tabID, disposition: .discard)
    }

    /// URL-backed: save then close. Untitled: route to Save As, tab
    /// stays open. On save failure: surface the error and KEEP the
    /// tab — closing would silently destroy the buffer.
    static func confirmSaveAndClose(_ pending: PendingClose) {
        guard let (session, tab) = Self.resolveSession(for: pending) else {
            Self.context.presentation.pendingClose = nil
            return
        }
        guard tab.document.fileURL != nil else {
            Self.context.pickers.pending = .saveAs
            Self.context.presentation.pendingClose = nil
            return
        }
        // Same funnel as ⌘S so the live-text flush and stale-source
        // check apply — a raised stale dialog (or failed write) keeps
        // the tab open for the user to resolve.
        let saved = saveDocumentSafely(tab, session: session)
        Self.context.presentation.pendingClose = nil
        if saved {
            session.closeTab(pending.tabID)
        }
    }

    /// "Save as Draft" path from the close dialog + title menu:
    /// force a draft snapshot of the live text so the launcher can
    /// resume it, then close (archive disposition — both the draft
    /// and the closed-tab record become recovery vehicles). Same
    /// The close awaits the committed write so the last keystroke cannot be
    /// lost when the debounce has not fired yet.
    static func saveAsDraftAndClose(_ pending: PendingClose) {
        guard let (session, tab) = Self.resolveSession(for: pending) else { return }
        Task { @MainActor in
            defer { Self.context.presentation.pendingClose = nil }
            do {
                try await snapshotDraft(for: tab, endEditing: true)
                session.closeTab(pending.tabID)
            } catch {
                Self.context.presentation.openErrorMessage =
                    "Couldn't save the recovery draft: \(error.localizedDescription)"
            }
        }
    }

    /// Title-menu / palette entry — captures the buffer into the
    /// draft store without closing.
    static func saveAsDraft() {
        guard let session = Self.context.scenes.currentSession,
              let tab = session.tabs.first(where: { $0.id == session.selectedTabID })
        else { return }
        Task { @MainActor in
            do {
                try await snapshotDraft(for: tab, endEditing: false)
            } catch {
                Self.context.presentation.openErrorMessage =
                    "Couldn't save the recovery draft: \(error.localizedDescription)"
            }
        }
    }

    private static func snapshotDraft(for tab: TabModel, endEditing: Bool) async throws {
        if endEditing {
            tab.state.textView?.resignFirstResponder()
        }
        if let live = tab.state.textView?.text {
            tab.document.text = live
        }
        // The user is closing or explicitly Save-as-Drafting, so commit the
        // live bytes to device-local recovery; per-keystroke autosave only
        // updates scratch.
        try await tab.document.commitRecoverySnapshot()
    }

    static func cancelPendingClose() {
        Self.context.presentation.pendingClose = nil
    }

    // MARK: - Stale-source safeguard

    /// Run before any ⌘S that's targeting an existing `fileURL`.
    /// Returns `true` when the caller should proceed with the
    /// actual write — `false` means we've raised a stale dialog
    /// and the user has to resolve it first.
    @discardableResult
    static func saveDocumentSafely(_ tab: TabModel, session: EditorSession) -> Bool {
        guard let url = tab.document.fileURL else {
            Self.context.pickers.pending = .saveAs
            return false
        }
        guard let attrs = PlainTextDocument.diskAttrs(of: url) else {
            Self.context.presentation.sourceStaleCheck = .missing(
                tabID: tab.id,
                displayName: tab.document.displayName
            )
            return false
        }
        // A nil baseline means the load never completed, so we
        // can't prove the buffer reflects the disk bytes — warn
        // instead of overwriting silently. (Save Anyway works:
        // `save()` refreshes the baseline after writing.)
        let baselineMatches = tab.document.sourceMtimeAtLoad == attrs.mtime
            && tab.document.sourceSizeAtLoad == attrs.size
        if !baselineMatches {
            Self.context.presentation.sourceStaleCheck = .changedOnSave(
                tabID: tab.id,
                displayName: tab.document.displayName
            )
            return false
        }
        return performSave(tab: tab)
    }

    /// "Save Anyway" path off the stale dialog — bypasses the disk
    /// check and writes over whatever's there now. The user
    /// acknowledged data loss.
    static func forceSaveAfterStale() {
        defer { Self.context.presentation.sourceStaleCheck = nil }
        guard let check = Self.context.presentation.sourceStaleCheck,
              let (_, tab) = resolveTab(for: check)
        else { return }
        _ = performSave(tab: tab)
    }

    /// "Reload" path off the stale dialog — discards the buffer's
    /// in-memory state and re-reads the source from disk. Lossy
    /// for whatever wasn't yet ⌘S'd.
    static func reloadAfterStale() {
        defer { Self.context.presentation.sourceStaleCheck = nil }
        guard let check = Self.context.presentation.sourceStaleCheck,
              let (_, tab) = resolveTab(for: check),
              let url = tab.document.fileURL
        else { return }
        // Keep the recovery files until the replacement load succeeds. A
        // transient provider failure must not turn the user's explicit
        // Reload choice into irreversible data loss.
        DocumentWorkflow.open(url, in: tab) { result in
            if case .success = result {
                tab.document.deleteScratchFile()
            }
        }
    }

    /// "Continue Editing" path off the `changedOnAdopt` dialog —
    /// keeps the drafted text but bumps the load-time baseline to
    /// the disk's current attrs so the next ⌘S doesn't re-warn for
    /// the same drift.
    static func acceptStaleAdopt() {
        defer { Self.context.presentation.sourceStaleCheck = nil }
        guard let check = Self.context.presentation.sourceStaleCheck,
              case .changedOnAdopt = check,
              let (_, tab) = resolveTab(for: check),
              let url = tab.document.fileURL,
              let attrs = PlainTextDocument.diskAttrs(of: url)
        else { return }
        tab.document.sourceMtimeAtLoad = attrs.mtime
        tab.document.sourceSizeAtLoad = attrs.size
        tab.state.requestEditorFocus()
    }

    /// "OK" off the source-missing dialog — the file's gone, so
    /// the buffer drops its URL link and becomes Untitled. Draft
    /// stays around as recovery for the bytes themselves.
    static func acknowledgeSourceMissing() {
        defer { Self.context.presentation.sourceStaleCheck = nil }
        guard let check = Self.context.presentation.sourceStaleCheck,
              case .missing = check,
              let (_, tab) = resolveTab(for: check)
        else { return }
        tab.document.fileURL = nil
        tab.state.fileURL = nil
        tab.document.sourceMtimeAtLoad = nil
        tab.document.sourceSizeAtLoad = nil
        // No baseline against a missing file — every line is "added"
        // until the user picks a new save target.
        tab.state.savedBaselineText = ""
        tab.state.requestEditorFocus()
    }

    private static func performSave(tab: TabModel) -> Bool {
        let live = tab.state.textView?.text ?? tab.document.text
        let prepared = tab.document.preparedTextForSaving(live)
        if prepared != live, let textView = tab.state.textView {
            let fullRange = NSRange(location: 0, length: (live as NSString).length)
            textView.replace(fullRange, withText: prepared)
        }
        tab.document.text = prepared
        tab.state.text = prepared
        do {
            try tab.document.save()
            tab.state.savedBaselineText = prepared
            return true
        } catch {
            Self.context.presentation.openErrorMessage =
                "Couldn't save \(tab.document.displayName): \(error.localizedDescription)"
            return false
        }
    }

    /// Walks every open session for a tab matching the stale-check.
    private static func resolveTab(for check: SourceStaleCheck) -> (EditorSession, TabModel)? {
        let tabID: UUID
        switch check {
        case .missing(let t, _), .changedOnAdopt(let t, _), .changedOnSave(let t, _):
            tabID = t
        }
        for session in Self.context.scenes.allOpenSessions {
            if let tab = session.tabs.first(where: { $0.id == tabID }) {
                return (session, tab)
            }
        }
        return nil
    }

    /// Shared by save / discard handlers so both reach the same
    /// definition of "the targeted tab."
    private static func resolveSession(for pending: PendingClose) -> (EditorSession, TabModel)? {
        let sessions = Self.context.scenes.allOpenSessions
        guard let session = sessions.first(where: { ObjectIdentifier($0) == pending.sessionID }),
              let tab = session.tabs.first(where: { $0.id == pending.tabID })
        else { return nil }
        return (session, tab)
    }

    /// Untitled-with-content or URL-backed-and-dirty triggers the
    /// dialog. Empty untitled scratches close silently — losing zero
    /// bytes isn't worth a confirmation.
    private static func shouldWarnBeforeClose(_ tab: TabModel) -> Bool {
        // Pull the engine's live buffer — `document.text` is a 300 ms
        // snapshot and a one-character untitled buffer + immediate
        // ⌘W would otherwise sail past the warning.
        let liveText = tab.state.textView?.text ?? tab.document.text
        if tab.document.fileURL == nil {
            return !liveText.isEmpty
        }
        return tab.document.isDirty
    }

    /// Public peek — sheet-hosting UI (switcher, palette) checks
    /// this so it can dismiss itself before the dialog. iOS hosts
    /// one modal per scene; presenting under another sheet drops
    /// the dialog silently or wedges the app.
    static func tabNeedsCloseConfirmation(_ tab: TabModel) -> Bool {
        shouldWarnBeforeClose(tab)
    }

    // MARK: - Draft recovery

    /// Two paths off the recovery sheet:
    ///   - URL-backed (metadata.sourceBookmark): re-attach the URL,
    ///     apply drafted text on top (dirty), seed baseline with the
    ///     on-disk content so the gutter highlights only the unsaved
    ///     deltas.
    ///   - Untitled: bytes load into a fresh Untitled tab; `draftURL`
    ///     is inherited so the next autosave overwrites the same file
    ///     instead of orphaning the old one.
    static func recoverDraft(_ draft: DraftRecord) {
        guard let session = Self.session else { return }
        let tab = session.newTab(kind: .editor)
        Task {
            do {
                if let staleCheck = try await DraftRecoveryWorkflow.adopt(draft, into: tab) {
                    context.presentation.sourceStaleCheck = staleCheck
                }
            } catch is CancellationError {
                session.closeTab(tab.id, disposition: .discard)
            } catch {
                session.closeTab(tab.id, disposition: .discard)
                context.presentation.openErrorMessage = error.localizedDescription
            }
        }
    }

    /// Restore a closed tab group into its own scene. The archive remains
    /// durable until the new EditorScene consumes it, so a failed or delayed
    /// window request cannot orphan the underlying recovery drafts.
    static func recoverClosedWindow(_ record: ClosedWindowRecord) {
        guard let openEditorWindow = Self.context.scenes.openEditorWindow else {
            Self.context.presentation.openErrorMessage =
                "A new window isn't available yet. The recovered window was kept so you can try again."
            return
        }
        ClosedWindowsStore.shared.dismissNotice()
        openEditorWindow(.restoreClosedWindow(record.id))
    }

    // MARK: - Duplicate / rename

    static func duplicateCurrentTab() {
        guard let session = Self.session else { return }
        let source = session.activeTab
        // Pull engine-live text — `document.text` lags by 300 ms and
        // a Duplicate right after typing would copy stale bytes.
        let snapshot = source.state.textView?.text ?? source.document.text
        let language = source.state.languageIdentifier
        let encoding = source.document.fileEncoding
        let lineEnding = source.document.lineEnding
        let tab = session.newTab()
        tab.document.text = snapshot
        tab.document.isDirty = true
        tab.document.fileEncoding = encoding
        tab.document.lineEnding = lineEnding
        tab.state.text = snapshot
        tab.state.languageIdentifier = language
        tab.state.fileEncoding = encoding
        tab.state.lineEnding = lineEnding
    }

    /// Preserves the original extension unless the user typed one
    /// explicitly. Renames on disk and updates both `fileURL` mirrors
    /// so the rest of the app picks up the new path immediately.
    static func renameCurrentFile(to newName: String) {
        guard let session = Self.session else { return }
        let document = session.activeTab.document
        let state = session.activeTab.state
        guard let oldURL = document.fileURL else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Typed dot = explicit override; otherwise inherit the old
        // extension.
        let finalName: String
        if trimmed.contains(".") {
            finalName = trimmed
        } else {
            let ext = oldURL.pathExtension
            finalName = ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
        }
        guard finalName != oldURL.lastPathComponent else { return }
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(finalName)
        let scoped = oldURL.startAccessingSecurityScopedResource()
        defer { if scoped { oldURL.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            document.fileURL = newURL
            state.fileURL = newURL
            RecentFilesStore.shared.record(newURL)
        } catch {
            Self.context.presentation.openErrorMessage =
                "Couldn't rename \(oldURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Navigation among tabs

    static func nextTab() {
        Self.context.scenes.currentSession?.selectNextTab()
    }

    static func previousTab() {
        Self.context.scenes.currentSession?.selectPreviousTab()
    }

    static func selectTab(at position: Int) {
        Self.context.scenes.currentSession?.selectTab(at: position)
    }

    static func pinCurrentTab() {
        guard let session = Self.session else { return }
        session.togglePinned(session.selectedTabID)
    }

    static func closeOtherTabs() {
        guard let session = Self.session else { return }
        requestCloseOtherTabs(except: session.selectedTabID, in: session)
    }

    static func closeTabsToRight() {
        guard let session = Self.session else { return }
        requestCloseTabsToRight(of: session.selectedTabID, in: session)
    }

    // MARK: - Batch close (Close Other Tabs / Right / All)

    /// Route every "close many tabs" entry through one funnel so the
    /// unsaved-changes dialog is consistent. The dialog fires only
    /// when at least one of the tabs in the closing set is dirty;
    /// clean batches go through immediately.
    static func requestCloseOtherTabs(except keepID: UUID, in session: EditorSession) {
        let victims = session.tabs.filter { $0.id != keepID && !$0.isPinned }
        requestCloseTabs(victims, in: session, description: descriptor(for: victims.count, kind: .other))
    }

    static func requestCloseTabsToRight(of pivotID: UUID, in session: EditorSession) {
        guard let pivot = session.tabs.firstIndex(where: { $0.id == pivotID }) else { return }
        let victims = session.tabs[(pivot + 1)...].filter { !$0.isPinned }
        requestCloseTabs(Array(victims), in: session, description: descriptor(for: victims.count, kind: .right))
    }

    static func requestCloseAllTabs(in session: EditorSession) {
        // Pinned tabs are exempt — matches the Safari semantics
        // every other batch-close command in the app follows.
        let victims = session.tabs.filter { !$0.isPinned }
        requestCloseTabs(victims, in: session, description: descriptor(for: victims.count, kind: .all))
    }

    private enum BatchKind { case other, right, all }

    private static func descriptor(for count: Int, kind: BatchKind) -> String {
        let plural = (count == 1 ? "tab" : "tabs")
        switch kind {
        case .other: return count == 1 ? "Close 1 other tab" : "Close \(count) other tabs"
        case .right: return "Close \(count) \(plural) to the right"
        case .all:   return count == 1 ? "Close 1 tab" : "Close all \(count) tabs"
        }
    }

    private static func requestCloseTabs(_ victims: [TabModel], in session: EditorSession, description: String) {
        guard !victims.isEmpty else { return }
        let dirty = victims.filter(shouldWarnBeforeClose)
        if dirty.isEmpty {
            for tab in victims { session.closeTab(tab.id) }
            return
        }
        Self.context.presentation.pendingBatchClose = PendingBatchClose(
            sessionID: ObjectIdentifier(session),
            tabIDs: victims.map(\.id),
            description: description,
            dirtyCount: dirty.count
        )
    }

    /// "Discard All" path — wipes scratch + draft for every dirty tab
    /// so the bytes can't resurrect from the launcher or ⇧⌘T.
    static func confirmBatchDiscard(_ pending: PendingBatchClose) {
        defer { Self.context.presentation.pendingBatchClose = nil }
        guard let session = resolveSession(for: pending) else { return }
        for tabID in pending.tabIDs {
            guard let tab = session.tabs.first(where: { $0.id == tabID }) else { continue }
            tab.document.deleteScratchFile()
            session.closeTab(tabID, disposition: .discard)
        }
    }

    /// "Save All to Drafts" — autosave the live buffer for every
    /// dirty tab (URL-backed gets a draft pinned to its source;
    /// untitled goes to the recovery pool), then close everything
    /// with `.archive` disposition so ⇧⌘T can resurrect them too.
    static func confirmBatchSaveAsDrafts(_ pending: PendingBatchClose) {
        guard let session = resolveSession(for: pending) else { return }
        Task { @MainActor in
            defer { Self.context.presentation.pendingBatchClose = nil }
            do {
                for tabID in pending.tabIDs {
                    guard let tab = session.tabs.first(where: { $0.id == tabID }) else { continue }
                    try await snapshotDraft(for: tab, endEditing: true)
                    session.closeTab(tabID)
                }
            } catch {
                Self.context.presentation.openErrorMessage =
                    "Couldn't save all recovery drafts: \(error.localizedDescription)"
            }
        }
    }

    static func cancelBatchClose() {
        Self.context.presentation.pendingBatchClose = nil
    }

    /// Resolves the originating session for a PendingBatchClose,
    /// matching by identity so the dialog hits the right window
    /// even after focus shifts.
    private static func resolveSession(for pending: PendingBatchClose) -> EditorSession? {
        Self.context.scenes.allOpenSessions.first { ObjectIdentifier($0) == pending.sessionID }
    }

    /// Reopen the most-recently closed tab in the active session.
    /// File-backed tabs route through the standard open path so
    /// security-scoped access and revision tracking re-initialize
    /// cleanly. Untitled buffers are rehydrated from the text
    /// snapshot taken at close time.
    static func reopenLastClosedTab() {
        guard Self.session != nil,
              let record = ClosedTabsStore.shared.first
        else { return }
        reopenClosedTab(record)
    }

    static func reopenClosedTab(_ record: ClosedTabRecord) {
        guard let session = Self.session else { return }
        let store = ClosedTabsStore.shared
        Task {
            let snapshot: String?
            do {
                snapshot = try await store.loadSnapshot(record)
            } catch {
                Self.context.presentation.openErrorMessage = error.localizedDescription
                return
            }

            if let url = store.resolveSourceURL(record) {
                let tab = session.newTab(kind: .editor)
                DocumentWorkflow.open(url, in: tab) { result in
                    switch result {
                    case .success:
                        if let snapshot {
                            restoreClosedSnapshot(
                                snapshot,
                                record: record,
                                into: tab,
                                sourceAvailable: true
                            )
                        }
                        store.remove(record.id)
                    case .failure:
                        guard let snapshot else {
                            session.closeTab(tab.id, disposition: .discard)
                            return
                        }
                        // The source disappeared, but the archived dirty
                        // bytes are still recoverable as an untitled tab.
                        restoreClosedSnapshot(
                            snapshot,
                            record: record,
                            into: tab,
                            sourceAvailable: false
                        )
                        store.remove(record.id)
                    }
                }
                return
            }

            guard snapshot != nil || record.sourceBookmark == nil else {
                Self.context.presentation.openErrorMessage =
                    ClosedTabsFailure.sourceUnavailable.localizedDescription
                return
            }
            let tab = session.newTab(kind: .editor)
            if let snapshot {
                restoreClosedSnapshot(
                    snapshot,
                    record: record,
                    into: tab,
                    sourceAvailable: false
                )
            } else {
                tab.state.requestEditorFocus()
            }
            store.remove(record.id)
        }
    }

    private static func restoreClosedSnapshot(
        _ snapshot: String,
        record: ClosedTabRecord,
        into tab: TabModel,
        sourceAvailable: Bool
    ) {
        if !sourceAvailable {
            tab.document.fileURL = nil
            tab.state.fileURL = nil
            tab.state.savedBaselineText = ""
        }
        tab.document.text = snapshot
        tab.document.isDirty = true
        tab.document.bufferRevision &+= 1
        tab.state.text = snapshot
        tab.state.setText?(snapshot)
        if let filename = record.draftFilename {
            tab.document.draftURL = DraftsStore.shared.readDirectories
                .map { $0.appendingPathComponent(filename) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        tab.kind = .editor
        tab.state.requestEditorFocus()
        tab.document.autoSave()
    }
}
