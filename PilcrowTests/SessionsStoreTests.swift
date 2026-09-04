import XCTest
@testable import Pilcrow

@MainActor
final class SessionsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SessionsStore!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "pilcrow-sessions-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        // observesScenes: false skips the global UIScene observer that
        // the singleton wires up — the test harness has no live scenes.
        store = SessionsStore(defaults: defaults, observesScenes: false)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Codable round-trip

    func test_record_serializationRoundTrip() throws {
        let original = SessionRecord(
            sceneUUID: "scene-1",
            tabs: [
                TabSnapshot(
                    fileBookmark: Data([0x01, 0x02, 0x03]),
                    draftFilename: "draft-1.txt",
                    isPinned: true,
                    displayName: "notes.md"
                ),
                TabSnapshot(
                    fileBookmark: nil,
                    draftFilename: nil,
                    isPinned: false
                ),
            ],
            activeIndex: 1,
            lastModified: Date(timeIntervalSince1970: 1_700_000_000),
            launchID: "launch-A",
            persistentIdentifier: "pid-abc"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: data)
        XCTAssertEqual(decoded.sceneUUID, original.sceneUUID)
        XCTAssertEqual(decoded.activeIndex, original.activeIndex)
        XCTAssertEqual(decoded.launchID, original.launchID)
        XCTAssertEqual(decoded.persistentIdentifier, original.persistentIdentifier)
        XCTAssertEqual(decoded.lastModified, original.lastModified)
        XCTAssertEqual(decoded.tabs.count, 2)
        XCTAssertEqual(decoded.tabs[0].fileBookmark, original.tabs[0].fileBookmark)
        XCTAssertEqual(decoded.tabs[0].draftFilename, original.tabs[0].draftFilename)
        XCTAssertTrue(decoded.tabs[0].isPinned)
        XCTAssertEqual(decoded.tabs[0].displayName, "notes.md")
        XCTAssertFalse(decoded.tabs[1].isPinned)
    }

    func test_tabSnapshot_decodesRecordsWrittenBeforeDisplayName() throws {
        let data = try XCTUnwrap(
            #"{"fileBookmark":null,"draftFilename":"draft.txt","isPinned":false}"#
                .data(using: .utf8)
        )
        let decoded = try JSONDecoder().decode(TabSnapshot.self, from: data)
        XCTAssertEqual(decoded.draftFilename, "draft.txt")
        XCTAssertNil(decoded.displayName)
    }

    // MARK: - tab insertion

    func test_newSessionStartsWithBlankEditor() {
        let session = EditorSession()

        XCTAssertEqual(session.tabs.count, 1)
        if case .editor = session.activeTab.kind {
            // Expected.
        } else {
            XCTFail("A new window should start with a blank editor")
        }
        XCTAssertEqual(session.activeTab.document.text, "")
        XCTAssertNil(session.activeTab.document.fileURL)
    }

    func test_newTab_insertsImmediatelyToRightOfActiveTab() {
        let session = EditorSession()
        let first = session.activeTab
        let second = session.newTab()
        let third = session.newTab()
        session.selectedTabID = first.id

        let inserted = session.newTab()

        XCTAssertEqual(
            session.tabs.map(\.id),
            [first.id, inserted.id, second.id, third.id]
        )
        XCTAssertEqual(session.selectedTabID, inserted.id)
        if case .editor = inserted.kind {
            // Expected.
        } else {
            XCTFail("New should create a blank editor tab")
        }
    }

    func test_closingLastTabLeavesBlankEditor() {
        let session = EditorSession()
        let original = session.activeTab

        XCTAssertTrue(session.closeTab(original.id, disposition: .discard))
        XCTAssertEqual(session.tabs.count, 1)
        XCTAssertNotEqual(session.activeTab.id, original.id)
        if case .editor = session.activeTab.kind {
            // Expected.
        } else {
            XCTFail("Closing the last tab should leave a blank editor")
        }
    }

    func test_newTab_afterPinnedSelection_preservesPinnedBlock() {
        let session = EditorSession()
        let firstPinned = session.activeTab
        let secondPinned = session.newTab()
        let existingUnpinned = session.newTab()
        session.togglePinned(firstPinned.id)
        session.togglePinned(secondPinned.id)
        session.selectedTabID = firstPinned.id

        let inserted = session.newTab()

        XCTAssertEqual(
            session.tabs.map(\.id),
            [firstPinned.id, secondPinned.id, inserted.id, existingUnpinned.id]
        )
        XCTAssertTrue(session.tabs[0].isPinned)
        XCTAssertTrue(session.tabs[1].isPinned)
        XCTAssertFalse(session.tabs[2].isPinned)
    }

    // MARK: - save / lookup

    func test_save_replacesPriorRecordForSameSceneUUID() {
        let v1 = makeRecord(sceneUUID: "scene-1", launchID: "L1", tabs: 1)
        let v2 = makeRecord(sceneUUID: "scene-1", launchID: "L1", tabs: 3)
        store.save(v1)
        store.save(v2)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.record(forScene: "scene-1")?.tabs.count, 3)
    }

    func test_save_newestRecordSortsToFront() {
        let a = makeRecord(sceneUUID: "scene-A", launchID: "L1", tabs: 1)
        let b = makeRecord(sceneUUID: "scene-B", launchID: "L1", tabs: 2)
        store.save(a)
        store.save(b)
        XCTAssertEqual(store.records.first?.sceneUUID, "scene-B")
    }

    func test_remove_byScene_removesRecord() {
        store.save(makeRecord(sceneUUID: "scene-A", launchID: "L1"))
        store.save(makeRecord(sceneUUID: "scene-B", launchID: "L1"))
        store.remove(forScene: "scene-A")
        XCTAssertNil(store.record(forScene: "scene-A"))
        XCTAssertNotNil(store.record(forScene: "scene-B"))
    }

    // MARK: - cap

    func test_save_evictsPastCap() {
        for i in 0..<(SessionsStore.cap + 5) {
            store.save(makeRecord(sceneUUID: "scene-\(i)", launchID: "L1"))
        }
        XCTAssertEqual(store.records.count, SessionsStore.cap)
    }

    // MARK: - persistence

    func test_persistence_recordsSurviveAcrossInstances() {
        store.save(makeRecord(sceneUUID: "scene-A", launchID: "L1"))
        store.save(makeRecord(sceneUUID: "scene-B", launchID: "L1"))
        let fresh = SessionsStore(defaults: defaults, observesScenes: false)
        XCTAssertEqual(fresh.records.map(\.sceneUUID).sorted(), ["scene-A", "scene-B"])
    }

    // MARK: - persistentIdentifier lookup

    func test_hasRecord_forPersistentIdentifier() {
        store.save(makeRecord(
            sceneUUID: "scene-A",
            launchID: "L1",
            persistentIdentifier: "pid-1"
        ))
        XCTAssertTrue(store.hasRecord(forPersistentIdentifier: "pid-1"))
        XCTAssertFalse(store.hasRecord(forPersistentIdentifier: "pid-other"))
        XCTAssertEqual(
            store.record(forPersistentIdentifier: "pid-1")?.sceneUUID,
            "scene-A"
        )
    }

    func test_removeRecord_forPersistentIdentifier_dropsRecord() {
        let pid = "pid-doomed"
        store.save(makeRecord(sceneUUID: "scene-A", launchID: "L1", persistentIdentifier: pid))
        store.save(makeRecord(sceneUUID: "scene-B", launchID: "L1", persistentIdentifier: "pid-other"))
        store.removeRecord(forPersistentIdentifier: pid)
        XCTAssertFalse(store.hasRecord(forPersistentIdentifier: pid))
        XCTAssertTrue(store.hasRecord(forPersistentIdentifier: "pid-other"))
    }

    // MARK: - restore sweep

    func test_initiateRestoreSweep_returnsCountOfPriorLaunchRecords() {
        // Simulate a previous launch: two records tagged with a launchID
        // that differs from the store's currentLaunchID.
        let priorLaunch = "previous-launch-id"
        store.save(makeRecord(sceneUUID: "scene-A", launchID: priorLaunch, tabs: 1))
        store.save(makeRecord(sceneUUID: "scene-B", launchID: priorLaunch, tabs: 2))
        // And a current-launch record that must NOT be in the sweep.
        store.save(makeRecord(sceneUUID: "scene-C", launchID: store.currentLaunchID))
        let count = store.initiateRestoreSweep()
        XCTAssertEqual(count, 2)
    }

    func test_initiateRestoreSweep_isIdempotentPerLaunch() {
        store.save(makeRecord(sceneUUID: "scene-A", launchID: "L_prev"))
        _ = store.initiateRestoreSweep()
        XCTAssertEqual(store.initiateRestoreSweep(), 0,
                       "Second call returns 0 — only one scene should seed the queue")
    }

    func test_consumePendingRestore_drainsInFIFOOrder() {
        store.save(makeRecord(
            sceneUUID: "scene-A",
            launchID: "L_prev",
            lastModified: Date(timeIntervalSince1970: 100)
        ))
        store.save(makeRecord(
            sceneUUID: "scene-B",
            launchID: "L_prev",
            lastModified: Date(timeIntervalSince1970: 200)
        ))
        _ = store.initiateRestoreSweep()
        // Older-first per docstring on recordsFromPreviousLaunch.
        XCTAssertEqual(store.consumePendingRestore()?.sceneUUID, "scene-A")
        XCTAssertEqual(store.consumePendingRestore()?.sceneUUID, "scene-B")
        XCTAssertNil(store.consumePendingRestore())
    }

    func test_initiateRestoreSweep_picksMostRecentPriorLaunchOnly() {
        // Two prior launches' records coexist. The sweep should restore
        // only the most recent prior launch's set.
        store.save(makeRecord(sceneUUID: "scene-old", launchID: "L_old",
                              lastModified: Date(timeIntervalSince1970: 100)))
        store.save(makeRecord(sceneUUID: "scene-recent-1", launchID: "L_recent",
                              lastModified: Date(timeIntervalSince1970: 500)))
        store.save(makeRecord(sceneUUID: "scene-recent-2", launchID: "L_recent",
                              lastModified: Date(timeIntervalSince1970: 600)))
        XCTAssertEqual(store.initiateRestoreSweep(), 2,
                       "Only L_recent records get restored; L_old stays dormant")
        let drained = (0..<2).compactMap { _ in store.consumePendingRestore()?.sceneUUID }
        XCTAssertEqual(Set(drained), ["scene-recent-1", "scene-recent-2"])
    }

    // MARK: - consumeOpen (palette/multi-scene gating)

    func test_consumeOpen_isRouterAPI_butLivesInSceneRouterTests() {
        // Documenting that consumeOpen is on SceneRouter, not SessionsStore.
        // Left here intentionally as a breadcrumb for future readers.
    }

    func test_sessionRestore_loadsBookmarkedSource() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pilcrow-session-restore-\(UUID().uuidString).txt")
        try Data("restored source".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let record = SessionRecord(
            sceneUUID: "restore-source",
            tabs: [TabSnapshot(
                fileBookmark: try sourceURL.bookmarkData(),
                draftFilename: nil,
                isPinned: true
            )],
            activeIndex: 0,
            lastModified: Date(),
            launchID: "previous-launch",
            persistentIdentifier: nil
        )
        let session = EditorSession()

        SessionRestore.apply(record, to: session)
        for _ in 0..<100 where session.activeTab.document.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(session.activeTab.document.isLoading)
        XCTAssertEqual(session.activeTab.document.text, "restored source")
        XCTAssertEqual(
            session.activeTab.document.fileURL?.standardizedFileURL,
            sourceURL.standardizedFileURL
        )
        XCTAssertTrue(session.activeTab.isPinned)
    }

    // MARK: - recently closed windows

    func test_closedWindows_archiveIgnoresCleanWindow() {
        let closed = ClosedWindowsStore(
            defaults: defaults,
            discardDraft: { _ in },
            removeClosedTab: { _ in }
        )
        XCTAssertNil(closed.archive(makeRecord(sceneUUID: "clean", launchID: "L1")))
        XCTAssertTrue(closed.records.isEmpty)
    }

    func test_closedWindows_dirtyArchivePersistsAcrossInstances() throws {
        var record = makeRecord(
            sceneUUID: "dirty",
            launchID: "L1",
            tabs: 2,
            persistentIdentifier: "pid-dirty"
        )
        record.activeIndex = 1
        record.tabs[1].draftFilename = "recovery.txt"
        let closed = ClosedWindowsStore(
            defaults: defaults,
            discardDraft: { _ in },
            removeClosedTab: { _ in }
        )
        let archived = try XCTUnwrap(closed.archive(record))
        XCTAssertEqual(closed.pendingNotice?.id, archived.id)
        XCTAssertEqual(archived.dirtyTabCount, 1)
        XCTAssertEqual(archived.tabCount, 2)

        let fresh = ClosedWindowsStore(
            defaults: defaults,
            discardDraft: { _ in },
            removeClosedTab: { _ in }
        )
        XCTAssertEqual(fresh.records.count, 1)
        XCTAssertEqual(fresh.records.first?.id, archived.id)
        XCTAssertEqual(fresh.records.first?.sourcePersistentIdentifier, "pid-dirty")
        XCTAssertNil(fresh.pendingNotice, "Transient banner state is not persisted")
    }

    func test_closedWindow_sessionRecordRehomesArchiveIntoNewScene() {
        var original = makeRecord(
            sceneUUID: "old-scene",
            launchID: "old-launch",
            tabs: 2,
            persistentIdentifier: "old-pid"
        )
        original.activeIndex = 1
        original.tabs[0].draftFilename = "first.txt"
        let archive = ClosedWindowRecord(sessionRecord: original)

        let replacement = archive.sessionRecord(
            sceneUUID: "new-scene",
            launchID: "new-launch",
            persistentIdentifier: "new-pid"
        )
        XCTAssertEqual(replacement.sceneUUID, "new-scene")
        XCTAssertEqual(replacement.launchID, "new-launch")
        XCTAssertEqual(replacement.persistentIdentifier, "new-pid")
        XCTAssertEqual(replacement.activeIndex, 1)
        XCTAssertEqual(replacement.tabs.count, 2)
        XCTAssertEqual(replacement.tabs[0].draftFilename, "first.txt")
    }

    func test_closedWindows_discardRemovesAssociatedHistoryAndDrafts() throws {
        var discardedDrafts: [String] = []
        var removedTabs: [UUID] = []
        let closed = ClosedWindowsStore(
            defaults: defaults,
            discardDraft: { discardedDrafts.append($0) },
            removeClosedTab: { removedTabs.append($0) }
        )
        var record = makeRecord(sceneUUID: "dirty", launchID: "L1", tabs: 2)
        record.tabs[0].draftFilename = "first.txt"
        record.tabs[1].draftFilename = "second.txt"
        let tabIDs = [UUID(), UUID()]
        let archived = try XCTUnwrap(closed.archive(
            record,
            closedTabRecordIDs: tabIDs
        ))

        closed.discard(archived.id)

        XCTAssertTrue(closed.records.isEmpty)
        XCTAssertEqual(Set(discardedDrafts), ["first.txt", "second.txt"])
        XCTAssertEqual(Set(removedTabs), Set(tabIDs))
    }

    func test_closedWindows_archiveDeduplicatesSystemCallbackByPersistentID() throws {
        var record = makeRecord(
            sceneUUID: "dirty",
            launchID: "L1",
            persistentIdentifier: "pid-one"
        )
        record.tabs[0].draftFilename = "recovery.txt"
        let closed = ClosedWindowsStore(
            defaults: defaults,
            discardDraft: { _ in },
            removeClosedTab: { _ in }
        )
        let first = try XCTUnwrap(closed.archive(record))
        let second = try XCTUnwrap(closed.archive(record))
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(closed.records.count, 1)
    }

    func test_recoverableCatalog_modelsThreeWindowScenarioWithoutDuplicateDraftRows() {
        let firstUntitled = makeDraft(
            filename: "first.txt",
            preview: "first untitled contents"
        )
        let secondUntitled = makeDraft(
            filename: "second.txt",
            preview: "second untitled contents"
        )
        let loneUntitled = makeDraft(
            filename: "lone.txt",
            preview: "one document"
        )
        let editedExisting = makeDraft(
            filename: "edited.txt",
            preview: "edited proposal",
            sourceDisplay: "Documents / proposal.md"
        )

        let twoUnsaved = makeClosedWindow(
            id: UUID(),
            tabs: [
                TabSnapshot(
                    fileBookmark: nil,
                    draftFilename: firstUntitled.recoveryFilename,
                    isPinned: false,
                    displayName: "Untitled"
                ),
                TabSnapshot(
                    fileBookmark: nil,
                    draftFilename: secondUntitled.recoveryFilename,
                    isPinned: false,
                    displayName: "Untitled 2"
                ),
            ]
        )
        let oneUnsaved = makeClosedWindow(
            id: UUID(),
            tabs: [
                TabSnapshot(
                    fileBookmark: nil,
                    draftFilename: loneUntitled.recoveryFilename,
                    isPinned: false,
                    displayName: "Untitled 3"
                ),
            ]
        )
        let cleanAndEdited = makeClosedWindow(
            id: UUID(),
            tabs: [
                TabSnapshot(
                    fileBookmark: Data([0x01]),
                    draftFilename: nil,
                    isPinned: true,
                    displayName: "reference.md"
                ),
                TabSnapshot(
                    fileBookmark: Data([0x02]),
                    draftFilename: editedExisting.recoveryFilename,
                    isPinned: false,
                    displayName: "proposal.md"
                ),
            ],
            activeIndex: 1
        )

        let catalog = RecoverableWorkCatalog(
            drafts: [
                firstUntitled,
                secondUntitled,
                loneUntitled,
                editedExisting,
            ],
            closedWindows: [
                twoUnsaved,
                oneUnsaved,
                cleanAndEdited,
            ]
        )

        XCTAssertEqual(
            Set(catalog.windows.map(\.id)),
            [twoUnsaved.id, cleanAndEdited.id]
        )
        XCTAssertEqual(catalog.drafts.count, 1)
        XCTAssertEqual(catalog.drafts.first?.draft.recoveryFilename, "lone.txt")
        XCTAssertEqual(catalog.drafts.first?.closedWindow?.id, oneUnsaved.id)
        XCTAssertTrue(catalog.invalidWindowIDs.isEmpty)
    }

    func test_recoverableCatalog_danglingWindowFallsBackToSurvivingDrafts() {
        let surviving = makeDraft(filename: "surviving.txt", preview: "still here")
        let incomplete = makeClosedWindow(
            id: UUID(),
            tabs: [
                TabSnapshot(
                    fileBookmark: nil,
                    draftFilename: surviving.recoveryFilename,
                    isPinned: false
                ),
                TabSnapshot(
                    fileBookmark: nil,
                    draftFilename: "missing.txt",
                    isPinned: false
                ),
            ]
        )

        let catalog = RecoverableWorkCatalog(
            drafts: [surviving],
            closedWindows: [incomplete]
        )

        XCTAssertTrue(catalog.windows.isEmpty)
        XCTAssertEqual(catalog.drafts.map(\.draft.recoveryFilename), ["surviving.txt"])
        XCTAssertNil(catalog.drafts.first?.closedWindow)
        XCTAssertEqual(catalog.invalidWindowIDs, [incomplete.id])
    }

    func test_recoverableCatalog_matchesScratchToItsCommittedWindowFilename() {
        let scratch = DraftRecord(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/scratch.txt"),
            modified: Date(),
            bytes: 4,
            preview: "newer",
            metadata: nil,
            origin: .localScratch,
            replacesDraftFilename: "committed.txt"
        )
        let single = makeClosedWindow(
            id: UUID(),
            tabs: [
                TabSnapshot(
                    fileBookmark: nil,
                    draftFilename: "committed.txt",
                    isPinned: false
                ),
            ]
        )

        let catalog = RecoverableWorkCatalog(
            drafts: [scratch],
            closedWindows: [single]
        )

        XCTAssertEqual(catalog.drafts.count, 1)
        XCTAssertEqual(catalog.drafts.first?.closedWindow?.id, single.id)
        XCTAssertTrue(catalog.windows.isEmpty)
    }

    func test_recoverableCatalog_prunesManifestForDraftAlreadyOpen() {
        let draft = makeDraft(filename: "open.txt", preview: "open")
        let staleWindow = makeClosedWindow(
            id: UUID(),
            tabs: [
                TabSnapshot(
                    fileBookmark: nil,
                    draftFilename: draft.recoveryFilename,
                    isPinned: false
                ),
            ]
        )

        let catalog = RecoverableWorkCatalog(
            drafts: [draft],
            closedWindows: [staleWindow],
            excludedDraftFilenames: [draft.recoveryFilename]
        )

        XCTAssertTrue(catalog.isEmpty)
        XCTAssertEqual(catalog.invalidWindowIDs, [staleWindow.id])
    }

    func test_closedWindows_pruneInvalidRecordsRemovesOnlyMetadata() throws {
        var discardedDrafts: [String] = []
        var removedTabs: [UUID] = []
        let closed = ClosedWindowsStore(
            defaults: defaults,
            discardDraft: { discardedDrafts.append($0) },
            removeClosedTab: { removedTabs.append($0) }
        )
        var record = makeRecord(sceneUUID: "dangling", launchID: "L1")
        record.tabs[0].draftFilename = "survivor.txt"
        let archived = try XCTUnwrap(closed.archive(
            record,
            closedTabRecordIDs: [UUID()]
        ))

        closed.pruneInvalidRecords([archived.id])

        XCTAssertTrue(closed.records.isEmpty)
        XCTAssertTrue(discardedDrafts.isEmpty)
        XCTAssertTrue(removedTabs.isEmpty)
    }

    // MARK: - Helpers

    private func makeDraft(
        filename: String,
        preview: String,
        sourceDisplay: String? = nil
    ) -> DraftRecord {
        DraftRecord(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/\(filename)"),
            modified: Date(),
            bytes: preview.utf8.count,
            preview: preview,
            metadata: sourceDisplay.map {
                DraftMetadata(
                    sourceBookmark: nil,
                    sourceDisplay: $0,
                    sourceEncodingRaw: String.Encoding.utf8.rawValue,
                    sourceMtime: nil,
                    sourceSize: nil
                )
            }
        )
    }

    private func makeClosedWindow(
        id: UUID,
        tabs: [TabSnapshot],
        activeIndex: Int = 0
    ) -> ClosedWindowRecord {
        ClosedWindowRecord(
            id: id,
            sessionRecord: SessionRecord(
                sceneUUID: "closed-\(id)",
                tabs: tabs,
                activeIndex: activeIndex,
                lastModified: Date(),
                launchID: "L1",
                persistentIdentifier: "pid-\(id)"
            )
        )
    }

    private func makeRecord(
        sceneUUID: String,
        launchID: String,
        tabs: Int = 1,
        lastModified: Date = Date(),
        persistentIdentifier: String? = nil
    ) -> SessionRecord {
        let snapshots = (0..<tabs).map { _ in
            TabSnapshot(fileBookmark: nil, draftFilename: nil, isPinned: false)
        }
        return SessionRecord(
            sceneUUID: sceneUUID,
            tabs: snapshots,
            activeIndex: 0,
            lastModified: lastModified,
            launchID: launchID,
            persistentIdentifier: persistentIdentifier
        )
    }
}

