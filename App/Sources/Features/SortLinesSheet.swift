import SwiftUI
import LineSort
import LineEnding

struct SortLinesSheet: View {

    let text: String
    let lineEnding: LineEnding
    var scopeLabel: String = "Whole Document"
    let onApply: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var ignoresCase: Bool = true
    @State private var numeric: Bool = true
    @State private var isLocalized: Bool = true
    @State private var keepsFirstLine: Bool = false
    @State private var descending: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section { LabeledContent("Scope", value: scopeLabel) }
                Section("Options") {
                    Toggle("Case-insensitive", isOn: $ignoresCase)
                    Toggle("Numeric sort", isOn: $numeric)
                    Toggle("Localized", isOn: $isLocalized)
                    Toggle("Descending", isOn: $descending)
                    Toggle("Keep first line in place", isOn: $keepsFirstLine)
                }

                Section("Preview") {
                    Text(previewSortedFirstLines)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("Sort Lines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sort") {
                        onApply(sortedText)
                        dismiss()
                    }
                }
            }
        }
    }

    private var options: SortOptions {
        SortOptions(
            ignoresCase: ignoresCase,
            numeric: numeric,
            isLocalized: isLocalized,
            keepsFirstLine: keepsFirstLine,
            descending: descending
        )
    }

    private var sortedText: String {
        EntireLineSortPattern().sort(text, options: options, baseLineEnding: lineEnding.string)
    }

    private var previewSortedFirstLines: String {
        let lines = sortedText.components(separatedBy: lineEnding.string)
        return lines.prefix(20).joined(separator: lineEnding.string)
    }
}
