import XCTest
import FileEncoding
import LineEnding
@testable import Writad

final class PlainTextDocumentEncodeTests: XCTestCase {

    // MARK: - Encoding choice

    func test_encode_utf8_noBOM_unlessOptedIn() throws {
        let data = try PlainTextDocument.encode(
            text: "hello",
            encoding: .utf8,
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(Array(data), Array("hello".utf8))
    }

    func test_encode_utf8_addsBOMWhenPrefIsOn() throws {
        let data = try PlainTextDocument.encode(
            text: "hello",
            encoding: .utf8,
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: true
        )
        let prefix = Array(data.prefix(3))
        XCTAssertEqual(prefix, [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(Array(data.dropFirst(3)), Array("hello".utf8))
    }

    func test_encode_utf8_addsBOMWhenDocumentRemembersBOM() throws {
        // Per-document toggle — the document itself remembers it had a
        // BOM at load time, so it should write one back even when the
        // global pref is off.
        let encoding = FileEncoding(encoding: .utf8, withUTF8BOM: true)
        let data = try PlainTextDocument.encode(
            text: "hello",
            encoding: encoding,
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
    }

    func test_encode_utf16LE_writesByteOrderMarkAndPairs() throws {
        let data = try PlainTextDocument.encode(
            text: "Aé",
            encoding: FileEncoding(encoding: .utf16LittleEndian, withUTF8BOM: false),
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        let decoded = String(data: data, encoding: .utf16LittleEndian)
        XCTAssertEqual(decoded, "Aé")
    }

    func test_encode_isoLatin1_handlesAccentedCharacters() throws {
        let data = try PlainTextDocument.encode(
            text: "café",
            encoding: FileEncoding(encoding: .isoLatin1, withUTF8BOM: false),
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        let decoded = String(data: data, encoding: .isoLatin1)
        XCTAssertEqual(decoded, "café")
    }

    func test_encode_throwsWhenEncodingCannotRepresentCharacter() {
        // ISO Latin 1 can't encode '日' — expect lossy failure to throw.
        XCTAssertThrowsError(
            try PlainTextDocument.encode(
                text: "日本語",
                encoding: FileEncoding(encoding: .isoLatin1, withUTF8BOM: false),
                lineEnding: .lf,
                trimTrailingWhitespace: false,
                ensureTrailingNewline: false,
                saveUTF8BOMPref: false
            )
        ) { error in
            XCTAssertEqual((error as? CocoaError)?.code, CocoaError.fileWriteInapplicableStringEncoding)
        }
    }

    // MARK: - Line endings

    func test_encode_normalizesMixedToLF() throws {
        let data = try PlainTextDocument.encode(
            text: "a\r\nb\rc\n",
            encoding: .utf8,
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "a\nb\nc\n")
    }

    func test_encode_normalizesToCRLF() throws {
        let data = try PlainTextDocument.encode(
            text: "a\nb\rc\r\nd",
            encoding: .utf8,
            lineEnding: .crlf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "a\r\nb\r\nc\r\nd")
    }

    func test_encode_normalizesToCR() throws {
        let data = try PlainTextDocument.encode(
            text: "a\nb\r\nc",
            encoding: .utf8,
            lineEnding: .cr,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "a\rb\rc")
    }

    // MARK: - Trim trailing whitespace

    func test_encode_trimsTrailingWhitespacePerLineWhenEnabled() throws {
        let data = try PlainTextDocument.encode(
            text: "alpha   \nbeta\t\ngamma\n",
            encoding: .utf8,
            lineEnding: .lf,
            trimTrailingWhitespace: true,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "alpha\nbeta\ngamma\n")
    }

    func test_encode_doesNotTrimWhenDisabled() throws {
        let data = try PlainTextDocument.encode(
            text: "alpha   \nbeta\t\n",
            encoding: .utf8,
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: false,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "alpha   \nbeta\t\n")
    }

    // MARK: - Ensure trailing newline

    func test_encode_ensuresTrailingNewlineWhenEnabled() throws {
        let data = try PlainTextDocument.encode(
            text: "alpha",
            encoding: .utf8,
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: true,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "alpha\n")
    }

    func test_encode_ensureNewline_isNoOpWhenAlreadyPresent() throws {
        let data = try PlainTextDocument.encode(
            text: "alpha\n",
            encoding: .utf8,
            lineEnding: .lf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: true,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "alpha\n")
    }

    func test_encode_ensureNewline_addsCRLFWhenLineEndingIsCRLF() throws {
        let data = try PlainTextDocument.encode(
            text: "alpha",
            encoding: .utf8,
            lineEnding: .crlf,
            trimTrailingWhitespace: false,
            ensureTrailingNewline: true,
            saveUTF8BOMPref: false
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "alpha\r\n")
    }

    // MARK: - Decode (Unicode BOMs)

    func test_decode_utf16LEWithBOM_roundTrips() throws {
        // UTF-16 data is full of NUL high bytes — the BOM must route it
        // past the binary-file heuristic into encoding detection.
        let text = "héllo wörld"
        var data = Data([0xFF, 0xFE])
        data.append(try XCTUnwrap(text.data(using: .utf16LittleEndian)))
        let payload = try PlainTextDocument.decodePayload(from: data)
        XCTAssertEqual(payload.text, text)
    }

    func test_decode_utf16BEWithBOM_roundTrips() throws {
        let text = "héllo wörld"
        var data = Data([0xFE, 0xFF])
        data.append(try XCTUnwrap(text.data(using: .utf16BigEndian)))
        let payload = try PlainTextDocument.decodePayload(from: data)
        XCTAssertEqual(payload.text, text)
    }

    func test_decode_nulBytesWithoutBOM_throwsBinaryFile() {
        let data = Data([0x68, 0x69, 0x00, 0x68, 0x69])
        XCTAssertThrowsError(try PlainTextDocument.decodePayload(from: data)) { error in
            guard case PlainTextDocument.DocumentError.binaryFile = error else {
                return XCTFail("Expected .binaryFile, got \(error)")
            }
        }
    }

    // MARK: - Composite

    func test_encode_allOptions_chainCorrectly() throws {
        let input = "alpha   \r\nbeta\t\r\ngamma"
        let data = try PlainTextDocument.encode(
            text: input,
            encoding: .utf8,
            lineEnding: .lf,
            trimTrailingWhitespace: true,
            ensureTrailingNewline: true,
            saveUTF8BOMPref: false
        )
        // Trim first → "alpha\r\nbeta\r\ngamma", then normalize CRLF→LF
        // → "alpha\nbeta\ngamma", then ensure trailing → "alpha\nbeta\ngamma\n".
        XCTAssertEqual(String(data: data, encoding: .utf8), "alpha\nbeta\ngamma\n")
    }

    // MARK: - Multi-file replacement encoding and targeting

    func test_multiFileReplacement_refusesLossyLegacyEncoding() throws {
        let original = try XCTUnwrap("café".data(using: .isoLatin1))
        let encoded = MultiFileSearchSheet.encodeReplacement(
            "café 😀",
            encoding: .isoLatin1,
            originalData: original
        )
        XCTAssertNil(encoded)
    }

    func test_multiFileReplacement_preservesUTF16BigEndianBOM() throws {
        var original = Data([0xFE, 0xFF])
        original.append(try XCTUnwrap("cat".data(using: .utf16BigEndian)))
        let encoded = try XCTUnwrap(MultiFileSearchSheet.encodeReplacement(
            "dog",
            encoding: .utf16,
            originalData: original
        ))
        XCTAssertTrue(encoded.starts(with: [0xFE, 0xFF]))
        XCTAssertEqual(
            String(data: encoded.dropFirst(2), encoding: .utf16BigEndian),
            "dog"
        )
    }

    func test_multiFileQueryReplacement_targetsChosenLiteralMatch() throws {
        var context = FindContext()
        context.query = "cat"
        let result = try MultiFileSearchSheet.replaceInString(
            "cat cat",
            query: "cat",
            replacement: "dog",
            context: context,
            limitToFirst: false,
            targetRanges: [NSRange(location: 4, length: 3)]
        )
        XCTAssertEqual(result.0, "cat dog")
        XCTAssertEqual(result.1, 1)
    }

    func test_multiFileQueryReplacement_targetsChosenRegexMatchWithCapture() throws {
        var context = FindContext()
        context.query = #"a(\d)"#
        context.useRegex = true
        let result = try MultiFileSearchSheet.replaceInString(
            "a1 a2",
            query: context.query,
            replacement: "b$1",
            context: context,
            limitToFirst: false,
            targetRanges: [NSRange(location: 3, length: 2)]
        )
        XCTAssertEqual(result.0, "a1 b2")
        XCTAssertEqual(result.1, 1)
    }
}
