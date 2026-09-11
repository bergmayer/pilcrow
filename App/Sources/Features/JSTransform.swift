import SwiftUI
import struct EditorEngine.BatchReplaceSet
import UIKit

// MARK: - Model

/// One JavaScript transform slot. The user writes code that operates
/// on `input` (the document or the selection) and produces a string
/// result — the value of the last expression in the script, or the
/// value assigned to `output`.
///
/// 10 slots are persisted permanently; menu / keyboard slots 1–9 map
/// to indices 0–8, slot 10 (⌃⌥0) maps to index 9 — same convention
/// as the tab-jump shortcuts.
struct JSTransformSlot: Codable, Equatable, Identifiable {
    var id: Int          // 1...10
    var name: String
    var code: String
    var scope: Scope

    enum Scope: String, Codable, CaseIterable {
        case document   // input = full document text
        case selection  // input = selected text (or empty if no selection)

        var label: String {
            switch self {
            case .document:  "Whole Document"
            case .selection: "Selection"
            }
        }
    }

    static func empty(id: Int) -> JSTransformSlot {
        JSTransformSlot(id: id, name: "", code: "", scope: .selection)
    }

    var isConfigured: Bool {
        !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Slot \(id)" : trimmed
    }
}

@MainActor
@Observable
final class JSTransformStore {

    static let shared = JSTransformStore()
    static let slotCount = 10

    private(set) var slots: [JSTransformSlot]

    private init() {
        self.slots = Self.load() ?? Self.defaultSlots()
        Self.seedSampleSlotIfEmpty(into: &slots)
    }

    /// Default sample placed in slot 1 on first launch — a small,
    /// self-contained transform that shows the model (input
    /// string in / output string out) without needing the user to
    /// understand JSON, regex, or anything domain-specific. ROT13
    /// fits: it's reversible (run it twice to get back the original),
    /// has no parse-error branch, and is famously simple. Won't
    /// overwrite a user-edited slot 1.
    private static let sampleJSCode: String = """
    // ROT13: rotates each letter 13 places through the alphabet.
    // Running this transform twice on the same text restores the
    // original — a quick way to show the input/output model:
    // `input` is the selected text (or whole document), and the
    // script's job is to assign the transformed string to `output`.
    output = input.replace(/[A-Za-z]/g, function (ch) {
      const base = ch <= 'Z' ? 65 : 97;
      return String.fromCharCode((ch.charCodeAt(0) - base + 13) % 26 + base);
    });
    """

    private static func defaultSlots() -> [JSTransformSlot] {
        var slots = (1...Self.slotCount).map(JSTransformSlot.empty)
        slots[0] = JSTransformSlot(id: 1, name: "ROT13",
                                    code: sampleJSCode, scope: .selection)
        return slots
    }

    /// One-time seed if a long-time user upgraded into the sample
    /// — only fills slot 1 when both its name and code are empty.
    private static func seedSampleSlotIfEmpty(into slots: inout [JSTransformSlot]) {
        guard let first = slots.first,
              first.name.isEmpty,
              first.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        slots[0] = JSTransformSlot(id: 1, name: "ROT13",
                                    code: sampleJSCode, scope: .selection)
    }

    func update(_ slot: JSTransformSlot) {
        guard let idx = slots.firstIndex(where: { $0.id == slot.id }) else { return }
        slots[idx] = slot
        save()
    }

    /// Slot index by id (1-based). Returns nil for out-of-range
    /// callers (e.g. menu shortcuts that lost sync with storage).
    func slot(id: Int) -> JSTransformSlot? {
        slots.first(where: { $0.id == id })
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(slots) else { return }
        UserDefaults.standard.set(data, forKey: AppPreferenceKey.jsTransformSlots)
    }

    private static func load() -> [JSTransformSlot]? {
        guard let data = UserDefaults.standard.data(forKey: AppPreferenceKey.jsTransformSlots),
              let decoded = try? JSONDecoder().decode([JSTransformSlot].self, from: data),
              decoded.count == JSTransformStore.slotCount
        else { return nil }
        return decoded
    }
}

// MARK: - Execution

/// A transform owns one captured buffer and selection. Its result is applied
/// only if that buffer and selection are still current when the worker finishes.
@MainActor
enum JSTransformRunner {
    static func run(_ slot: JSTransformSlot) {
        guard slot.isConfigured, let state = CommandActions.state,
              let editor = state.textView, state.transformTask == nil else { return }
        let source = editor.text
        let selection = editor.selectedRange
        let range = slot.scope == .document ? NSRange(location: 0, length: (source as NSString).length) : selection
        let input = (source as NSString).substring(with: range)
        state.operationError = nil
        state.transformTask = Task { @MainActor [weak state, weak editor] in
            defer { state?.transformTask = nil }
            do {
                let worker = JavaScriptWorker()
                let output = try await worker.evaluate(code: slot.code, input: input)
                try Task.checkCancellation()
                guard let state, let editor, state.textView === editor,
                      editor.text == source, editor.selectedRange == selection else {
                    state?.operationError = "The document or selection changed. Run the transform again to apply it to the current text."
                    return
                }
                let replacement = output.replacingLineEndings(with: state.lineEnding)
                editor.replaceText(in: BatchReplaceSet(replacements: [.init(range: range, text: replacement)]))
            } catch is CancellationError { }
            catch { state?.operationError = "\(slot.displayName): \(error.localizedDescription)" }
        }
    }
}

// MARK: - Editor sheet

/// Per-slot editor presented from the Typing settings pane. Edits a
/// copy of the slot and writes through to the store on Save.
struct JSTransformEditorSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var draft: JSTransformSlot
    let onSave: (JSTransformSlot) -> Void

    init(slot: JSTransformSlot, onSave: @escaping (JSTransformSlot) -> Void) {
        self._draft = State(initialValue: slot)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Reverse Lines", text: $draft.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Scope") {
                    Picker("Apply To", selection: $draft.scope) {
                        ForEach(JSTransformSlot.Scope.allCases, id: \.self) { scope in
                            Text(scope.label).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    TextEditor(text: $draft.code)
                        .font(.body.monospaced())
                        .frame(minHeight: 220)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("JavaScript")
                } footer: {
                    Text("`input` (or `text`) holds the source string. Return the result as the last expression, or assign it to `output`. Example: `input.split('\\n').reverse().join('\\n')`.")
                }
            }
            .navigationTitle("Slot \(draft.id): \(draft.name.isEmpty ? "(unnamed)" : draft.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                }
            }
        }
    }
}
