import XCTest
@testable import Pilcrow

@MainActor
final class DraftsStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var store: DraftsStore!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pilcrow-drafts-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        // Empty protected set keeps eviction tests hermetic — the
        // default consults the process-wide SessionsStore.shared.
        store = DraftsStore(rootOverride: tempRoot, protectedDraftFilenames: { [] })
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        store = nil
        tempRoot = nil
        try await super.tearDown()
    }

    // MARK: - save / load round-trip

    func test_save_writesFileAndShowsUpInLoadAll() async throws {
        let url = try await store.save(text: "hello", existing: nil)
        let savedText = try await DraftsStore.readText(at: url)
        XCTAssertEqual(savedText, "hello")
        let records = store.loadAll()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.preview, "hello")
        XCTAssertEqual(records.first?.bytes, 5)
    }

    func test_save_withExistingURL_overwritesSameFile() async throws {
        let first = try await store.save(text: "v1", existing: nil)
        let second = try await store.save(text: "v2", existing: first)
        XCTAssertEqual(first, second, "Should reuse the same UUID file path")
        let savedText = try await DraftsStore.readText(at: second)
        XCTAssertEqual(savedText, "v2")
        XCTAssertEqual(store.loadAll().count, 1)
    }

    func test_save_emptyTextThroughLoadAll_isFilteredOut() async throws {
        _ = try await store.save(text: "", existing: nil)
        XCTAssertEqual(store.loadAll().count, 0, "Zero-byte drafts are dropped from recovery")
    }

    func test_adoptDraft_preservesFileUntilNextCommittedDraftWrite() async throws {
        let url = try await store.save(text: "original", existing: nil)
        let draft = try XCTUnwrap(store.loadAll().first)
        let tab = TabModel()

        let staleCheck = try await EditorScene.adoptDraft(draft, into: tab, store: store)
        XCTAssertNil(staleCheck)

        XCTAssertEqual(tab.document.text, "original")
        XCTAssertTrue(tab.document.isDirty)
        XCTAssertEqual(tab.document.draftURL?.standardizedFileURL, url.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        tab.document.text = "edited"
        tab.document.draftURL = try await store.save(
            text: tab.document.text,
            existing: tab.document.draftURL
        )

        XCTAssertEqual(tab.document.draftURL?.standardizedFileURL, url.standardizedFileURL)
        let savedText = try await DraftsStore.readText(at: url)
        XCTAssertEqual(savedText, "edited")
        XCTAssertEqual(store.loadAll().count, 1)
    }

    func test_saveToRealFile_removesCheckedOutDraft() async throws {
        let draftURL = try await store.save(text: "draft body", existing: nil)
        let draft = try XCTUnwrap(store.loadAll().first)
        let tab = TabModel()

        let staleCheck = try await EditorScene.adoptDraft(draft, into: tab, store: store)
        XCTAssertNil(staleCheck)
        let savedURL = tempRoot.appendingPathComponent("saved.txt")
        try tab.document.save(to: savedURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))
        XCTAssertNil(tab.document.draftURL)
        XCTAssertEqual(try String(contentsOf: savedURL, encoding: .utf8), "draft body")
    }

    // MARK: - eviction

    func test_save_evictsOldestPastCap() async throws {
        // Write one over the cap with controlled mtimes so eviction is
        // deterministic: each gets an mtime 1s newer than the previous.
        var urls: [URL] = []
        for i in 0...DraftsStore.maxDrafts {
            let url = try await store.save(text: "draft-\(i)", existing: nil)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceReferenceDate: Double(i))],
                ofItemAtPath: url.path
            )
            urls.append(url)
        }
        let records = store.loadAll()
        XCTAssertEqual(records.count, DraftsStore.maxDrafts)
        // Oldest (urls[0]) should be the one evicted.
        XCTAssertFalse(records.contains { $0.url == urls[0] })
        XCTAssertTrue(records.contains { $0.url == urls.last })
    }

    func test_save_doesNotEvictTheFreshlyWrittenDraft() async throws {
        // Even if every existing draft has a newer mtime than the new
        // overwrite, the freshly-saved URL is exempt from eviction.
        var urls: [URL] = []
        for i in 0..<DraftsStore.maxDrafts {
            let url = try await store.save(text: "draft-\(i)", existing: nil)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceReferenceDate: Double(1000 + i))],
                ofItemAtPath: url.path
            )
            urls.append(url)
        }
        // Overwrite urls[0] with an older mtime than every sibling.
        _ = try await store.save(text: "refreshed", existing: urls[0])
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 0)],
            ofItemAtPath: urls[0].path
        )
        // Trigger another write so enforceCap runs again.
        let fresh = try await store.save(text: "newest", existing: nil)
        // Now count is one over the cap. Oldest is urls[0] but that
        // was last-written here so it should survive THAT pass; one of
        // the originals should fall out instead.
        let records = store.loadAll()
        XCTAssertEqual(records.count, DraftsStore.maxDrafts)
        XCTAssertTrue(records.contains { $0.url == fresh })
    }

    func test_save_doesNotEvictDraftsReferencedBySessions() async throws {
        // Fill the cap with oldest-first mtimes.
        var urls: [URL] = []
        for i in 0..<DraftsStore.maxDrafts {
            let url = try await store.save(text: "draft-\(i)", existing: nil)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceReferenceDate: Double(i))],
                ofItemAtPath: url.path
            )
            urls.append(url)
        }
        // A store that treats the two oldest as referenced by persisted
        // session records (same root, so it sees the same files).
        let protectedNames = Set(urls.prefix(2).map(\.lastPathComponent))
        let protecting = DraftsStore(
            rootOverride: tempRoot,
            protectedDraftFilenames: { protectedNames }
        )
        let fresh = try await protecting.save(text: "newest", existing: nil)
        let remaining = protecting.loadAll().map(\.url.lastPathComponent)
        XCTAssertEqual(remaining.count, DraftsStore.maxDrafts)
        XCTAssertTrue(remaining.contains(urls[0].lastPathComponent),
                      "Session-referenced draft must survive the cap")
        XCTAssertTrue(remaining.contains(urls[1].lastPathComponent),
                      "Session-referenced draft must survive the cap")
        XCTAssertFalse(remaining.contains(urls[2].lastPathComponent),
                       "Oldest unprotected draft is the one evicted")
        XCTAssertTrue(remaining.contains(fresh.lastPathComponent))
    }

    func test_migrationPromotesLegacyDraftToDeviceLocalDirectory() async throws {
        let localRoot = tempRoot.appendingPathComponent("local", isDirectory: true)
        let legacyRoot = tempRoot.appendingPathComponent("legacy", isDirectory: true)
        let legacyDirectory = legacyRoot.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let filename = "\(UUID().uuidString).txt"
        let legacyURL = legacyDirectory.appendingPathComponent(filename)
        try Data("legacy body".utf8).write(to: legacyURL)
        let metadata = DraftMetadata(
            sourceBookmark: nil,
            sourceDisplay: "Documents / legacy.txt",
            sourceEncodingRaw: String.Encoding.utf8.rawValue,
            sourceMtime: Date(timeIntervalSince1970: 1_700_000_000),
            sourceSize: 11
        )
        let legacySidecar = legacyURL.deletingPathExtension().appendingPathExtension("json")
        try JSONEncoder().encode(metadata).write(to: legacySidecar)

        let migrationStore = DraftsStore(
            rootOverride: localRoot,
            legacyRootOverrides: [legacyRoot],
            protectedDraftFilenames: { [] }
        )
        let discovered = try XCTUnwrap(migrationStore.loadAll().first)
        XCTAssertEqual(discovered.url.standardizedFileURL, legacyURL.standardizedFileURL)

        await migrationStore.migrateLegacyRecovery()

        let promoted = try XCTUnwrap(migrationStore.loadAll().first?.url)
        XCTAssertEqual(
            promoted.deletingLastPathComponent().standardizedFileURL,
            migrationStore.directory.standardizedFileURL
        )
        XCTAssertEqual(promoted.lastPathComponent, filename)
        let promotedText = try await DraftsStore.readText(at: promoted)
        XCTAssertEqual(promotedText, "legacy body")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacySidecar.path))
        XCTAssertEqual(migrationStore.loadAll().count, 1)

        // A launcher row loaded just before migration still carries the old
        // URL. Adoption resolves the same filename at its new local path.
        let tab = TabModel()
        _ = try await EditorScene.adoptDraft(
            discovered,
            into: tab,
            store: migrationStore
        )
        XCTAssertEqual(tab.document.text, "legacy body")
        XCTAssertEqual(
            tab.document.draftURL?.deletingLastPathComponent().standardizedFileURL,
            migrationStore.directory.standardizedFileURL
        )
    }

    // MARK: - discard

    func test_discard_removesAtomicRecoveryFile() async throws {
        let metadata = DraftMetadata(
            sourceBookmark: nil,
            sourceDisplay: "Foo › bar.txt",
            sourceEncodingRaw: String.Encoding.utf8.rawValue,
            sourceMtime: Date(timeIntervalSince1970: 1_700_000_000),
            sourceSize: 42
        )
        let url = try await store.save(text: "x", existing: nil, metadata: metadata)
        let sidecar = url.deletingPathExtension().appendingPathExtension("json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        store.discard(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertEqual(store.loadAll().count, 0)
    }

    func test_discard_nilURL_isNoOp() {
        store.discard(nil)
        XCTAssertEqual(store.loadAll().count, 0)
    }

    func test_discardScratchRowAlsoRemovesShadowedCommittedDraft() async throws {
        let committed = try await store.save(text: "older", existing: nil)
        let scratchID = UUID()
        defer { ScratchStore.discard(id: scratchID) }
        try ScratchStore.write(
            text: "newer",
            sidecar: ScratchSidecar(
                id: scratchID,
                revisionKey: "revision-\(scratchID)",
                draftFilename: committed.lastPathComponent,
                metadata: nil
            )
        )
        let scratch = try XCTUnwrap(
            ScratchStore.loadAll().first { $0.id == scratchID }
        )

        store.discard(scratch)

        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.path))
    }

    func test_save_withoutMetadata_stripsLegacySidecar() async throws {
        let metadata = DraftMetadata(
            sourceBookmark: nil,
            sourceDisplay: "Foo › bar.txt",
            sourceEncodingRaw: nil,
            sourceMtime: nil,
            sourceSize: nil
        )
        let url = try await store.save(text: "v1", existing: nil, metadata: metadata)
        let sidecar = url.deletingPathExtension().appendingPathExtension("json")
        try Data("legacy".utf8).write(to: sidecar)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        _ = try await store.save(text: "v2", existing: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path),
                       "Save without metadata must clear stale sidecar")
    }

    // MARK: - metadata round-trip

    func test_metadata_atomicFileRoundTrip() async throws {
        let metadata = DraftMetadata(
            sourceBookmark: Data([0x01, 0x02, 0x03]),
            sourceDisplay: "Documents › notes.md",
            sourceEncodingRaw: String.Encoding.utf8.rawValue,
            sourceMtime: Date(timeIntervalSince1970: 1_700_000_000),
            sourceSize: 256,
            sourceHadUTF8BOM: true
        )
        _ = try await store.save(text: "body", existing: nil, metadata: metadata)
        let record = try XCTUnwrap(store.loadAll().first)
        let decoded = try XCTUnwrap(record.metadata)
        XCTAssertEqual(decoded.sourceBookmark, metadata.sourceBookmark)
        XCTAssertEqual(decoded.sourceDisplay, metadata.sourceDisplay)
        XCTAssertEqual(decoded.sourceEncodingRaw, metadata.sourceEncodingRaw)
        XCTAssertEqual(decoded.sourceMtime, metadata.sourceMtime)
        XCTAssertEqual(decoded.sourceSize, metadata.sourceSize)
        XCTAssertEqual(decoded.sourceHadUTF8BOM, true)
    }

    func test_loadAll_sortsNewestFirst() async throws {
        let oldURL = try await store.save(text: "old", existing: nil)
        let newURL = try await store.save(text: "new", existing: nil)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 0)],
            ofItemAtPath: oldURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 1000)],
            ofItemAtPath: newURL.path
        )
        let records = store.loadAll()
        XCTAssertEqual(records.first?.url, newURL)
        XCTAssertEqual(records.last?.url, oldURL)
    }

    func test_preview_collapsesNewlinesAndIsBounded() async throws {
        let body = String(repeating: "abc\ndef\n", count: 50)
        _ = try await store.save(text: body, existing: nil)
        let preview = try XCTUnwrap(store.loadAll().first?.preview)
        XCTAssertFalse(preview.contains("\n"))
        XCTAssertLessThanOrEqual(preview.count, 80)
    }

    func test_emptyFileBackedDraft_isRecoverable() async throws {
        let metadata = DraftMetadata(
            sourceBookmark: nil,
            sourceDisplay: "Documents / emptied.txt",
            sourceEncodingRaw: String.Encoding.utf8.rawValue,
            sourceMtime: Date(),
            sourceSize: 12
        )
        _ = try await store.save(text: "", existing: nil, metadata: metadata)
        let draft = try XCTUnwrap(store.loadAll().first)
        XCTAssertEqual(draft.bytes, 0)

        let tab = TabModel()
        _ = try await EditorScene.adoptDraft(draft, into: tab, store: store)
        XCTAssertEqual(tab.document.text, "")
        XCTAssertTrue(tab.document.isDirty, "Deleting all source text is a recoverable edit")
    }

    func test_failedDraftDecode_doesNotMutateTabOrDeleteDraft() async throws {
        let url = store.directory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data([0xFF, 0xFE, 0xFF]).write(to: url)
        let draft = try XCTUnwrap(store.loadAll().first)
        let tab = TabModel()
        tab.document.text = "keep me"
        tab.state.text = "keep me"

        do {
            _ = try await EditorScene.adoptDraft(draft, into: tab, store: store)
            XCTFail("Expected invalid UTF-8 to fail recovery")
        } catch DraftRecoveryFailure.invalidUTF8 {
            // Expected.
        }

        XCTAssertEqual(tab.document.text, "keep me")
        XCTAssertEqual(tab.state.text, "keep me")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_localScratch_roundTripsExactBufferAndEmptyFileMetadata() async throws {
        let id = UUID()
        defer { ScratchStore.discard(id: id) }
        let metadata = DraftMetadata(
            sourceBookmark: nil,
            sourceDisplay: "Documents / source.txt",
            sourceEncodingRaw: String.Encoding.utf8.rawValue,
            sourceMtime: Date(),
            sourceSize: 1
        )
        let sidecar = ScratchSidecar(
            id: id,
            revisionKey: "tab-\(id.uuidString)",
            draftFilename: "existing.txt",
            metadata: metadata
        )
        let exact = "trailing spaces   \nno forced newline"
        try ScratchStore.write(text: exact, sidecar: sidecar)
        let record = try XCTUnwrap(ScratchStore.loadAll().first { $0.id == id })
        let restored = try await DraftsStore.readText(at: record.url)
        XCTAssertEqual(restored, exact)
        XCTAssertEqual(record.replacesDraftFilename, "existing.txt")

        try ScratchStore.write(text: "", sidecar: sidecar)
        let empty = try XCTUnwrap(ScratchStore.loadAll().first { $0.id == id })
        XCTAssertEqual(empty.bytes, 0)
        let emptyText = try await DraftsStore.readText(at: empty.url, allowEmpty: true)
        XCTAssertEqual(emptyText, "")
    }
}
