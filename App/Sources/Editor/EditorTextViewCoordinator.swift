import SwiftUI
import UIKit
import EditorEngine

/// Bridges the engine's `TextViewDelegate` callbacks into the SwiftUI
/// observation graph. Lives here (not nested in `EditorTextView`) so
/// the representable's body stays readable and the per-edit /
/// per-render pipelines are easy to find by file name.
@MainActor
final class EditorTextViewCoordinator: NSObject, @preconcurrency EditorEngine.TextViewDelegate {
    let document: PlainTextDocument
    let state: EditorState
    var currentLanguageIdentifier: LanguageIdentifier?
    /// Last EXTERNAL push (load / revert / restore); the cached
    /// value lets updateUIView skip the per-render O(n) compare.
    var lastPushedDocumentText: String?
    /// Last focus request consumed by this mounted engine view.
    var handledFocusRequestID: Int = 0
    /// Short-circuits delegate callbacks while propagating a
    /// sibling split-pane edit so the change doesn't bounce.
    var isApplyingSiblingSync: Bool = false
    /// Debounced snapshot back into `state.text` / `document.text`
    /// for the eventual-consistency consumers.
    var bufferSnapshotTask: Task<Void, Never>?
    /// Skips the O(N) fold walk when nothing relevant has
    /// changed — SwiftUI fires updateUIView on every observable
    /// mutation regardless of buffer state.
    private var foldCacheKey: (length: Int, language: LanguageIdentifier, userFolds: String)?
    weak var bookmarkOverlay: BookmarkGutterOverlay?
    weak var changeHistoryOverlay: ChangeHistoryGutterOverlay?
    /// Cached so the debounced refresh skips `components(separatedBy:)`
    /// when the sources haven't moved.
    var changeHistoryBaselineCache: String?
    var changeHistoryCurrentCache: String?
    /// `updateUIView` fires per body re-eval — i.e. every
    /// keystroke on a big file. Splitting both baseline + buffer
    /// by "\n" on each call is ~22k allocs on Moby Dick. The
    /// debounce coalesces them into one re-split after the user
    /// pauses; diff bars update a beat late, typing stays snappy.
    var overlayRefreshTask: Task<Void, Never>?
    /// `AppTheme.current(...)` returns a fresh reference each
    /// call; the engine's `theme.didSet` uses `!==`. Reassigning
    /// an equivalent theme per render invalidates every line
    /// controller and re-lays the view — visible on large files
    /// as the viewport drifting down a line per update.
    var themeCacheKey: ThemeCacheKey?

    struct ThemeCacheKey: Equatable {
        let name: AppThemeName
        let font: EditorFont
        let fontSize: CGFloat
        let style: UIUserInterfaceStyle
    }

    init(document: PlainTextDocument, state: EditorState) {
        self.document = document
        self.state = state
    }

    func textViewDidChange(_ textView: EditorEngine.TextView) {
        if isApplyingSiblingSync { return }
        // This is the authoritative mutation callback. Undo/redo,
        // indentation, line moves, and Replace All can bypass the
        // preflight delegate, but they all finish here.
        if !document.isDirty { document.isDirty = true }
        document.bufferRevision &+= 1
        scheduleBufferSnapshot(from: textView)
        foldCacheKey = nil
        refreshFoldableRegions(textView)
    }

    /// Window matches the change-history overlay so both refresh
    /// in the same render pass.
    private func scheduleBufferSnapshot(from textView: EditorEngine.TextView) {
        bufferSnapshotTask?.cancel()
        bufferSnapshotTask = Task { @MainActor [weak document, weak state, weak self] in
            try? await Task.sleep(for: Timing.changeHistoryOverlayDebounce)
            if Task.isCancelled { return }
            guard let document, let state, let self else { return }
            let snapshot = textView.text
            if document.text != snapshot {
                document.text = snapshot
                // Match so the next updateUIView doesn't push
                // this snapshot back at us.
                self.lastPushedDocumentText = snapshot
            }
            if state.text != snapshot {
                state.text = snapshot
            }
        }
    }

    func refreshFoldableRegions(_ textView: EditorEngine.TextView) {
        guard !state.isLargeFile else {
            textView.foldableRegions = []
            return
        }
        let length = (textView.text as NSString).length
        // User-fold fingerprint included so an ad-hoc fold's
        // chevron appears immediately.
        let userFingerprint = state.userFoldedBodyRanges
            .map { "\($0.lowerBound)-\($0.upperBound)" }
            .sorted()
            .joined(separator: ",")
        let key = (length: length, language: state.languageIdentifier, userFolds: userFingerprint)
        if let cached = foldCacheKey,
           cached.length == key.length,
           cached.language == key.language,
           cached.userFolds == key.userFolds {
            return
        }
        var regions = FoldDiscovery.allFoldableHeaders(
            in: textView.text as NSString,
            language: state.languageIdentifier
        )
        // Fold Selection isn't in language discovery; synthesize
        // a FoldableRegion so the engine paints its chevron.
        for body in state.userFoldedBodyRanges {
            let header = max(0, body.lowerBound - 1)
            if regions.contains(where: { $0.headerRow == header }) { continue }
            regions.append(EditorEngine.TextView.FoldableRegion(
                headerRow: header,
                bodyRange: body
            ))
        }
        textView.foldableRegions = regions
        foldCacheKey = key
    }

