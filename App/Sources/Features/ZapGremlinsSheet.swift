import SwiftUI

/// Choose unwanted character categories to remove or replace.
///
/// Lets the user pick which character categories count as gremlins
/// (ASCII control, invisible Unicode, all non-ASCII) and what to
/// substitute in (delete, ?, space, or a custom string). The "Zap"
/// button applies the transform to the current selection (whole
/// document if nothing's selected) and dismisses.
struct ZapGremlinsSheet: View {

    @Environment(\.dismiss) private var dismiss

    @State private var options = ZapGremlinsOptions()
    @State private var action: ReplacementChoice = .delete
    @State private var customReplacement: String = ""

    enum ReplacementChoice: Hashable {
        case delete
        case questionMark
        case space
        case custom
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("ASCII control characters",
                           isOn: $options.asciiControl)
                    Toggle("Invisible Unicode (BOM, zero-width, joiners)",
                           isOn: $options.invisibleUnicode)
                    Toggle("All non-ASCII characters (codes above 127)",
                           isOn: $options.nonAscii)
                } header: {
                    Text("What to Zap")
                } footer: {
                    Text("Tab, line feed, and carriage return are always kept.")
                        .font(.footnote)
                }

                Section("Replacement") {
                    Picker("Replace with", selection: $action) {
                        Text("Delete").tag(ReplacementChoice.delete)
                        Text("Question mark (?)").tag(ReplacementChoice.questionMark)
                        Text("Space").tag(ReplacementChoice.space)
                        Text("Custom…").tag(ReplacementChoice.custom)
                    }
                    .pickerStyle(.inline)

                    if action == .custom {
                        TextField("Replacement string", text: $customReplacement)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.body.monospaced())
                    }
                }

                Section {
                    Button {
                        zap()
                    } label: {
                        Label("Zap", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!anyCategorySelected)
                }
            }
            .navigationTitle("Zap Gremlins")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var anyCategorySelected: Bool {
        options.asciiControl || options.invisibleUnicode || options.nonAscii
    }

    private func zap() {
        var opts = options
        opts.replacement = resolvedReplacement
        CommandActions.zapGremlinsConfigured(options: opts)
        dismiss()
    }

    private var resolvedReplacement: String {
        switch action {
        case .delete:       return ""
        case .questionMark: return "?"
        case .space:        return " "
        case .custom:       return customReplacement
        }
    }
}
