import SwiftUI
import FileEncoding
import LineEnding

/// Per-document state shared by SwiftUI views and the menu bar
/// (via FocusedValues). Preferences read through `AppPreferencesStore`;
/// overridable ones (theme / font / fontSize) consult a per-window
/// override slot first. Settings changes propagate via Observation
/// without a sync layer.
@MainActor
@Observable
final class EditorState {

    // MARK: Document
    var text: String = ""
    var fileEncoding: FileEncoding = .utf8
    var lineEnding: LineEnding = .lf
    var fileURL: URL?
    /// Diff baseline for the change-history gutter — reset on every
    /// load / save / revert.
    var savedBaselineText: String = ""
    var sidebarOpen: Bool = false
    /// On state (not @State on the view) so menu and the status-bar
    /// ⓘ share one source of truth.
    var inspectorOpen: Bool = false
    var inspectorTab: InfoInspectorSheet.Tab = .file
    /// Two views over the SAME document — per-pane cursor/scroll, but
    /// writes flow back to the shared `PlainTextDocument`.
    var splitOpen: Bool = false
    var splitOrientation: SplitOrientation = .horizontal
    var splitFraction: CGFloat = 0.5
    /// Set when split opens — lets a coordinator reach across to the
    /// sibling pane's text view and propagate edits directly without
    /// a shared observable. Weak to break the would-be retain cycle.
    weak var siblingState: EditorState?
    var languageIdentifier: LanguageIdentifier
    /// Exceeded `SyntaxLimit` — opened in plain-text mode, skipping
    /// tree-sitter, fold discovery, and the markdown decorator.
    var isLargeFile: Bool = false

    // MARK: Per-window overrides (info inspector)
    /// Non-nil → wins over the matching global pref. Lives in memory
    /// only; cleared with the tab. The matching `themeName` / `font` /
    /// `fontSize` computed properties consult this first.
    var themeOverride: AppThemeName?
    var fontOverride: EditorFont?
    var fontSizeOverride: Double?

    // MARK: Runtime UI state
    /// Selection-occurrence count for the status bar; 0 when nothing's
    /// highlighted.
    var liveMatchCount: Int = 0
    var documentShare: DocumentShare?
    var transformTask: Task<Void, Never>?
    var operationError: String?
    var writingStatistics: WritingStatistics?
    @ObservationIgnored var lastFindSelection: (text: String, context: FindContext, range: NSRange)?
    /// Accessory keyboard's sticky modifiers. Armed by a tap on the
    /// accessory bar; the engine's `shouldChangeTextIn` consumes them
    /// on the next text insertion to fire the matching modified
    /// command instead of typing the literal character. Shift is
    /// derived from the case of the incoming character (iOS shift
    /// arms the uppercase form natively), not tracked here.
    var armedAccessoryControl: Bool = false
    var armedAccessoryCommand: Bool = false
    var armedAccessoryOption: Bool = false

    /// Selection / cursor (mirrored from editor engine).
    @ObservationIgnored var viewport: EditorViewport?
    @ObservationIgnored var pendingViewport: EditorViewport?
    var selectedRange: NSRange = NSRange(location: 0, length: 0)
    /// Monotonic request ID. Incrementing this asks the mounted editor
    /// view to become first responder once SwiftUI has rendered it.
    var editorFocusRequestID: Int = 0

    /// Bookmarks: digit (0–9) → cursor location in the document.
    var bookmarks: [Int: Int] = [:]
    /// Fold Selection ranges (the body lines that collapse). Language
    /// fold discovery doesn't know about these — the engine draws an
    /// indicator at the header line above each. In-memory only.
    var userFoldedBodyRanges: Set<ClosedRange<Int>> = []

    /// Cursor jumps from gotos / find / bookmarks — Back/Forward
    /// navigate the history.
    var positionHistory = PositionHistory()

    weak var textView: PilcrowTextView?

    /// The loading-overlay Cancel button cancels this; the Task
    /// clears it in its `defer`.
    var loadTask: Task<Void, Never>?
    /// Distinguishes a superseding load from the cancelled task it replaced;
    /// the older task must not clear the newer task's handle in `defer`.
    var loadGeneration: UInt64 = 0

