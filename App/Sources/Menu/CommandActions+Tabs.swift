import Foundation
import UIKit
import FileEncoding

extension CommandActions {

    // MARK: - Move / detach

    /// Keep the tab in its source window until its destination receives
    /// the identified request. A failed window open cannot orphan the tab.
    static func moveTabToNewWindow(_ tabID: UUID) {
        guard DeviceIdiom.supportsMultipleWindows,
              let source = Self.context.scenes.session(containing: tabID), source.tabs.count > 1,
              source.tabs.contains(where: { $0.id == tabID }) else { return }
        Self.context.scenes.openEditorWindow?(.moveTab(tabID))
    }

    // MARK: - Close / confirm

    /// ⌘W closes the active tab. Closing the final tab now leaves the
    /// window with a fresh start page. Use `closeWindow()`
    /// (⌘⇧W) when the user actually wants the window gone.
    static func closeActiveTab() {
        guard let session = Self.session else { return }
        requestCloseTab(session.selectedTabID, in: session)
    }

    /// Tear down the scene hosting `session` (default: the focused
    /// session). iPad-only; iPhone is single-window and the system
    /// request is a no-op there.
    static func closeWindow(session: EditorSession? = nil) {
        guard DeviceIdiom.supportsMultipleWindows else { return }
        let target = session ?? Self.session
        if let request = target?.requestClose {
            request(.window)
            return
        }
        // An unregistered scene must not fall back to an arbitrary foreground
        // window: multiple windows can be foreground-active on iPad.
        target?.activeTab.state.operationError = "The window is not ready to close. Please try again."
    }

    static func saveAllAndCloseWindow(session: EditorSession? = nil) {
        guard DeviceIdiom.supportsMultipleWindows else { return }
        let target = session ?? Self.session
        guard let save = target?.requestSaveAllAndCloseWindow else {
            target?.activeTab.state.operationError = "The window is not ready to save and close. Please try again."
            return
        }
        save()
    }

    static func closeWindow(_ target: EditorSession, scene: UIScene, discardChanges: Bool = false) {
        guard target.prepareForWindowClose(discardChanges: discardChanges) else { return }
        Self.context.scenes.focusSurvivingSession(excludingSceneUUID: target.sceneUUID)
        // This decision has already been confirmed. Do not wait for the next
        // SwiftUI update to remove the native confirmation configuration.
        (scene as? UIWindowScene)?.closureConfirmation = nil
        UIApplication.shared.requestSceneSessionDestruction(
            scene.session,
            options: nil,
            errorHandler: { error in
                Task { @MainActor in
                    target.isClosingWindow = false
                    Self.context.scenes.claimFocus(session: target)
                    // The live buffers remain authoritative if UIKit refuses
                    // the close. Reestablish their private checkpoints.
                    var message = "Couldn't close the window: \(error.localizedDescription)"
                    do {
                        try await target.checkpointDocuments()
                    } catch {
                        message += " Recovery checkpoint failed: \(error.localizedDescription)"
                    }
                    target.persistRestorationRecord()
                    target.activeTab.state.operationError = message
                }
            }
        )
    }

    /// Single entry point so every UI surface (pill ×, swipe-to-
    /// close, context menu, ⌘W) gets the same unsaved-changes warning.
    static func requestCloseTab(_ tabID: UUID, in session: EditorSession) {
        guard let tab = session.tabs.first(where: { $0.id == tabID }) else { return }
        requestCloseTabs([tab], in: session)
    }

    // MARK: - Stale-source safeguard

    /// Source validation and the write share one coordinated access.
    @discardableResult
    static func saveDocumentSafely(_ tab: TabModel, overwrite: Bool = false) async -> Bool {
        guard tab.document.fileURL != nil else {
            Self.context.pickers.pending = .saveAs
            return false
        }
        guard !tab.document.isSaving else { return false }
        do {
            try await DocumentWorkflow.save(tab, overwrite: overwrite)
            return true
        } catch is CancellationError {
            return false
        } catch PlainTextDocument.DocumentError.sourceChanged {
            Self.context.presentation.sourceStaleCheck = .changedOnSave(
                tabID: tab.id, displayName: tab.document.displayName)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            Self.context.presentation.sourceStaleCheck = .missing(
                tabID: tab.id, displayName: tab.document.displayName)
        } catch {
            Self.context.presentation.openErrorMessage =
                "Couldn't save \(tab.document.displayName): \(error.localizedDescription)"
        }
        return false
    }

