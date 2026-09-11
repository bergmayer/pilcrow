import SwiftUI
import UniformTypeIdentifiers

/// Immutable, prepared bytes for one native Save As presentation.
struct TextFileWrapperProxy: FileDocument {
    let data: Data

    static let readableContentTypes: [UTType] = []
    // Bytes are already encoded. A concrete text UTI makes the native
    // exporter append its preferred extension (e.g. .md.txt).
    static let writableContentTypes: [UTType] = [.data]

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
