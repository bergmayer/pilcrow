import Foundation

private extension String {
    func padded(toLeftWidth width: Int) -> String {
        guard count < width else { return self }
        return String(repeating: " ", count: width - count) + self
    }
}

/// Pure text transformations behind the Text menu. Operate on whole input;
/// callers slice by selection.
enum Transformations {

    // MARK: - Case conversion

    /// Chicago-ish Title Case: first/last word always capitalized; articles,
    /// short prepositions, coordinating conjunctions otherwise lowercased.
    static func titleCase(_ input: String) -> String {
        guard !input.isEmpty else { return input }

        var ranges: [Range<String.Index>] = []
        input.enumerateSubstrings(
            in: input.startIndex..<input.endIndex,
            options: .byWords
        ) { _, range, _, _ in
            ranges.append(range)
        }
        guard !ranges.isEmpty else { return input }

        var result = input
        // Reverse: earlier indices stay valid as later ones are replaced.
        for (offset, range) in ranges.enumerated().reversed() {
            let word = String(input[range])
            let lower = word.lowercased()
            let isFirstOrLast = (offset == 0) || (offset == ranges.count - 1)
            let replacement: String
            if !isFirstOrLast && titleCaseLowercaseWords.contains(lower) {
                replacement = lower
            } else {
                replacement = titleCaseWord(word)
            }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    static func snakeCase(_ input: String) -> String {
        components(of: input)
            .map { $0.lowercased() }
            .joined(separator: "_")
    }

    static func kebabCase(_ input: String) -> String {
        components(of: input)
            .map { $0.lowercased() }
            .joined(separator: "-")
    }

    static func camelCase(_ input: String) -> String {
        let parts = components(of: input)
        guard let first = parts.first else { return input }
        let rest = parts.dropFirst().map(capitalizeFirst)
        return ([first.lowercased()] + rest).joined()
    }

    static func pascalCase(_ input: String) -> String {
        components(of: input).map(capitalizeFirst).joined()
    }

    // MARK: - Unicode normalization

    static func normalize(_ input: String, form: NormalizationForm) -> String {
        switch form {
        case .nfc:  return input.precomposedStringWithCanonicalMapping
        case .nfd:  return input.decomposedStringWithCanonicalMapping
        case .nfkc: return input.precomposedStringWithCompatibilityMapping
        case .nfkd: return input.decomposedStringWithCompatibilityMapping
        }
    }

    enum NormalizationForm { case nfc, nfd, nfkc, nfkd }

    // MARK: - Encoding

    /// RFC 3986 unreserved set. `.urlQueryAllowed` leaves `&` `=` `+` `?` `/`
    /// raw, which corrupts values pasted into query strings and isn't the
    /// inverse of `urlDecode`.
    private static let rfc3986Unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func urlEncode(_ input: String) -> String {
        input.addingPercentEncoding(withAllowedCharacters: rfc3986Unreserved) ?? input
    }

    static func urlDecode(_ input: String) -> String {
        input.removingPercentEncoding ?? input
    }

    static func base64Encode(_ input: String) -> String {
        guard let data = input.data(using: .utf8) else { return input }
        return data.base64EncodedString()
    }

    static func base64Decode(_ input: String) -> String {
        guard let data = Data(base64Encoded: input, options: .ignoreUnknownCharacters),
              let decoded = String(data: data, encoding: .utf8)
        else { return input }
        return decoded
    }

    // MARK: - Selection ops

    static func reverseCharacters(_ input: String) -> String {
        String(input.reversed())
    }

    // MARK: - Helpers

    /// Splits identifier-ish input on underscore / hyphen / dot / slash /
    /// space / camelCase boundaries.
    private static func components(of input: String) -> [String] {
        let separatorsReplaced = input
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "/", with: " ")

        var spaced = ""
        var previous: Character? = nil
        for character in separatorsReplaced {
            if let p = previous,
               (p.isLowercase || p.isNumber),
               character.isUppercase {
                spaced.append(" ")
            }
            spaced.append(character)
            previous = character
        }

        return spaced
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func capitalizeFirst(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst().lowercased()
    }

    /// Title Case only: any existing uppercase signals an acronym or brand
    /// ("NASA", "iCloud") that `capitalizeFirst`'s aggressive lowercasing
    /// would destroy, so only all-lowercase words get touched.
    private static func titleCaseWord(_ word: String) -> String {
        guard word == word.lowercased(), let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    /// Lowercase-unless-first-or-last word list for Title Case: articles +
    /// coordinating conjunctions + short prepositions + a few extras.
    private static let titleCaseLowercaseWords: Set<String> = [
        "a", "an", "the",
        "and", "but", "for", "nor", "or", "so", "yet",
        "as", "if", "than",
        "at", "by", "in", "of", "off", "on", "out", "per",
        "to", "up", "via", "with", "from", "into", "onto",
        "over", "down", "near", "till", "upon"
    ]

    // MARK: - Paragraph helpers

    /// Split on blank-line (whitespace-only) delimiters; chunks keep their
    /// internal breaks. Used by Add/Remove Linebreaks.
    static func splitParagraphs(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []
        // splitKeepingNewlines rather than split(whereSeparator:) — Character
        // comparison never matches the fused CRLF grapheme cluster.
        for piece in splitKeepingNewlines(text) {
            let line = splitTrailingNewline(piece).0
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current.joined(separator: "\n"))
                    current.removeAll()
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }
        return paragraphs
    }

    // MARK: - Lipsum

    /// First paragraph always opens with the canonical "Lorem ipsum dolor
    /// sit amet…" sentence; remaining sentences are randomly generated.
    static func lipsum(paragraphs n: Int, separator: String) -> String {
        guard n > 0 else { return "" }
        var rng = SystemRandomNumberGenerator()
        let paragraphs = (0..<n).map { idx -> String in
            let opener = idx == 0 ? lipsumOpener : nil
            let sentenceCount = Int.random(in: 3...6, using: &rng)
            var sentences: [String] = []
            if let opener { sentences.append(opener) }
            while sentences.count < sentenceCount {
                let len = Int.random(in: 6...18, using: &rng)
                var words: [String] = []
                for _ in 0..<len { words.append(lipsumWords.randomElement(using: &rng) ?? "lorem") }
                var s = words.joined(separator: " ")
                s = s.prefix(1).uppercased() + s.dropFirst() + "."
                sentences.append(s)
            }
            return sentences.joined(separator: " ")
        }
        return paragraphs.joined(separator: separator)
    }

    private static let lipsumOpener = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua."
    private static let lipsumWords: [String] = [
        "lorem","ipsum","dolor","sit","amet","consectetur","adipiscing","elit","sed","do",
        "eiusmod","tempor","incididunt","ut","labore","et","dolore","magna","aliqua","enim",
        "ad","minim","veniam","quis","nostrud","exercitation","ullamco","laboris","nisi","aliquip",
        "ex","ea","commodo","consequat","duis","aute","irure","reprehenderit","voluptate","velit",
        "esse","cillum","dolore","fugiat","nulla","pariatur","excepteur","sint","occaecat","cupidatat",
        "non","proident","sunt","in","culpa","officia","deserunt","mollit","anim","id","est","laborum"
    ]

    // MARK: - Line-wise prefix / suffix / numbering

    static func prefixLines(_ text: String, with prefix: String) -> String {
        mapLines(text) { prefix + $0 }
    }

    static func suffixLines(_ text: String, with suffix: String) -> String {
        mapLines(text) { $0 + suffix }
    }

    /// 1-based, right-aligned line numbers with `". "` separator.
    static func addLineNumbers(_ text: String) -> String {
        let lines = splitKeepingNewlines(text)
        let width = String(lines.count).count
        return lines.enumerated().map { (idx, line) -> String in
            let (body, sep) = splitTrailingNewline(line)
            let padded = String(idx + 1).padded(toLeftWidth: width)
            return "\(padded). \(body)\(sep)"
        }.joined()
    }

    /// Strips a leading `N. ` / `N) ` / ` N. ` prefix per line.
    static func removeLineNumbers(_ text: String) -> String {
        mapLines(text) { line in
            var i = line.startIndex
            while i < line.endIndex, line[i] == " " { i = line.index(after: i) }
            guard i < line.endIndex, line[i].isNumber else { return line }
            var j = i
            while j < line.endIndex, line[j].isNumber { j = line.index(after: j) }
            guard j < line.endIndex, line[j] == "." || line[j] == ")" else { return line }
            var k = line.index(after: j)
            while k < line.endIndex, line[k] == " " { k = line.index(after: k) }
            return String(line[k..<line.endIndex])
        }
    }

    static func removeBlankLines(_ text: String) -> String {
        splitKeepingNewlines(text)
            .filter { !splitTrailingNewline($0).0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
    }

    static func increaseQuoteLevel(_ text: String) -> String {
        mapLines(text) { "> \($0)" }
    }

    /// Strip one leading `>` (and optional space) per line.
    static func decreaseQuoteLevel(_ text: String) -> String {
        mapLines(text) { line in
            guard line.hasPrefix(">") else { return line }
            let after = line.dropFirst()
            if let first = after.first, first == " " { return String(after.dropFirst()) }
            return String(after)
        }
    }

    // MARK: - Whitespace / encoding

    /// Collapse per-line runs of space/tab to one space. Newlines and
    /// per-line leading/trailing whitespace untouched — use `trim` for that.
    static func normalizeSpaces(_ text: String) -> String {
        mapLines(text) { line in
            var out = ""
            out.reserveCapacity(line.count)
            var lastWasSpace = false
            for ch in line {
                if ch == " " || ch == "\t" {
                    if !lastWasSpace { out.append(" "); lastWasSpace = true }
                } else {
                    out.append(ch); lastWasSpace = false
                }
            }
            return out
        }
    }

    /// Tabs → `tabWidth` spaces. Naive — no column tracking; bulk-convert
    /// editors rarely do column-aware expansion either.
    static func tabsToSpaces(_ text: String, tabWidth: Int) -> String {
        guard tabWidth > 0 else { return text }
        let pad = String(repeating: " ", count: tabWidth)
        return text.replacingOccurrences(of: "\t", with: pad)
    }

    /// Leading-indent only: runs of `tabWidth` spaces become single tabs.
    /// Body spaces preserved so prose isn't mangled.
    static func spacesToTabs(_ text: String, tabWidth: Int) -> String {
        guard tabWidth > 0 else { return text }
        return mapLines(text) { line in
            var i = line.startIndex
            var leading = 0
            while i < line.endIndex, line[i] == " " {
                leading += 1
                i = line.index(after: i)
            }
            let tabs = leading / tabWidth
            let rem = leading % tabWidth
            return String(repeating: "\t", count: tabs)
                + String(repeating: " ", count: rem)
                + line[i..<line.endIndex]
        }
    }

    static func normalizeLineEndings(_ text: String, to ending: String) -> String {
        let lf = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return lf.replacingOccurrences(of: "\n", with: ending)
    }

    /// Default-options convenience kept for callers that don't surface the
    /// sheet UI.
    static func zapGremlins(_ text: String) -> String {
        zapGremlins(text, options: ZapGremlinsOptions())
    }

    static func zapGremlins(_ text: String, options: ZapGremlinsOptions) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for ch in text {
            for scalar in ch.unicodeScalars {
                if options.isGremlin(scalar) {
                    out.append(options.replacement)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// NFD-decompose, drop U+0300–U+036F combining marks, recompose.
    static func stripDiacritics(_ text: String) -> String {
        let folded = text.precomposedStringWithCanonicalMapping.decomposedStringWithCanonicalMapping
        var out = String()
        out.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars where !(0x0300...0x036F).contains(scalar.value) {
            out.unicodeScalars.append(scalar)
        }
        return out.precomposedStringWithCanonicalMapping
    }

    /// CFStringTransform Latin→ASCII, then drops anything still >= 0x80.
    static func convertToASCII(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, "Any-Latin; Latin-ASCII" as NSString, false)
        let folded = mutable as String
        return String(folded.unicodeScalars.filter { $0.value < 128 })
    }

    /// Decode `\n` `\t` `\r` `\\` `\"` `\'` `\xHH` `\uHHHH`. Unknown escapes
    /// pass through.
    static func interpretEscapeSequences(_ text: String) -> String {
        let simple: [Character: Character] = [
            "n": "\n", "t": "\t", "r": "\r", "\\": "\\",
            "\"": "\"", "'": "'", "0": "\0"
        ]
        let hexWidths: [Character: Int] = ["x": 2, "u": 4]
        var out = String()
        out.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            let next = text.index(after: i)
            if ch == "\\", next < text.endIndex {
                let escape = text[next]
                if let replacement = simple[escape] {
                    out.append(replacement)
                    i = text.index(after: next)
                    continue
                }
                if let width = hexWidths[escape],
                   let hex = takeHex(in: text, from: text.index(after: next), count: width),
                   escape != "u" || hex.0.count == width,
                   let value = UInt32(hex.0, radix: 16),
                   let scalar = Unicode.Scalar(value) {
                    out.unicodeScalars.append(scalar)
                    i = hex.1
                    continue
                }
            }
            // Unknown, incomplete, and invalid scalar escapes stay literal.
            out.append(ch)
            i = next
        }
        return out
    }

    /// Inverse of `interpretEscapeSequences` for `\n` `\t` `\r` `\\` only.
    static func escapeSpecialCharacters(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        // Scalars, not Characters: the fused CRLF grapheme cluster matches
        // neither "\r" nor "\n" and would pass through raw.
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": out.append("\\n")
            case "\t": out.append("\\t")
            case "\r": out.append("\\r")
            case "\\": out.append("\\\\")
            default:   out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Straight → curly. Opening vs closing picked from prior char:
    /// whitespace/start → opening, otherwise closing.
    static func educateQuotes(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for ch in text {
            // Context comes from the output, not the source: a just-educated
            // opening “ / ‘ must count as opening context or nested quotes
            // ("'nested'") come out closing.
            let prev: Character? = out.last
            let openingContext = (prev == nil) || prev!.isWhitespace || "([{<«—–-“‘".contains(prev!)
            switch ch {
            case "\"":
                out.append(openingContext ? "\u{201C}" : "\u{201D}")
            case "'":
                out.append(openingContext ? "\u{2018}" : "\u{2019}")
            default:
                out.append(ch)
            }
        }
        return out
    }

    static func straightenQuotes(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}": out.append("'")
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}": out.append("\"")
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - Helpers (line-wise)

    private static func mapLines(_ text: String, _ f: (String) -> String) -> String {
        splitKeepingNewlines(text).map { piece -> String in
            let (body, nl) = splitTrailingNewline(piece)
            return f(body) + nl
        }.joined()
    }

    /// Pieces are one line each **including the trailing line break**.
    /// Final piece carries no break if the source ends mid-line.
    ///
    /// Operates on Unicode scalars rather than `Character` because Swift
    /// treats `\r\n` as a single extended grapheme cluster — iterating
    /// by `Character` never matches `"\r"` or `"\n"` once the platform
    /// has combined them, and CRLF-ended files would silently come out
    /// as one giant line.
    private static func splitKeepingNewlines(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s == "\r" {
                current.unicodeScalars.append(s)
                if i + 1 < scalars.count, scalars[i + 1] == "\n" {
                    current.unicodeScalars.append(scalars[i + 1])
                    i += 2
                } else {
                    i += 1
                }
                pieces.append(current); current.removeAll(keepingCapacity: true)
            } else if s == "\n" {
                current.unicodeScalars.append(s)
                pieces.append(current); current.removeAll(keepingCapacity: true)
                i += 1
            } else {
                current.unicodeScalars.append(s)
                i += 1
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// "\r\n" is one extended grapheme cluster in Swift, so dropLast()
    /// (count 1) is correct for it — `dropLast(2)` would over-drop into
    /// the preceding character.
    private static func splitTrailingNewline(_ piece: String) -> (String, String) {
        if piece.hasSuffix("\r\n") { return (String(piece.dropLast()), "\r\n") }
        if piece.hasSuffix("\n")   { return (String(piece.dropLast()), "\n") }
        if piece.hasSuffix("\r")   { return (String(piece.dropLast()), "\r") }
        return (piece, "")
    }

    /// Returns substring + the index just past last digit, or nil if none.
    private static func takeHex(in text: String, from start: String.Index, count: Int) -> (String, String.Index)? {
        var i = start
        var consumed = 0
        var out = ""
        while consumed < count, i < text.endIndex, text[i].isHexDigit {
            out.append(text[i])
            i = text.index(after: i)
            consumed += 1
        }
        return out.isEmpty ? nil : (out, i)
    }

    /// Greedy word-wrap to `column`. Existing whitespace normalised to one
    /// space first so prior hard wraps don't survive; words longer than
    /// `column` land on their own line.
    static func wordWrap(_ paragraph: String, to column: Int, separator: String) -> String {
        let words = paragraph
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return "" }
        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= column {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: separator)
    }
}

/// Character categories and replacement text for Zap Gremlins.
struct ZapGremlinsOptions: Equatable {
    /// C0 (0x00–0x1F except TAB/LF/CR), DEL (0x7F), and C1 (0x80–0x9F).
    var asciiControl: Bool = true
    /// ZWJ/ZWNJ, BOM, word joiner, language tags, etc.
    var invisibleUnicode: Bool = true
    /// Anything with scalar value > 0x7F.
    var nonAscii: Bool = false
    /// Empty = delete the gremlin outright.
    var replacement: String = ""

    func isGremlin(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if asciiControl {
            if v < 0x20, v != 0x09, v != 0x0A, v != 0x0D { return true }
            if v == 0x7F { return true }
            if (0x80...0x9F).contains(v) { return true }
        }
        if invisibleUnicode {
            if (0x200B...0x200F).contains(v) { return true }
            if v == 0xFEFF { return true }
            if (0x2060...0x206F).contains(v) { return true }
        }
        if nonAscii, v > 0x7F { return true }
        return false
    }
}
