import XCTest
@testable import Writad

@MainActor
final class DraftsStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var store: DraftsStore!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("writad-drafts-test-\(UUID().uuidString)", isDirectory: true)
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

    func test_save_writesFileAndShowsUpInLoadAll() throws {
        let url = try XCTUnwrap(store.save(text: "hello", existing: nil))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello")
        let records = store.loadAll()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.preview, "hello")
        XCTAssertEqual(records.first?.bytes, 5)
    }

    func test_save_withExistingURL_overwritesSameFile() throws {
        let first = try XCTUnwrap(store.save(text: "v1", existing: nil))
        let second = try XCTUnwrap(store.save(text: "v2", existing: first))
        XCTAssertEqual(first, second, "Should reuse the same UUID file path")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "v2")
        XCTAssertEqual(store.loadAll().count, 1)
    }

    func test_save_emptyTextThroughLoadAll_isFilteredOut() throws {
        _ = try XCTUnwrap(store.save(text: "", existing: nil))
        XCTAssertEqual(store.loadAll().count, 0, "Zero-byte drafts are dropped from recovery")
    }

    func test_adoptDraft_preservesFileUntilNextCommittedDraftWrite() async throws {
        let url = try XCTUnwrap(store.save(text: "original", existing: nil))
        let draft = try XCTUnwrap(store.loadAll().first)
        let tab = TabModel()

        let staleCheck = try await EditorScene.adoptDraft(draft, into: tab)
        XCTAssertNil(staleCheck)

        XCTAssertEqual(tab.document.text, "original")
        XCTAssertTrue(tab.document.isDirty)
        XCTAssertEqual(tab.document.draftURL?.standardizedFileURL, url.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        tab.document.text = "edited"
        tab.document.writeDraftToSyncFolder()

        XCTAssertEqual(tab.document.draftURL?.standardizedFileURL, url.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "edited")
        XCTAssertEqual(store.loadAll().count, 1)
    }

    func test_saveToRealFile_removesCheckedOutDraft() async throws {
        let draftURL = try XCTUnwrap(store.save(text: "draft body", existing: nil))
        let draft = try XCTUnwrap(store.loadAll().first)
        let tab = TabModel()

        let staleCheck = try await EditorScene.adoptDraft(draft, into: tab)
        XCTAssertNil(staleCheck)
        let savedURL = tempRoot.appendingPathComponent("saved.txt")
        try tab.document.save(to: savedURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))
        XCTAssertNil(tab.document.draftURL)
        XCTAssertEqual(try String(contentsOf: savedURL, encoding: .utf8), "draft body")
    }

    // MARK: - eviction

    func test_save_evictsOldestPastCap() throws {
        // Cap is 6. Write 7 drafts with controlled mtimes so eviction is
        // deterministic: each gets an mtime 1s newer than the previous.
        var urls: [URL] = []
        for i in 0..<7 {
            let url = try XCTUnwrap(store.save(text: "draft-\(i)", existing: nil))
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
        XCTAssertTrue(records.contains { $0.url == urls[6] })
    }

    func test_save_doesNotEvictTheFreshlyWrittenDraft() throws {
        // Even if every existing draft has a newer mtime than the new
        // overwrite, the freshly-saved URL is exempt from eviction.
        var urls: [URL] = []
        for i in 0..<6 {
            let url = try XCTUnwrap(store.save(text: "draft-\(i)", existing: nil))
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceReferenceDate: Double(1000 + i))],
                ofItemAtPath: url.path
            )
            urls.append(url)
        }
        // Overwrite urls[0] with an older mtime than every sibling.
        _ = store.save(text: "refreshed", existing: urls[0])
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: 0)],
            ofItemAtPath: urls[0].path
        )
        // Trigger another write so enforceCap runs again.
        let fresh = try XCTUnwrap(store.save(text: "newest", existing: nil))
        // Now count is 7 → 6 cap eviction. Oldest is urls[0] but that
        // was last-written here so it should survive THAT pass; one of
        // the originals should fall out instead.
        let records = store.loadAll()
        XCTAssertEqual(records.count, DraftsStore.maxDrafts)
        XCTAssertTrue(records.contains { $0.url == fresh })
    }

    func test_save_doesNotEvictDraftsReferencedBySessions() throws {
        // Six drafts at the cap, oldest-first mtimes.
        var urls: [URL] = []
        for i in 0..<6 {
            let url = try XCTUnwrap(store.save(text: "draft-\(i)", existing: nil))
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
        let fresh = try XCTUnwrap(protecting.save(text: "newest", existing: nil))
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

    // MARK: - discard

    func test_discard_removesFileAndSidecar() throws {
        let metadata = DraftMetadata(
            sourceBookmark: nil,
            sourceDisplay: "Foo › bar.txt",
            sourceEncodingRaw: String.Encoding.utf8.rawValue,
            sourceMtime: Date(timeIntervalSince1970: 1_700_000_000),
            sourceSize: 42
        )
        let url = try XCTUnwrap(store.save(text: "x", existing: nil, metadata: metadata))
        let sidecar = url.deletingPathExtension().appendingPathExtension("json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        store.discard(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertEqual(store.loadAll().count, 0)
    }

    func test_discard_nilURL_isNoOp() {
        store.discard(nil)
        XCTAssertEqual(store.loadAll().count, 0)
    }

    func test_save_withoutMetadata_stripsStaleSidecar() throws {
        // First save WITH metadata creates a sidecar; second save to
        // the same URL WITHOUT metadata must delete it.
        let metadata = DraftMetadata(
            sourceBookmark: nil,
            sourceDisplay: "Foo › bar.txt",
            sourceEncodingRaw: nil,
            sourceMtime: nil,
            sourceSize: nil
        )
        let url = try XCTUnwrap(store.save(text: "v1", existing: nil, metadata: metadata))
        let sidecar = url.deletingPathExtension().appendingPathExtension("json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        _ = store.save(text: "v2", existing: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path),
                       "Save without metadata must clear stale sidecar")
    }

    // MARK: - metadata round-trip

    func test_metadata_sidecarRoundTrip() throws {
        let metadata = DraftMetadata(
            sourceBookmark: Data([0x01, 0x02, 0x03]),
            sourceDisplay: "Documents › notes.md",
            sourceEncodingRaw: String.Encoding.utf8.rawValue,
            sourceMtime: Date(timeIntervalSince1970: 1_700_000_000),
            sourceSize: 256,
            sourceHadUTF8BOM: true
        )
        _ = try XCTUnwrap(store.save(text: "body", existing: nil, metadata: metadata))
        let record = try XCTUnwrap(store.loadAll().first)
        let decoded = try XCTUnwrap(record.metadata)
        XCTAssertEqual(decoded.sourceBookmark, metadata.sourceBookmark)
        XCTAssertEqual(decoded.sourceDisplay, metadata.sourceDisplay)
        XCTAssertEqual(decoded.sourceEncodingRaw, metadata.sourceEncodingRaw)
        XCTAssertEqual(decoded.sourceMtime, metadata.sourceMtime)
        XCTAssertEqual(decoded.sourceSize, metadata.sourceSize)
        XCTAssertEqual(decoded.sourceHadUTF8BOM, true)
    }

    func test_loadAll_sortsNewestFirst() throws {
        let oldURL = try XCTUnwrap(store.save(text: "old", existing: nil))
        let newURL = try XCTUnwrap(store.save(text: "new", existing: nil))
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

    func test_preview_collapsesNewlinesAndIsBounded() throws {
        let body = String(repeating: "abc\ndef\n", count: 50)
        _ = try XCTUnwrap(store.save(text: body, existing: nil))
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
        _ = try XCTUnwrap(store.save(text: "", existing: nil, metadata: metadata))
        let draft = try XCTUnwrap(store.loadAll().first)
        XCTAssertEqual(draft.bytes, 0)

        let tab = TabModel()
        _ = try await EditorScene.adoptDraft(draft, into: tab)
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
            _ = try await EditorScene.adoptDraft(draft, into: tab)
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
