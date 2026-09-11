import WebKit

/// The user script runs in a Web Worker, outside both the app's main thread and
/// the page that owns its deadline. terminate() stops a looping worker. The
/// page has no network permission or persistent website storage.
@MainActor
final class JavaScriptWorker: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var completion: CheckedContinuation<String, any Error>?
    private var watchdog: Task<Void, Never>?
    private var code = ""
    private var input = ""
    private var limit = 5.0

    func evaluate(code: String, input: String, timeout: Double = 5) async throws -> String {
        self.code = code
        self.input = input
        limit = max(0.05, timeout)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                let view = WKWebView(frame: .zero, configuration: configuration)
                webView = view
                view.navigationDelegate = self
                view.loadHTMLString(
                    """
                    <!doctype html><meta http-equiv="Content-Security-Policy"
                    content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; worker-src blob:; connect-src 'none'">
                    """, baseURL: nil)
                watchdog = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(max(10, timeout + 5))) } catch { return }
                    self?.finish(.failure(WorkerError.unavailable))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard completion != nil else { return }
        webView.callAsyncJavaScript(
            Self.workerScript,
            arguments: ["source": code, "inputText": input, "limitMilliseconds": limit * 1000],
            in: nil, in: .page
        ) { [weak self] result in
            switch result {
            case .success(let value): self?.finish(.success(value as? String ?? ""))
            case .failure(let error):
                let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                self?.finish(.failure(WorkerError.script(message ?? error.localizedDescription)))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        finish(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(WorkerError.unavailable))
    }

    private func finish(_ result: Result<String, any Error>) {
        guard let continuation = completion else { return }
        completion = nil
        watchdog?.cancel()
        watchdog = nil
        webView?.evaluateJavaScript("globalThis.cancelTransform?.()", completionHandler: nil)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation.resume(with: result)
    }

    private enum WorkerError: LocalizedError {
        case unavailable
        case script(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "The JavaScript worker stopped responding. Your document was not changed."
            case .script(let message): message
            }
        }
    }

    private static let workerScript = #"""
        return await new Promise((resolve, reject) => {
            const workerSource = `
            self.onmessage = function(event) {
                var input = event.data.input;
                var text = input;
                var output = null;
                try {
                    const last = eval(event.data.code);
                    const value = output !== null && output !== undefined ? output : last;
                    self.postMessage({output: value === null || value === undefined ? "" : String(value)});
                } catch (error) {
                    self.postMessage({error: String(error)});
                }
            };`;
            const url = URL.createObjectURL(new Blob([workerSource], {type: "text/javascript"}));
            const worker = new Worker(url);
            let timer;
            const finish = (error, output) => {
                clearTimeout(timer);
                worker.terminate();
                URL.revokeObjectURL(url);
                globalThis.cancelTransform = null;
                error ? reject(new Error(error)) : resolve(output);
            };
            globalThis.cancelTransform = () => finish("Transform cancelled.");
            worker.onmessage = event => finish(event.data.error, event.data.output);
            worker.onerror = event => finish(event.message || "JavaScript failed.");
            timer = setTimeout(() => finish("Transform exceeded its time limit. Your document was not changed."), limitMilliseconds);
            worker.postMessage({code: source, input: inputText});
        });
        """#
}
