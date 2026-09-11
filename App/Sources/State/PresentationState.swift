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
