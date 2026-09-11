import SwiftUI
import UIKit

/// Sharing captures the working buffer, including unsaved text. A file export
/// uses a temporary copy; the source document and its save baseline stay intact.
final class DocumentShare: Identifiable {
    let id = UUID()
    let item: Any
    private let directory: URL?

    init(text: String) {
        item = text
        directory = nil
    }
    init(file: URL) {
        item = file
        directory = file.deletingLastPathComponent()
    }
    deinit { if let directory { try? FileManager.default.removeItem(at: directory) } }

    nonisolated static func writeCopy(text: String, filename: String, encoding: UInt, utf8BOM: Bool) throws -> URL {
        let selectedEncoding = String.Encoding(rawValue: encoding)
        guard var data = text.data(using: selectedEncoding, allowLossyConversion: false) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        if selectedEncoding == .utf8, utf8BOM { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = URL(fileURLWithPath: filename).lastPathComponent
        let url = directory.appendingPathComponent(safeName.isEmpty ? "Untitled.txt" : safeName)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

struct DocumentShareSheet: UIViewControllerRepresentable {
    let share: DocumentShare
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [share.item], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

@MainActor
extension CommandActions {
    static func shareText() {
        guard let state, let editor = state.textView else { return }
        state.documentShare = DocumentShare(text: editor.text)
    }

    static func shareFile() {
        guard let state, let tab = session?.tabs.first(where: { $0.owns(state) }) else { return }
        let source = state.textView?.text ?? tab.document.text
        let filename =
            tab.document.fileURL?.lastPathComponent
            ?? LanguageRegistry.suggestedFilename(tab.document.displayName, language: state.languageIdentifier)
        let encoding = tab.document.fileEncoding
        Task { @MainActor [weak state] in
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    try DocumentShare.writeCopy(
                        text: source, filename: filename,
                        encoding: encoding.encoding.rawValue, utf8BOM: encoding.withUTF8BOM)
                }.value
                let share = DocumentShare(file: file)
                state?.documentShare = share
            } catch { state?.operationError = "Couldn't share the file: " + error.localizedDescription }
        }
    }

    static func printDocument() {
        guard let state, let editor = state.textView, editor.window != nil else { return }
        guard UIPrintInteractionController.isPrintingAvailable else {
            state.operationError = "Printing is unavailable on this device."
            return
        }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = session?.activeTab.document.displayName ?? "Document"
        info.outputType = .general
        controller.printInfo = info
        let formatter = UISimpleTextPrintFormatter(text: editor.text)
        formatter.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        formatter.perPageContentInsets = UIEdgeInsets(top: 36, left: 36, bottom: 36, right: 36)
        controller.printFormatter = formatter
        let presented = controller.present(
            from: CGRect(x: editor.bounds.midX, y: editor.bounds.minY, width: 1, height: 1),
            in: editor, animated: true
        ) { _, _, error in
            if let error { state.operationError = "Couldn't print: " + error.localizedDescription }
        }
        if !presented {
            state.operationError = "The print dialog couldn't be opened. Try again after closing the current dialog."
        }
    }
}
