import XCTest
@testable import Writad

@MainActor
final class RevisionStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RevisionStore!
    private let key = "test-key"

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("writad-revisions-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RevisionStore(
            supportDirOverride: tempRoot,
            maxRevisions: 5,             // small cap so tests stay fast
            autoCoalesceWindow: 60
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        store = nil
        tempRoot = nil
        try await super.tearDown()
    }

    // MARK: - original anchor

    func test_recordOriginalIfNeeded_writesOriginalOnce() async throws {
        let recorded = try await store.recordOriginalIfNeeded("v0", forKey: key)
        let first = try XCTUnwrap(recorded)
        XCTAssertEqual(first.kind, .original)
        let second = try await store.recordOriginalIfNeeded("v0-again", forKey: key)
        XCTAssertNil(second, "Subsequent calls return nil — original is sticky")
        let originals = await store.entries(forKey: key).filter { $0.kind == .original }
        XCTAssertEqual(originals.count, 1)
        let originalText = await store.loadText(of: originals[0], forKey: key)
        XCTAssertEqual(originalText, "v0")
    }

    // MARK: - kinds + coalescing

    func test_recordRevision_manualNeverCoalesces() async throws {
        _ = try await store.recordOriginalIfNeeded("v0", forKey: key)
        _ = try await store.recordRevision("v1", kind: .manual, forKey: key)
        _ = try await store.recordRevision("v2", kind: .manual, forKey: key)
        let manuals = await store.entries(forKey: key).filter { $0.kind == .manual }
        XCTAssertEqual(manuals.count, 2)
        let firstText = await store.loadText(of: manuals[0], forKey: key)
        let secondText = await store.loadText(of: manuals[1], forKey: key)
        XCTAssertEqual(firstText, "v1")
        XCTAssertEqual(secondText, "v2")
    }

    func test_recordRevision_consecutiveAutosCoalesce() async throws {
        _ = try await store.recordOriginalIfNeeded("v0", forKey: key)
        _ = try await store.recordRevision("a1", kind: .auto, forKey: key)
        _ = try await store.recordRevision("a2", kind: .auto, forKey: key)
        _ = try await store.recordRevision("a3", kind: .auto, forKey: key)
        let autos = await store.entries(forKey: key).filter { $0.kind == .auto }
        XCTAssertEqual(autos.count, 1, "Consecutive autos within window collapse onto one entry")
        let autoText = await store.loadText(of: autos[0], forKey: key)
        XCTAssertEqual(autoText, "a3")
    }

    func test_recordRevision_manualBreaksAutoCoalesceChain() async throws {
        _ = try await store.recordOriginalIfNeeded("v0", forKey: key)
        _ = try await store.recordRevision("a1", kind: .auto, forKey: key)
        _ = try await store.recordRevision("m1", kind: .manual, forKey: key)
        _ = try await store.recordRevision("a2", kind: .auto, forKey: key)
        let kinds = await store.entries(forKey: key).map(\.kind)
        XCTAssertEqual(kinds, [.original, .auto, .manual, .auto])
    }

    func test_recordRevision_autoOutsideWindowDoesNotCoalesce() async throws {
        // 0-second coalesce window guarantees every auto adds a fresh entry.
        let strict = RevisionStore(
            supportDirOverride: tempRoot,
            maxRevisions: 10,
            autoCoalesceWindow: 0
        )
        _ = try await strict.recordOriginalIfNeeded("v0", forKey: key)
        _ = try await strict.recordRevision("a1", kind: .auto, forKey: key)
        _ = try await strict.recordRevision("a2", kind: .auto, forKey: key)
        let autos = await strict.entries(forKey: key).filter { $0.kind == .auto }
        XCTAssertEqual(autos.count, 2)
    }

    // MARK: - cap

    func test_evict_keepsOriginalAndDropsOldestNonOriginal() async throws {
        // maxRevisions is 5 (non-original cap). Write 7 manuals.
        _ = try await store.recordOriginalIfNeeded("v0", forKey: key)
        for i in 1...7 {
            _ = try await store.recordRevision("v\(i)", kind: .manual, forKey: key)
        }
        let all = await store.entries(forKey: key)
        XCTAssertEqual(all.filter { $0.kind == .original }.count, 1,
                       "Original survives every eviction pass")
        let manuals = all.filter { $0.kind == .manual }
        XCTAssertEqual(manuals.count, 5)
        // The two oldest manuals (v1, v2) should be the ones evicted.
        let previews = manuals.map(\.preview)
        XCTAssertFalse(previews.contains("v1"))
        XCTAssertFalse(previews.contains("v2"))
        XCTAssertTrue(previews.contains("v7"))
    }

    func test_clearAll_removesEveryEntryForKey() async throws {
        _ = try await store.recordOriginalIfNeeded("v0", forKey: key)
        _ = try await store.recordRevision("v1", kind: .manual, forKey: key)
        await store.clearAll(forKey: key)
        let remaining = await store.entries(forKey: key)
        XCTAssertTrue(remaining.isEmpty)
    }

    func test_snapshotAboveByteLimit_isSkipped() async throws {
        let bounded = RevisionStore(
            supportDirOverride: tempRoot,
            maxRevisions: 10,
            autoCoalesceWindow: 0,
            maxSnapshotBytes: 4,
            maxBytesPerDocument: 100,
            maxTotalBytes: 1_000
        )
        let entry = try await bounded.recordRevision(
            "12345",
            kind: .manual,
            forKey: "oversized"
        )
        XCTAssertNil(entry)
        let entries = await bounded.entries(forKey: "oversized")
        XCTAssertTrue(entries.isEmpty)
    }

    func test_perDocumentByteLimit_evictsOldestNonOriginal() async throws {
        let bounded = RevisionStore(
            supportDirOverride: tempRoot,
            maxRevisions: 10,
            autoCoalesceWindow: 0,
            maxSnapshotBytes: 100,
            maxBytesPerDocument: 6,
            maxTotalBytes: 1_000
        )
        _ = try await bounded.recordOriginalIfNeeded("o", forKey: "bounded")
        _ = try await bounded.recordRevision("1111", kind: .manual, forKey: "bounded")
        _ = try await bounded.recordRevision("2222", kind: .manual, forKey: "bounded")

        let entries = await bounded.entries(forKey: "bounded")
        XCTAssertEqual(entries.map(\.kind), [.original, .manual])
        let newest = await bounded.loadText(of: entries[1], forKey: "bounded")
        XCTAssertEqual(newest, "2222")
    }

    func test_globalByteLimit_evictsOldestNonOriginalAcrossDocuments() async throws {
        let bounded = RevisionStore(
            supportDirOverride: tempRoot,
            maxRevisions: 10,
            autoCoalesceWindow: 0,
            maxSnapshotBytes: 100,
            maxBytesPerDocument: 100,
            maxTotalBytes: 6
        )
        _ = try await bounded.recordOriginalIfNeeded("a", forKey: "global-a")
        _ = try await bounded.recordRevision("1111", kind: .manual, forKey: "global-a")
        _ = try await bounded.recordOriginalIfNeeded("b", forKey: "global-b")
        _ = try await bounded.recordRevision("2222", kind: .manual, forKey: "global-b")

        let first = await bounded.entries(forKey: "global-a")
        let second = await bounded.entries(forKey: "global-b")
        XCTAssertEqual(first.map(\.kind), [.original])
        XCTAssertEqual(second.map(\.kind), [.original, .manual])
    }

    // MARK: - keys

    func test_key_forURL_isStableAcrossEqualPaths() {
        let a = URL(fileURLWithPath: "/tmp/foo/bar.txt")
        let b = URL(fileURLWithPath: "/tmp/foo/./bar.txt").standardizedFileURL
        XCTAssertEqual(RevisionStore.key(for: a), RevisionStore.key(for: b))
    }

    func test_key_forURL_differsByPath() {
        XCTAssertNotEqual(
            RevisionStore.key(for: URL(fileURLWithPath: "/tmp/foo.txt")),
            RevisionStore.key(for: URL(fileURLWithPath: "/tmp/bar.txt"))
        )
    }

    func test_keyForUntitledTab_distinctPerUUID() {
        let a = RevisionStore.keyForUntitledTab(UUID())
        let b = RevisionStore.keyForUntitledTab(UUID())
        XCTAssertNotEqual(a, b)
    }

    // MARK: - missing snapshot

    func test_loadText_returnsNilIfSnapshotFileGone() async throws {
        _ = try await store.recordOriginalIfNeeded("v0", forKey: key)
        let entries = await store.entries(forKey: key)
        let entry = try XCTUnwrap(entries.first)
        // Manually delete the snapshot file to simulate disk corruption.
        let snapshotURL = tempRoot
            .appendingPathComponent("Revisions")
            .appendingPathComponent(key)
            .appendingPathComponent("\(entry.index).bin")
        try FileManager.default.removeItem(at: snapshotURL)
        let missing = await store.loadText(of: entry, forKey: key)
        XCTAssertNil(missing)
    }

    // MARK: - manifest persistence

    func test_manifest_survivesAcrossStoreInstances() async throws {
        _ = try await store.recordOriginalIfNeeded("v0", forKey: key)
        _ = try await store.recordRevision("v1", kind: .manual, forKey: key)
        let fresh = RevisionStore(
            supportDirOverride: tempRoot,
            maxRevisions: 5,
            autoCoalesceWindow: 60
        )
        let entries = await fresh.entries(forKey: key)
        XCTAssertEqual(entries.map(\.kind), [.original, .manual])
        let restored = await fresh.loadText(of: entries[1], forKey: key)
        XCTAssertEqual(restored, "v1")
    }
}
