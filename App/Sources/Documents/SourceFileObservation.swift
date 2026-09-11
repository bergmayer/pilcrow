import Foundation

/// Foundation invokes presenters on its operation queue. Only the URL and
/// registration flag are mutable here, both protected by the lock. Events cross
/// to the editor through AsyncStream; the presenter never touches UI state.
final class SourceFileObservation: NSObject, NSFilePresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL
    private var registered = true
    private let scopedURL: URL?
    let events: AsyncStream<URL>
    private let continuation: AsyncStream<URL>.Continuation
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    var presentedItemURL: URL? { lock.withLock { url } }

    init(url: URL) {
        self.url = url
        scopedURL = url.startAccessingSecurityScopedResource() ? url : nil
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
        NSFileCoordinator.addFilePresenter(self)
        continuation.yield(url)
    }

    func presentedItemDidChange() { continuation.yield(lock.withLock { url }) }

    func presentedItemDidMove(to newURL: URL) {
        lock.withLock { url = newURL }
        continuation.yield(newURL)
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping ((any Error)?) -> Void) {
        presentedItemDidChange()
        completionHandler(nil)
    }

    func stop() {
        let remove = lock.withLock {
            let old = registered
            registered = false
            return old
        }
        guard remove else { return }
        NSFileCoordinator.removeFilePresenter(self)
        continuation.finish()
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    deinit { stop() }
}

@MainActor
extension DocumentWorkflow {
    /// Read a provider snapshot before deciding whether it can replace the
    /// buffer. Typing during the read always wins over automatic refresh.
    static func refreshExternalSource(_ tab: TabModel, at url: URL) async {
        let document = tab.document
        guard document.fileURL == url, !document.isSaving, !document.isLoading else { return }
        do {
            let payload = try await PlainTextDocument.readPayload(from: url)
            try Task.checkCancellation()
            guard document.fileURL == url, !document.isSaving, !document.isLoading else { return }
            guard payload.data != document.originalData else {
                document.externalChangeMessage = nil
                return
            }
            let live = tab.state.textView?.text ?? document.text
            guard !document.isDirty, live == tab.state.savedBaselineText else {
                document.externalChangeMessage =
                    "This file changed outside Pilcrow. Your edits are preserved. Reload to use the disk version, or Save As to keep both."
                return
            }
            let layout = EditorLayoutSnapshot(tab: tab)
            document.applyPayload(payload, url: url)
            applyLoadedDocument(document, at: url, to: tab.state)
            layout.restore(to: tab)
        } catch is CancellationError {} catch {
            guard !Task.isCancelled, document.fileURL == url else { return }
            document.externalChangeMessage = "Couldn't check the source file: " + error.localizedDescription
        }
    }
}
