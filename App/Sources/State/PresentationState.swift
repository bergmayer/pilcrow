import Foundation

@MainActor
@Observable
final class PresentationState {

    var presentedSheet: EditorSheet? {
        didSet {
            if presentedSheet == nil { presentedSheetOwner = nil }
        }
    }
    /// Stable owner for editor-scoped sheets. Window focus can change while
    /// a sheet is visible under Stage Manager; its actions must not follow
    /// the global focus pointer into another document.
    weak var presentedSheetOwner: EditorState?
    var revertRequestCount: Int = 0
    var openErrorMessage: String?
    var pendingClose: PendingClose?
    var pendingBatchClose: PendingBatchClose?
    var sourceStaleCheck: SourceStaleCheck?

    func present(_ sheet: EditorSheet, owner: EditorState?) {
        presentedSheetOwner = owner
        presentedSheet = sheet
    }
}

/// What the user has to resolve before continuing.
enum SourceStaleCheck: Identifiable {
    /// File the draft references is gone. Continue as Untitled.
    case missing(tabID: UUID, displayName: String)
    /// Source file changed since draft was captured. The user picks
    /// between keeping the draft's bytes or reloading disk content.
    case changedOnAdopt(tabID: UUID, displayName: String)
    /// ⌘S aborted because the source file changed between load and
    /// save. The user picks force-save, reload, or cancel.
    case changedOnSave(tabID: UUID, displayName: String)

    var id: String {
        switch self {
        case .missing(let t, _):       return "missing-\(t)"
        case .changedOnAdopt(let t, _): return "changed-adopt-\(t)"
        case .changedOnSave(let t, _):  return "changed-save-\(t)"
        }
    }

    var displayName: String {
        switch self {
        case .missing(_, let n), .changedOnAdopt(_, let n), .changedOnSave(_, let n):
            return n
        }
    }
}

/// The session id is captured so the dialog targets the right
/// window even if focus shifts before the user taps a button.
@MainActor
struct PendingClose: Identifiable {
    let id = UUID()
    let sessionID: ObjectIdentifier
    let tabID: UUID
    let displayName: String
    let isUntitled: Bool
}

/// "Close Other Tabs" / "Close Tabs to the Right" / "Close All Tabs"
/// route through this when at least one of the tabs in the batch
/// has unsaved changes. The user picks Discard All (drops drafts)
/// or Save All to Drafts (keeps each tab's edits in the unsaved-
/// drafts list so they're recoverable from the launcher). No per-
/// tab Save-and-Close — the prompt is meant to be quick.
@MainActor
struct PendingBatchClose: Identifiable {
    let id = UUID()
    let sessionID: ObjectIdentifier
    let tabIDs: [UUID]
    /// "Close 4 other tabs", "Close 7 tabs to the right", "Close all 9 tabs"
    let description: String
    /// Number of tabs in `tabIDs` that are actually dirty — used in
    /// the dialog message so the user sees the scope.
    let dirtyCount: Int
}