    /// One pending checkpoint per tab. Further edits update the live
    /// buffer without postponing the checkpoint.
    var autoSaveTask: Task<Void, Never>?

    func scheduleAutoSave(for document: PlainTextDocument) {
        guard !document.isLoading, document.isDirty, autoSaveTask == nil else { return }
        autoSaveTask = Task { @MainActor [weak document, weak self] in
            try? await Task.sleep(for: Timing.autoSaveInterval)
            if Task.isCancelled { return }
            guard let document, !document.isLoading, document.isDirty else {
                self?.autoSaveTask = nil
                return
            }
            let revision = document.bufferRevision
            defer {
                // Cancellation relinquishes ownership in the caller. A failed
                // window close may already have scheduled a replacement.
                if !Task.isCancelled {
                    self?.autoSaveTask = nil
                    if document.bufferRevision != revision {
                        self?.scheduleAutoSave(for: document)
                    }
                }
            }
            // Capture at the deadline, not at the first keystroke. The
            // native buffer is newer than document.text's UI snapshot.
            if let live = self?.textView?.text {
                document.text = live
            }
            await document.autoSave().value
            guard !Task.isCancelled, document.recoveryError == nil else { return }
            let owner = AppStateBus.shared.scenes.allOpenSessions.first { session in
                session.tabs.contains { $0.document === document }
            }
            owner?.persistRestorationRecord()
        }
    }

    /// Debounced re-highlight for live spell check. The engine is a
    /// UIScrollView + custom UITextInput, so it doesn't draw native
    /// squiggles — we paint red misspelling highlights ourselves
    /// after typing stops.
    var liveSpellTask: Task<Void, Never>?

    /// **Important:** EditorView must assign these with weak captures
    /// — closures stored on `self` that capture `self` strongly are
    /// a classic ARC cycle.
    var setText: ((String) -> Void)?
    var reinterpretWithEncoding: ((FileEncoding) -> Void)?

    init() {
        let d = UserDefaults.standard
        self.languageIdentifier = d.string(forKey: AppPreferenceKey.defaultLanguage)
            .flatMap(LanguageIdentifier.init(rawValue:)) ?? .plain
    }

    func requestEditorFocus() {
        editorFocusRequestID &+= 1
    }

    // MARK: - Preferences (pass-through to AppPreferencesStore)
    //
    // Stored fields used to mirror UserDefaults and were kept in sync by
    // EditorPrefSync. Now each reads through the @Observable preferences
    // store directly — views that read `state.fontSize` register a
    // dependency on `prefs.fontSize` (not on state), so Settings changes
    // propagate to every open tab without a separate sync layer.

    /// Per-window override (info inspector) wins over the global pref.
    var themeName: AppThemeName {
        get { themeOverride ?? AppThemeName(stored: prefs.themeName) }
        set {
            if themeOverride != nil {
                themeOverride = newValue
            } else {
                prefs.themeName = newValue.rawValue
            }
        }
    }

    /// Per-window override wins over the global pref.
    var font: EditorFont {
        get { fontOverride ?? EditorFont(stored: prefs.fontName) }
        set {
            if fontOverride != nil {
                fontOverride = newValue
            } else {
                prefs.fontName = newValue.rawValue
            }
        }
    }

    /// Per-window override wins over the global pref.
    var fontSize: Double {
        get { fontSizeOverride ?? prefs.fontSize }
        set {
            if fontSizeOverride != nil {
                fontSizeOverride = newValue
            } else {
                prefs.fontSize = newValue
            }
        }
    }