    static func forceSaveAfterStale() {
        guard let check = Self.context.presentation.sourceStaleCheck,
              let (_, tab) = resolveTab(for: check) else { return }
        Self.context.presentation.sourceStaleCheck = nil
        Task { @MainActor in _ = await saveDocumentSafely(tab, overwrite: true) }
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

    /// Accept the current disk version as the draft's new save baseline,
    /// retaining the recovered text and its selected encoding.
    static func acceptStaleAdopt() {
        guard let check = Self.context.presentation.sourceStaleCheck,
              case .changedOnAdopt = check, let (_, tab) = resolveTab(for: check),
              let url = tab.document.fileURL else { return }
        let presentation = Self.context.presentation
        presentation.sourceStaleCheck = nil
        let generation = tab.state.loadGeneration
        Task { @MainActor in
            do {
                let payload = try await PlainTextDocument.readPayload(from: url)
                guard tab.state.loadGeneration == generation, tab.document.fileURL == url else { return }
                tab.document.originalData = payload.data
                tab.document.sourceMtimeAtLoad = payload.modificationDate
                tab.document.sourceSizeAtLoad = payload.data.count
                tab.state.requestEditorFocus()
            } catch {
                presentation.openErrorMessage = "Couldn't read the current source: " + error.localizedDescription
            }
        }
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

    // MARK: - Draft recovery

    /// Two paths off the recovery sheet:
    ///   - URL-backed (metadata.sourceBookmark): re-attach the URL,
    ///     apply drafted text on top (dirty), seed baseline with the
    ///     on-disk content so the gutter highlights only the unsaved
    ///     deltas.
    ///   - Untitled: bytes load into a fresh Untitled tab; `draftURL`
    ///     is inherited so the next autosave overwrites the same file
    ///     instead of orphaning the old one.
    static func recoverDraft(_ draft: DraftRecord, in session: EditorSession) {
        guard Self.context.scenes.allOpenSessions.contains(where: { $0 === session }) else { return }
        let tab = session.newTab(kind: .editor)
        tab.document.isLoading = true
        tab.state.loadTask = Task { @MainActor [weak session, weak tab] in
            guard let session, let tab else { return }
            defer {
                tab.document.isLoading = false
                tab.state.loadTask = nil
                session.persistRestorationRecord()
            }
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
    static func recoverClosedWindow(_ record: ClosedWindowRecord, in session: EditorSession) {
        guard Self.context.scenes.allOpenSessions.contains(where: { $0 === session }) else { return }
        if !DeviceIdiom.supportsMultipleWindows {
            let recovered = record.sessionRecord(sceneUUID: session.sceneUUID,
                launchID: SessionsStore.shared.currentLaunchID,
                persistentIdentifier: SessionsStore.shared.persistentIdentifier(forSceneUUID: session.sceneUUID))
            let append = session.tabs.count > 1 || session.activeTab.kind != .launcher
            var combined = SessionRecord(scene: session.sceneUUID, session: session)
            combined.activeIndex = combined.tabs.count + recovered.activeIndex
            combined.tabs += recovered.tabs
            SessionsStore.shared.save(combined)
            SessionRestore.apply(recovered, to: session, append: append)
            ClosedWindowsStore.shared.completeRestore(record.id)
            return
        }
        guard let openEditorWindow = Self.context.scenes.openEditorWindow else {
            Self.context.presentation.openErrorMessage =
                "A new window isn't available yet. The recovered window was kept so you can try again."
            return
        }
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
        let tab = session.newTab(kind: .editor)
        tab.document.fileEncoding = encoding
        tab.document.lineEnding = lineEnding
        tab.state.fileEncoding = encoding
        tab.state.lineEnding = lineEnding
        tab.state.languageIdentifier = language
        tab.startDocument(with: snapshot)
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
        guard !finalName.contains("/"), finalName != ".", finalName != "..", !finalName.contains("\u{0}") else {
            state.operationError = "Enter a filename without path separators."
            return
        }
        guard !document.isSaving, !document.isLoading else { return }
        document.isSaving = true
        Task { @MainActor in
            defer { document.isSaving = false }
            do {
                let movedURL = try await CoordinatedFileAccess.move(from: oldURL, to: newURL)
                guard document.fileURL == oldURL || document.fileURL == movedURL else { return }
                document.fileURL = movedURL
                document.revisionKey = RevisionStore.key(for: movedURL)
                state.fileURL = movedURL
                state.siblingState?.fileURL = movedURL
                RecentFilesStore.shared.record(movedURL)
            } catch {
                state.operationError =
                    "Couldn't rename \(oldURL.lastPathComponent): \(error.localizedDescription)"
            }
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
        requestCloseTabs(victims, in: session)
    }

    static func requestCloseTabsToRight(of pivotID: UUID, in session: EditorSession) {
        guard let pivot = session.tabs.firstIndex(where: { $0.id == pivotID }) else { return }
        let victims = session.tabs[(pivot + 1)...].filter { !$0.isPinned }
        requestCloseTabs(Array(victims), in: session)
    }

    static func requestCloseAllTabs(in session: EditorSession) {
        // Preserve pinned tabs, as with the other batch-close commands.
        let victims = session.tabs.filter { !$0.isPinned }
        requestCloseTabs(victims, in: session)
    }

    private static func requestCloseTabs(_ victims: [TabModel], in session: EditorSession) {
        guard !victims.isEmpty else { return }
        if !victims.contains(where: \.needsCloseConfirmation) {
            for tab in victims { session.closeTab(tab.id) }
            return
        }
        guard let review = session.requestClose else {
            session.activeTab.state.operationError = "The window is not ready to close. Please try again."
            return
        }
        review(.tabs(victims.map(\.id)))
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