final class WindowKeyboardGeometryTests: XCTestCase {

    func test_dockedKeyboardReturnsOnlyItsWindowOverlap() {
        let overlap = WindowKeyboardGeometry.bottomOverlap(
            viewBounds: CGRect(x: 0, y: 0, width: 900, height: 700),
            keyboardFrame: CGRect(x: -200, y: 520, width: 1_400, height: 380)
        )

        XCTAssertEqual(overlap, 180)
    }

    func test_keyboardBelowWindowDoesNotMoveStatusBar() {
        let overlap = WindowKeyboardGeometry.bottomOverlap(
            viewBounds: CGRect(x: 0, y: 0, width: 900, height: 500),
            keyboardFrame: CGRect(x: -200, y: 520, width: 1_400, height: 380)
        )

        XCTAssertEqual(overlap, 0)
    }

    func test_floatingKeyboardDoesNotMoveFullWidthStatusBar() {
        let overlap = WindowKeyboardGeometry.bottomOverlap(
            viewBounds: CGRect(x: 0, y: 0, width: 900, height: 700),
            keyboardFrame: CGRect(x: 560, y: 430, width: 300, height: 270)
        )

        XCTAssertEqual(overlap, 0)
    }

    func test_nonBottomIntersectionDoesNotMoveStatusBar() {
        let overlap = WindowKeyboardGeometry.bottomOverlap(
            viewBounds: CGRect(x: 0, y: 0, width: 900, height: 700),
            keyboardFrame: CGRect(x: 0, y: 300, width: 900, height: 200)
        )

        XCTAssertEqual(overlap, 0)
    }
}
