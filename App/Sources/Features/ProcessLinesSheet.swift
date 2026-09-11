import SwiftUI

/// Line filter — keep / delete / copy lines that match
/// a pattern.
struct ProcessLinesSheet: View {

    @Environment(\.dismiss) private var dismiss

    @State private var pattern: String = ""
    @State private var useRegex: Bool = false
    @State private var invertMatch: Bool = false
    @State private var action: CommandActions.ProcessLinesAction = .keepMatching

    var body: some View {
        NavigationStack {
            Form {
                Section("Pattern") {
                    TextField("Substring or regex", text: $pattern)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Toggle("Regular expression", isOn: $useRegex)
                    Toggle("Invert (operate on non-matching lines)", isOn: $invertMatch)
                }
                Section("Action") {
                    Picker("What to do", selection: $action) {
                        Text("Keep matching lines").tag(CommandActions.ProcessLinesAction.keepMatching)
                        Text("Delete matching lines").tag(CommandActions.ProcessLinesAction.deleteMatching)
                        Text("Copy matching lines to clipboard").tag(CommandActions.ProcessLinesAction.copyMatchingToClipboard)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Text("Operates on the current selection if non-empty, otherwise the whole document.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Process Lines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        CommandActions.processLines(
                            pattern: pattern,
                            regex: useRegex,
                            invert: invertMatch,
                            action: action
                        )
                        dismiss()
                    }
                    .disabled(pattern.isEmpty)
                }
            }
        }
    }
}
