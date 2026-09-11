import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// One preview owns one source document, even when another editor gains focus.
struct MarkdownPreviewContent: View {
    let document: PlainTextDocument
    var onDone: (() -> Void)?
    @State private var html = ""
    @State private var export: HTMLExport?
    @State private var error: String?
    @State private var reloadID = 0

    private struct Source: Equatable, Sendable {
        let text: String
        let title: String
    }

    private var source: Source {
        Source(text: document.text, title: document.fileURL?.deletingPathExtension().lastPathComponent ?? document.displayName)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error {
                    HStack {
                        Text(error).font(.callout)
                        Button("Reload") { self.error = nil; reloadID += 1 }
                    }
                    .padding()
                }
                MarkdownWebView(html: html, onFailure: { error = $0 })
                    .id(reloadID)
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(source.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onDone {
                    ToolbarItem(placement: .topBarLeading) { Button("Done", action: onDone).bold() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let export {
                        ShareLink(item: export, preview: SharePreview(export.title))
                    }
                }
            }
        }
        .task(id: source) {
            let captured = source
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let rendered = MarkdownRenderer.html(for: captured.text, title: captured.title)
                try Task.checkCancellation()
                return HTMLExport(html: rendered, title: captured.title)
            }
            do {
                let rendered = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                html = rendered.html
                export = rendered
                error = nil
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// Sharing transfers immutable data; previews never collide in a temporary file.
struct HTMLExport: Transferable, Sendable {
    let html: String
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .html) { Data($0.html.utf8) }
            .suggestedFileName { $0.title + ".html" }
    }
}

struct MarkdownPreviewScene: View {
    let tabID: UUID?
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var document: PlainTextDocument?

    var body: some View {
        Group {
            if let document {
                MarkdownPreviewContent(document: document, onDone: { dismissWindow() })
            } else {
                ContentUnavailableView("Source document unavailable", systemImage: "doc",
                    description: Text("Open a document and choose Markdown Preview again."))
            }
        }
        .onAppear {
            guard document == nil, let tabID else { return }
            document = AppStateBus.shared.scenes.session(containing: tabID)?
                .tabs.first { $0.id == tabID }?.document
        }
    }
}

struct MarkdownPreviewSheet: View {
    let document: PlainTextDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MarkdownPreviewContent(document: document, onDone: { dismiss() })
    }
}

private struct MarkdownWebView: UIViewRepresentable {
    let html: String
    let onFailure: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        view.scrollView.backgroundColor = .systemBackground
        view.navigationDelegate = context.coordinator
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?
        var position = CGPoint.zero
        var zoomScale: CGFloat = 1
        let onFailure: (String) -> Void

        init(onFailure: @escaping (String) -> Void) { self.onFailure = onFailure }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.setZoomScale(zoomScale, animated: false)
            let maximum = max(0, webView.scrollView.contentSize.height - webView.scrollView.bounds.height)
            webView.scrollView.setContentOffset(CGPoint(x: position.x, y: min(position.y, maximum)), animated: false)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            onFailure("Couldn't render preview: " + error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            self.webView(webView, didFail: navigation, withError: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onFailure("The preview stopped rendering. Reload to continue.")
        }
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard html != context.coordinator.lastHTML else { return }
        context.coordinator.lastHTML = html
        context.coordinator.position = view.scrollView.contentOffset
        context.coordinator.zoomScale = view.scrollView.zoomScale
        view.loadHTMLString(html, baseURL: nil)
    }
}

// MARK: - Renderer

/// Wraps the rendered body in a self-contained HTML document.
/// `color-scheme: light dark` tracks the system tonality.
enum MarkdownRenderer {