    var showLineNumbers: Bool {
        get { prefs.showLineNumbers }
        set { prefs.showLineNumbers = newValue }
    }
    var wrapLines: Bool {
        get { prefs.wrapLines }
        set { prefs.wrapLines = newValue }
    }
    var highlightCurrentLine: Bool {
        get { prefs.highlightCurrentLine }
        set { prefs.highlightCurrentLine = newValue }
    }
    var highlightMatchingBrackets: Bool {
        get { prefs.highlightMatchingBrackets }
        set { prefs.highlightMatchingBrackets = newValue }
    }
    var showPageGuide: Bool {
        get { prefs.showPageGuide }
        set { prefs.showPageGuide = newValue }
    }
    var pageGuideColumn: Int {
        get { prefs.pageGuideColumn }
        set { prefs.pageGuideColumn = newValue }
    }
    /// Off by default — the per-line diff is cheap but caretRect
    /// lookups grow with line count, and `Timing
    /// .changeHistoryGutterByteLimit` short-circuits past the ceiling.
    var showChangeHistoryGutter: Bool {
        get { prefs.showChangeHistoryGutter }
        set { prefs.showChangeHistoryGutter = newValue }
    }
    /// Adds a 10-line scrollable cushion below the last line.
    var overscroll: Bool {
        get { prefs.overscroll }
        set { prefs.overscroll = newValue }
    }

    var showInvisibles: Bool {
        get { prefs.showInvisibles }
        set { prefs.showInvisibles = newValue }
    }
    var showInvisibleSpace: Bool {
        get { prefs.showInvisibleSpace }
        set { prefs.showInvisibleSpace = newValue }
    }
    var showInvisibleTab: Bool {
        get { prefs.showInvisibleTab }
        set { prefs.showInvisibleTab = newValue }
    }
    var showInvisibleNewline: Bool {
        get { prefs.showInvisibleNewline }
        set { prefs.showInvisibleNewline = newValue }
    }
    var showInvisibleNonBreakingSpace: Bool {
        get { prefs.showInvisibleNonBreakingSpace }
        set { prefs.showInvisibleNonBreakingSpace = newValue }
    }

    var statusShowsLineCol: Bool {
        get { prefs.statusShowsLineCol }
        set { prefs.statusShowsLineCol = newValue }
    }
    var statusShowsCharCount: Bool {
        get { prefs.statusShowsCharCount }
        set { prefs.statusShowsCharCount = newValue }
    }
    var statusShowsLineCount: Bool {
        get { prefs.statusShowsLineCount }
        set { prefs.statusShowsLineCount = newValue }
    }

    var usesTabs: Bool {
        get { prefs.usesTabs }
        set { prefs.usesTabs = newValue }
    }
    var indentWidth: Int {
        get { prefs.indentWidth }
        set { prefs.indentWidth = newValue }
    }

    var insertCharacterPairs: Bool {
        get { prefs.insertCharacterPairs }
        set { prefs.insertCharacterPairs = newValue }
    }
    var autoCorrect: Bool {
        get { prefs.autoCorrect }
        set { prefs.autoCorrect = newValue }
    }
    var autoCapitalize: Bool {
        get { prefs.autoCapitalize }
        set { prefs.autoCapitalize = newValue }
    }
    var smartQuotes: Bool {
        get { prefs.smartQuotes }
        set { prefs.smartQuotes = newValue }
    }
    var spellCheck: Bool {
        get { prefs.spellCheck }
        set { prefs.spellCheck = newValue }
    }
    var autoLinkDetection: Bool {
        get { prefs.autoLinkDetection }
        set { prefs.autoLinkDetection = newValue }
    }

    var showStatusBar: Bool {
        get { prefs.showStatusBar }
        set { prefs.showStatusBar = newValue }
    }
    var showToolbar: Bool {
        get { prefs.showToolbar }
        set { prefs.showToolbar = newValue }
    }
    var liveMatchHighlight: Bool {
        get { prefs.liveMatchHighlight }
        set { prefs.liveMatchHighlight = newValue }
    }

    var lineHeight: Double {
        get { prefs.lineHeight }
        set { prefs.lineHeight = newValue }
    }
    var ligatures: Bool {
        get { prefs.ligatures }
        set { prefs.ligatures = newValue }
    }

    private var prefs: AppPreferencesStore { AppPreferencesStore.shared }
}

enum SplitOrientation {
    case horizontal
    case vertical
}