    func textViewDidChangeSelection(_ textView: EditorEngine.TextView) {
        state.selectedRange = textView.selectedRange
        guard let textView = textView as? PilcrowTextView else { return }
        if state.highlightMatchingBrackets {
            textView.refreshBracketMatchHighlight()
        } else {
            textView.clearBracketMatchHighlight()
        }
        refreshLiveMatches(textView)
    }

    private static let liveMatchIDPrefix = "live-match-"

    func refreshLiveMatches(_ textView: EditorEngine.TextView) {
        let selRange = textView.selectedRange
        let cleared = textView.highlightedRanges.filter { !$0.id.hasPrefix(Self.liveMatchIDPrefix) }

        // Length checks run BEFORE the O(n) `textView.text` bridge —
        // this fires on every caret move, and a caret never matches.
        guard state.liveMatchHighlight,
              selRange.length >= 2,
              selRange.length < 200 else {
            textView.highlightedRanges = cleared
            state.liveMatchCount = 0
            matchScrollOverlay?.matchRanges = []
            return
        }
        let ns = textView.text as NSString
        guard selRange.location + selRange.length <= ns.length else {
            textView.highlightedRanges = cleared
            state.liveMatchCount = 0
            matchScrollOverlay?.matchRanges = []
            return
        }
        let needle = ns.substring(with: selRange)
        // Single-line only.
        if needle.contains("\n") || needle.contains("\r") {
            textView.highlightedRanges = cleared
            state.liveMatchCount = 0
            matchScrollOverlay?.matchRanges = []
            return
        }
        var hits: [NSRange] = []
        var searchStart = 0
        while searchStart < ns.length {
            let searchRange = NSRange(location: searchStart, length: ns.length - searchStart)
            let r = ns.range(of: needle, options: [], range: searchRange)
            guard r.location != NSNotFound else { break }
            if r.location != selRange.location {
                hits.append(r)
            }
            searchStart = r.location + max(r.length, 1)
            if hits.count > 2000 { break }  // sanity cap on huge files
        }
        let tint = UIColor.systemYellow.withAlphaComponent(0.35)
        let highlights = hits.enumerated().map { idx, range in
            HighlightedRange(
                id: "\(Self.liveMatchIDPrefix)\(idx)",
                range: range,
                color: tint,
                cornerRadius: 2
            )
        }
        textView.highlightedRanges = cleared + highlights
        state.liveMatchCount = hits.count
        matchScrollOverlay?.matchRanges = hits
    }

    weak var matchScrollOverlay: MatchScrollMarksOverlay?

    /// Per-edit: armed modifier → dirty flag → sibling sync →
    /// list-continuation interceptor on Enter. The interceptor's
    /// `false` return skips the engine's bare `\n` insert when
    /// the helper has already handled the newline.
    func textView(
        _ textView: EditorEngine.TextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        if isApplyingSiblingSync { return true }

        // Armed accessory modifier wins over the literal
        // keystroke. `handleArmedKey` disarms before dispatching —
        // armed actions can re-enter this delegate via `replace`.
        if state.armedAccessoryControl
            || state.armedAccessoryCommand
            || state.armedAccessoryOption,
           text.count == 1,
           let ascii = text.unicodeScalars.first,
           ascii.isASCII {
            if AccessoryKeyboard.handleArmedKey(text, state: state) {
                return false
            }
        }

        // Sibling sync reaches the sibling coordinator to arm its
        // recursion guard. Gated on the sibling view
        // existing, not `splitOpen` — that flag only lives on the
        // primary pane's state, so the secondary pane would skip
        // syncing its edits back.
        if let sibling = state.siblingState?.textView,
           let siblingCoord = sibling.editorDelegate as? EditorTextViewCoordinator {
            siblingCoord.isApplyingSiblingSync = true
            sibling.replace(range, withText: text)
            siblingCoord.isApplyingSiblingSync = false
        }

        // 3. List continuation interceptor.
        guard text == "\n",
              UserDefaults.standard.bool(forKey: AppPreferenceKey.autoContinueLists)
        else { return true }
        switch MarkdownListContinuation.handle(in: textView, replacing: range) {
        case .intercepted: return false
        case .passThrough: return true
        }
    }
}
