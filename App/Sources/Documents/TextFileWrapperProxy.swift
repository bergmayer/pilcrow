import SwiftUI
import UniformTypeIdentifiers

/// `FileDocument` conformance required by SwiftUI's `.fileExporter`.
/// Holds a snapshot *provider* rather than eager bytes: SwiftUI
/// re-evaluates `.fileExporter(document:)` on every body render, so
/// the O(n) buffer copy + encode must wait until `fileWrapper` runs
/// at actual export time.
struct TextFileWrapperProxy: FileDocument {
    let snapshot: @Sendable () throws -> Data

    static let readableContentTypes: [UTType] = []
    static let writableContentTypes: [UTType] = PlainTextDocument.supportedWriteTypes

    init() {
        self.snapshot = { Data() }
    }

    init(snapshot: @escaping @Sendable () throws -> Data) {
        self.snapshot = snapshot
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        self.snapshot = { data }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try snapshot())
    }
}
