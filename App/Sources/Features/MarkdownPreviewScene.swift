import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// WKWebView host for the rendered markdown. iPad opens it as a
/// dedicated scene; iPhone presents it as a sheet (no second
/// window). Share → Print → "Save as PDF" is the iPad-native PDF
/// export.
struct MarkdownPreviewContent: View {

    /// Scene host passes `dismissWindow`; sheet host passes
    /// SwiftUI's `dismiss`. `nil` hides the Done button.
    var onDone: (() -> Void)?

    @State private var renderedHTML: String = ""
    /// Last rendered source — throttles re-renders while typing.
    @State private var lastSource: String = ""
    /// Scratch-sandbox `.html` for the share sheet, refreshed by
    /// `rerender()` — `ShareLink(item:)` is body-evaluated, so the
    /// file write must not happen inline there.
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            MarkdownWebView(html: renderedHTML)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let onDone {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done", action: onDone).bold()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if let exportURL {
                            ShareLink(item: exportURL,
                                      preview: SharePreview(currentTitle))
                        }
                    }
                }
        }
        .onAppear { rerender() }
        // `EditorState` is a class — its `text` mutations don't
        // drive SwiftUI, so a 600 ms timer is the cheapest hook for
        // "live" preview without thrashing the WebView mid-typing.
        .task(id: lastSource) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                rerender()
            }
        }
    }

    private func rerender() {
        let src = AppStateBus.shared.scenes.currentSession?
            .activeTab.document.text ?? ""
        guard src != lastSource else { return }
        lastSource = src
        renderedHTML = MarkdownRenderer.html(for: src, title: currentTitle)
        exportURL = writeExportFile(html: renderedHTML)
    }

    private var currentTitle: String {
        AppStateBus.shared.scenes.currentSession?
            .activeTab.document.fileURL?
            .deletingPathExtension()
            .lastPathComponent ?? "Untitled"
    }

    /// System Print → Save as PDF renders the shared `.html` to PDF.
    private func writeExportFile(html: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(currentTitle).html")
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

/// iPad host — opened via `openWindow(id: .markdownPreview)`.
struct MarkdownPreviewScene: View {

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        MarkdownPreviewContent(onDone: {
            dismissWindow(id: SceneID.markdownPreview.rawValue)
        })
        .onAppear {
            // Same restore guard the file browser uses — drop the
            // window if iPadOS restored it after a quit.
            if !AppStateBus.shared.scenes.consumeOpen(.markdownPreview) {
                dismissWindow(id: SceneID.markdownPreview.rawValue)
            }
        }
    }
}

/// iPhone host — `openWindow` is a no-op on phone, so this is a
/// `.sheet(item:)`.
struct MarkdownPreviewSheet: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MarkdownPreviewContent(onDone: { dismiss() })
    }
}

// MARK: - WebView host

private struct MarkdownWebView: UIViewRepresentable {

    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        view.scrollView.backgroundColor = .systemBackground
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Tracks the last-loaded HTML — `updateUIView` fires on every
    /// host re-render, and an unconditional reload resets scroll.
    final class Coordinator {
        var lastHTML: String?
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard html != context.coordinator.lastHTML else { return }
        context.coordinator.lastHTML = html
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

/// Covers the casual subset: ATX headers, bold / italic / strike /
/// code, fenced + indented blocks, ordered/unordered lists,
/// blockquotes, HRs, inline links/images, hard breaks, and GFM
/// footnotes. NOT CommonMark — no tables, nested-list rules, HTML
/// inlining, or reference-style links. Good enough for live preview.
enum SwiftMarkdown {

    static func render(_ source: String) -> String {
        var parser = Parser(lines: source.components(separatedBy: "\n"))
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
            while i < lines.count {
                let line = lines[i]
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
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                    continue
                }
                consumeBlock(startingWith: line)
            }
        }

        private mutating func consumeBlock(startingWith line: String) {
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                consumeFencedCodeBlock(fence: String(line.prefix(3)))
            } else if isHorizontalRule(line) {
                html += "<hr>\n"
                index += 1
            } else if let header = headerMatch(line) {
                html += "<h\(header.level)>\(inline(header.text))</h\(header.level)>\n"
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

        private mutating func consumeFencedCodeBlock(fence: String) {
            index += 1
            var code = ""
            while index < lines.count, !lines[index].hasPrefix(fence) {
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
            while index < lines.count {
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
            while index < lines.count {
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
            while index < lines.count {
                let line = lines[index]
                if beginsBlock(line) { break }
                paragraph.append(line)
                index += 1
            }
            html += "<p>\(inline(paragraph.joined(separator: " ")))</p>\n"
        }

        private func beginsBlock(_ line: String) -> Bool {
            line.trimmingCharacters(in: .whitespaces).isEmpty
                || isHorizontalRule(line)
                || headerMatch(line) != nil
                || line.hasPrefix("> ")
                || line == ">"
                || isUnorderedListItem(line)
                || isOrderedListItem(line)
                || line.hasPrefix("```")
                || line.hasPrefix("~~~")
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

        private func headerMatch(_ line: String) -> (level: Int, text: String)? {
            var hashes = 0
            for ch in line {
                if ch == "#" { hashes += 1 } else { break }
            }
            guard (1...6).contains(hashes) else { return nil }
            let afterHashes = line.dropFirst(hashes)
            guard afterHashes.first == " " else { return nil }
            return (hashes, String(afterHashes.dropFirst()))
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