    static func html(for source: String, title: String) -> String {
        let body = SwiftMarkdown.render(source)
        let titleEscaped = htmlEscape(title)
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(titleEscaped)</title>
        <style>
        :root { color-scheme: light dark; }
        body {
          font: 16px/1.55 -apple-system, system-ui, sans-serif;
          margin: 0 auto;
          padding: 24px 32px 64px;
          max-width: 760px;
          color: -apple-system-label;
          background: -apple-system-background;
        }
        h1, h2, h3, h4, h5, h6 {
          font-weight: 600;
          margin: 1.6em 0 0.6em;
          line-height: 1.25;
        }
        h1 { font-size: 2em; border-bottom: 1px solid rgba(127,127,127,0.3); padding-bottom: 0.3em; }
        h2 { font-size: 1.5em; border-bottom: 1px solid rgba(127,127,127,0.2); padding-bottom: 0.2em; }
        h3 { font-size: 1.25em; }
        p  { margin: 0.8em 0; }
        a  { color: #0a84ff; text-decoration: none; }
        a:hover { text-decoration: underline; }
        code {
          font: 0.92em SF Mono, Menlo, monospace;
          background: rgba(127,127,127,0.18);
          padding: 0.12em 0.35em;
          border-radius: 4px;
        }
        pre {
          background: rgba(127,127,127,0.12);
          border-radius: 8px;
          padding: 14px 16px;
          overflow: auto;
        }
        pre code { background: transparent; padding: 0; font-size: 0.92em; }
        blockquote {
          border-left: 4px solid rgba(127,127,127,0.4);
          margin: 1em 0;
          padding: 0.1em 1em;
          color: rgba(127,127,127,1);
        }
        hr { border: none; border-top: 1px solid rgba(127,127,127,0.3); margin: 2em 0; }
        ul, ol { padding-left: 1.4em; }
        sup a { font-size: 0.75em; }
        .footnotes { font-size: 0.92em; border-top: 1px solid rgba(127,127,127,0.3); margin-top: 3em; padding-top: 1em; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func htmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - SwiftMarkdown

/// Covers the casual subset: ATX and single-line Setext headers, bold / italic / strike /
/// code, fenced + indented blocks, ordered/unordered lists,
/// blockquotes, HRs, inline links/images, hard breaks, and GFM
/// footnotes. NOT CommonMark — no tables, nested-list rules, HTML
/// inlining, or reference-style links. Good enough for live preview.
enum SwiftMarkdown {

    static func render(_ source: String) -> String {
        var parser = Parser(lines: OutlineBuilder.lines(in: source))
        parser.parse()
        return parser.html
    }

    fileprivate struct Footnote {
        var id: String
        var body: String
    }

    fileprivate struct Parser {
        var lines: [String]
        var html: String = ""
        var footnotes: [Footnote] = []
        private var index = 0

        init(lines: [String]) {
            self.lines = lines
        }

        mutating func parse() {
            extractFootnotes()
            parseBlocks()

            if !footnotes.isEmpty {
                appendFootnotes()
            }
        }

        /// Pull definitions out before parsing the document body so references
        /// can resolve regardless of where their definitions appear.
        private mutating func extractFootnotes() {
            // Pass 1: lift footnote definitions out so pass 2 can
            // wire references to them and they don't leak inline.
            var bodyLines: [String] = []
            var i = 0
            var fence: OutlineBuilder.Fence?
            while i < lines.count, !Task.isCancelled {
                let line = lines[i]
                if let open = fence {
                    if open.closes(line) { fence = nil }
                    bodyLines.append(line)
                    i += 1
                    continue
                }
                if let opening = OutlineBuilder.Fence(line) {
                    fence = opening
                    bodyLines.append(line)
                    i += 1
                    continue
                }
                if let defMatch = footnoteDefinitionMatch(line) {
                    var collected = defMatch.body
                    // Continuation lines: indented 4+ spaces or tab.
                    var j = i + 1
                    while j < lines.count {
                        let next = lines[j]
                        if next.hasPrefix("    ") || next.hasPrefix("\t") {
                            let trimmed = next.drop(while: { $0 == " " || $0 == "\t" })
                            collected += "\n" + String(trimmed)
                            j += 1
                        } else if next.trimmingCharacters(in: .whitespaces).isEmpty {
                            j += 1
                        } else { break }
                    }
                    footnotes.append(Footnote(id: defMatch.id, body: collected))
                    i = j
                    continue
                }
                bodyLines.append(line)
                i += 1
            }
            lines = bodyLines
            index = 0
        }

        private mutating func parseBlocks() {
            while index < lines.count, !Task.isCancelled {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                    continue
                }
                consumeBlock(startingWith: line)
            }
        }

        private mutating func consumeBlock(startingWith line: String) {
            if let fence = OutlineBuilder.Fence(line) {
                consumeFencedCodeBlock(fence: fence)
            } else if let header = OutlineBuilder.heading(line, next: lines.indices.contains(index + 1) ? lines[index + 1] : nil) {
                html += "<h\(header.level)>\(inline(header.text))</h\(header.level)>\n"
                index += header.lines
            } else if isHorizontalRule(line) {
                html += "<hr>\n"
                index += 1
            } else if line.hasPrefix("> ") || line == ">" {
                consumeBlockquote()
            } else if isUnorderedListItem(line) {
                consumeList(ordered: false)
            } else if isOrderedListItem(line) {
                consumeList(ordered: true)
            } else if line.hasPrefix("    ") || line.hasPrefix("\t") {
                consumeIndentedCodeBlock()
            } else {
                consumeParagraph()
            }
        }

        // MARK: Block helpers

        private mutating func consumeFencedCodeBlock(fence: OutlineBuilder.Fence) {
            index += 1
            var code = ""
            while index < lines.count, !Task.isCancelled, !fence.closes(lines[index]) {
                code += htmlEscape(lines[index]) + "\n"
                index += 1
            }
            if index < lines.count { index += 1 }  // skip closing fence
            html += "<pre><code>\(code)</code></pre>\n"
        }

        private mutating func consumeIndentedCodeBlock() {
            var code = ""
            while index < lines.count,
                  (lines[index].hasPrefix("    ") || lines[index].hasPrefix("\t")) {
                let trimmed = lines[index].hasPrefix("\t")
                    ? String(lines[index].dropFirst())
                    : String(lines[index].dropFirst(4))
                code += htmlEscape(trimmed) + "\n"
                index += 1
            }
            html += "<pre><code>\(code)</code></pre>\n"
        }

        private mutating func consumeBlockquote() {
            var inner = ""
            while index < lines.count, !Task.isCancelled {
                let line = lines[index]
                if line.hasPrefix("> ") {
                    inner += inline(String(line.dropFirst(2))) + "<br>\n"
                    index += 1
                } else if line == ">" {
                    inner += "<br>\n"
                    index += 1
                } else { break }
            }
            html += "<blockquote>\(inner)</blockquote>\n"
        }

        private mutating func consumeList(ordered: Bool) {
            let tag = ordered ? "ol" : "ul"
            html += "<\(tag)>\n"
            while index < lines.count, !Task.isCancelled {
                let line = lines[index]
                if ordered ? isOrderedListItem(line) : isUnorderedListItem(line) {
                    html += "<li>\(inline(stripListMarker(line)))</li>\n"
                    index += 1
                } else { break }
            }
            html += "</\(tag)>\n"
        }

        private mutating func consumeParagraph() {
            var paragraph: [String] = []
            while index < lines.count, !Task.isCancelled {
                let line = lines[index]
                let next = lines.indices.contains(index + 1) ? lines[index + 1] : nil
                if beginsBlock(line) || OutlineBuilder.heading(line, next: next) != nil { break }
                paragraph.append(line)
                index += 1
            }
            html += "<p>\(inline(paragraph.joined(separator: " ")))</p>\n"
        }

        private func beginsBlock(_ line: String) -> Bool {
            line.trimmingCharacters(in: .whitespaces).isEmpty
                || isHorizontalRule(line)
                || OutlineBuilder.heading(line) != nil
                || line.hasPrefix("> ")
                || line == ">"
                || isUnorderedListItem(line)
                || isOrderedListItem(line)
                || OutlineBuilder.Fence(line) != nil
        }

        private mutating func appendFootnotes() {
            html += "<div class=\"footnotes\"><hr><ol>\n"
            for footnote in footnotes {
                let safeID = htmlEscape(footnote.id)
                html += "<li id=\"fn-\(safeID)\">\(inline(footnote.body)) <a href=\"#fnref-\(safeID)\">↩</a></li>\n"
            }
            html += "</ol></div>\n"
        }

        // MARK: Block detection

        private func isHorizontalRule(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3 else { return false }
            let first = trimmed.first!
            guard first == "-" || first == "*" || first == "_" else { return false }
            return trimmed.allSatisfy { $0 == first || $0 == " " }
        }

        private func isUnorderedListItem(_ line: String) -> Bool {
            let trimmed = line.drop(while: { $0 == " " })
            guard let first = trimmed.first else { return false }
            guard first == "-" || first == "*" || first == "+" else { return false }
            return trimmed.dropFirst().first == " "
        }

        private func isOrderedListItem(_ line: String) -> Bool {
            let trimmed = line.drop(while: { $0 == " " })
            var digits = 0
            for ch in trimmed {
                if ch.isASCII && ch.isNumber { digits += 1 } else { break }
            }
            guard digits > 0 else { return false }
            let rest = trimmed.dropFirst(digits)
            guard let dot = rest.first, dot == "." || dot == ")" else { return false }
            return rest.dropFirst().first == " "
        }

        private func stripListMarker(_ line: String) -> String {
            let trimmed = line.drop(while: { $0 == " " })
            // unordered: marker is 1 char
            if let first = trimmed.first, first == "-" || first == "*" || first == "+" {
                return String(trimmed.dropFirst(2))
            }
            // ordered: digits + . + space
            let rest = trimmed.drop(while: { $0.isASCII && $0.isNumber })
            return String(rest.dropFirst(2))
        }

        // MARK: Footnote definition

        private func footnoteDefinitionMatch(_ line: String) -> (id: String, body: String)? {
            guard line.hasPrefix("[^") else { return nil }
            // [^id]: body
            guard let closeBracket = line.range(of: "]:") else { return nil }
            let id = String(line[line.index(line.startIndex, offsetBy: 2)..<closeBracket.lowerBound])
            let body = String(line[closeBracket.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (id, body)
        }

        // MARK: Inline

        private func inline(_ source: String) -> String {
            // Safe to escape first — we only escape `<>&"`, and
            // markdown markers don't overlap.
            var text = htmlEscape(source)
            // Image before link: `![…](…)` contains the link pattern.
            text = applyPattern(text, pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) { groups in
                "<img alt=\"\(groups[1])\" src=\"\(groups[2])\">"
            }
            text = applyPattern(text, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) { groups in
                "<a href=\"\(groups[2])\">\(groups[1])</a>"
            }
            // After links — `[^id]` lacks the `(` the link pattern
            // requires, so order matters.
            text = applyPattern(text, pattern: #"\[\^([^\]]+)\]"#) { groups in
                let safe = htmlEscape(groups[1])
                return "<sup id=\"fnref-\(safe)\"><a href=\"#fn-\(safe)\">\(safe)</a></sup>"
            }
            // Longer marker first so `**bold**` doesn't get chewed
            // by the `*italic*` pattern.
            text = applyPattern(text, pattern: #"\*\*([^*]+)\*\*"#) { "<strong>\($0[1])</strong>" }
            text = applyPattern(text, pattern: #"__([^_]+)__"#)     { "<strong>\($0[1])</strong>" }
            text = applyPattern(text, pattern: #"\*([^*]+)\*"#)     { "<em>\($0[1])</em>" }
            text = applyPattern(text, pattern: #"(?<!\w)_([^_]+)_(?!\w)"#) { "<em>\($0[1])</em>" }
            text = applyPattern(text, pattern: #"~~([^~]+)~~"#)     { "<del>\($0[1])</del>" }
            text = applyPattern(text, pattern: #"`([^`]+)`"#)       { "<code>\($0[1])</code>" }
            return text
        }

        private func applyPattern(_ source: String,
                                   pattern: String,
                                   replacement: ([String]) -> String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
            let nsSource = source as NSString
            let matches = regex.matches(in: source,
                                        range: NSRange(location: 0, length: nsSource.length))
            // Apply bottom-up so earlier match offsets stay valid.
            var result = source
            for match in matches.reversed() {
                var groups: [String] = []
                for g in 0..<match.numberOfRanges {
                    let r = match.range(at: g)
                    groups.append(r.location == NSNotFound ? "" : nsSource.substring(with: r))
                }
                let rangeInResult = Range(match.range, in: result)!
                result.replaceSubrange(rangeInResult, with: replacement(groups))
            }
            return result
        }

        private func htmlEscape(_ string: String) -> String {
            string
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
    }
}
