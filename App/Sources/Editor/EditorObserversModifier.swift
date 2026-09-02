import SwiftUI

/// Bundles `EditorView`'s `.onChange` observers (encoding/lineEnding
/// mirror, autosave debounce, live spell check toggle, tap-to-suggest
/// on misspelling entry) into one modifier. Same type-checker budget
/// reason as the sibling *AlertModifier files — five `.onChange`
/// closures inline in `body` pushed the chain past the compiler's
/// expression limit again.
struct EditorObserversModifier: ViewModifier {

    let document: PlainTextDocument
    let state: EditorState
    let onBufferEdit: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: state.fileEncoding) { _, newValue in
                guard document.fileEncoding != newValue else { return }
                document.fileEncoding = newValue
                document.isDirty = true
                document.bufferRevision &+= 1
            }
            .onChange(of: state.lineEnding) { _, newValue in
                guard document.lineEnding != newValue else { return }
                document.lineEnding = newValue
                document.isDirty = true
                document.bufferRevision &+= 1
            }
            // `bufferRevision` is a UInt64 bumped per edit — O(1) to
            // observe. Watching `document.text` would cascade the whole
            // String through the observation graph per keystroke (the
            // McCartney-file freeze).
            .onChange(of: document.bufferRevision) { _, _ in
                onBufferEdit()
            }
            // Repaint/clear immediately so the user sees the toggle take.
            .onChange(of: state.spellCheck) { _, isOn in
                if isOn {
                    state.textView?.highlightAllMisspellings()
                } else {
                    state.liveSpellTask?.cancel()
                    state.liveSpellTask = nil
                    state.textView?.clearMisspellingHighlights()
                }
            }
            // Tap-to-suggest on a highlighted misspelling: only fire
            // when the caret crosses INTO a new misspelling range, never
            // on arrow-key movement within the same word, never while
            // another sheet is up.
            .onChange(of: state.selectedRange) { oldValue, newValue in
                guard newValue.length == 0,
                      AppStateBus.shared.presentation.presentedSheet == nil,
                      let actions = state.textView,
                      let entered = actions.misspellingRange(at: newValue.location),
                      actions.misspellingRange(at: oldValue.location) != entered
                else { return }
                CommandActions.presentSpellCheckSheet()
            }
    }
}
