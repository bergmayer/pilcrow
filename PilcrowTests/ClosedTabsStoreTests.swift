import XCTest
@testable import Pilcrow

@MainActor
final class ClosedTabsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ClosedTabsStore!
    private var storageDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "pilcrow-closed-tabs-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pilcrow-closed-tabs-\(UUID().uuidString)", isDirectory: true)
        store = ClosedTabsStore(defaults: defaults, storageDirectory: storageDirectory)
    }

    override func tearDown() async throws {
        store.clear()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: storageDirectory)
        store = nil
        storageDirectory = nil
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - record / popFirst

    func test_record_insertsAtFront() {
        store.record(makeRecord(displayName: "alpha"))
        store.record(makeRecord(displayName: "beta"))
        XCTAssertEqual(store.records.map(\.displayName), ["beta", "alpha"])
    }

    func test_popFirst_returnsAndRemovesFrontEntry() {
        store.record(makeRecord(displayName: "alpha"))
        store.record(makeRecord(displayName: "beta"))
        let popped = store.popFirst()
        XCTAssertEqual(popped?.displayName, "beta")
        XCTAssertEqual(store.records.map(\.displayName), ["alpha"])
    }

    func test_popFirst_emptyStoreReturnsNil() {
        XCTAssertNil(store.popFirst())
    }

    // MARK: - cap

    func test_record_evictsTailPastCap() {
        for i in 0..<(ClosedTabsStore.cap + 5) {
            store.record(makeRecord(displayName: "entry-\(i)"))
        }
        XCTAssertEqual(store.records.count, ClosedTabsStore.cap)
        XCTAssertEqual(store.records.first?.displayName, "entry-\(ClosedTabsStore.cap + 4)")
    }

    // MARK: - remove / clear

    func test_remove_byID_removesEntry() {
        let a = makeRecord(displayName: "alpha")
        let b = makeRecord(displayName: "beta")
        store.record(a)
        store.record(b)
        store.remove(a.id)
        XCTAssertEqual(store.records.map(\.id), [b.id])
    }

    func test_clear_emptiesStore() {
        store.record(makeRecord(displayName: "alpha"))
        store.record(makeRecord(displayName: "beta"))
        store.clear()
        XCTAssertTrue(store.records.isEmpty)
    }

    // MARK: - persistence

    func test_persistence_recordsSurviveAcrossInstances() {
        store.record(makeRecord(displayName: "alpha"))
        store.record(makeRecord(displayName: "beta"))
        let fresh = ClosedTabsStore(defaults: defaults, storageDirectory: storageDirectory)
        XCTAssertEqual(fresh.records.map(\.displayName), ["beta", "alpha"])
    }

    func test_remove_persistsAcrossInstances() {
        let target = makeRecord(displayName: "target")
        store.record(target)
        store.record(makeRecord(displayName: "other"))
        store.remove(target.id)
        let fresh = ClosedTabsStore(defaults: defaults, storageDirectory: storageDirectory)
        XCTAssertEqual(fresh.records.map(\.displayName), ["other"])
    }

    func test_isUnsavedScratch_isTrueOnlyForDirtyUntitled() {
        let untitled = ClosedTabRecord(displayName: "Untitled", fileURL: nil, unsavedSnapshot: "x")
        let untitledEmpty = ClosedTabRecord(displayName: "Untitled", fileURL: nil, unsavedSnapshot: "")
        let savedFile = ClosedTabRecord(
            displayName: "foo.md",
            fileURL: URL(fileURLWithPath: "/tmp/foo.md"),
            unsavedSnapshot: "x"
        )
        XCTAssertTrue(untitled.isUnsavedScratch)
        XCTAssertFalse(untitledEmpty.isUnsavedScratch)
        XCTAssertFalse(savedFile.isUnsavedScratch)
    }

    func test_record_externalizesSnapshotAndKeepsDefaultsSmall() async throws {
        let body = String(repeating: "abcdefghij", count: 20_000)
        store.record(ClosedTabRecord(
            displayName: "large untitled",
            fileURL: nil,
            unsavedSnapshot: body
        ))

        let record = try XCTUnwrap(store.records.first)
        XCTAssertNotNil(record.snapshotFilename)
        let persistedMetadata = try XCTUnwrap(
            defaults.data(forKey: AppPreferenceKey.closedTabRecords)
        )
        XCTAssertLessThan(persistedMetadata.count, 4_096)
        let restored = try await store.loadSnapshot(record)
        XCTAssertEqual(restored, body)
    }

    func test_remove_deletesExternalSnapshot() throws {
        store.record(makeRecord(displayName: "temporary"))
        let record = try XCTUnwrap(store.records.first)
        let filename = try XCTUnwrap(record.snapshotFilename)
        let payload = storageDirectory.appendingPathComponent(filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))

        store.remove(record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
    }

    // MARK: - Helpers

    private func makeRecord(displayName: String) -> ClosedTabRecord {
        ClosedTabRecord(
            displayName: displayName,
            fileURL: nil,
            unsavedSnapshot: "snapshot of \(displayName)"
        )
    }
}
