import SwiftUI
import FileEncoding
import LineEnding

/// iOS has no stock `.checkbox` Toggle style.
private struct CheckboxRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .frame(width: 24)
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct EditorPreferencesTab: View {

    @Bindable private var prefs = AppPreferencesStore.shared
    @State private var appIcon = AppIconChoice.current
    @State private var appIconErrorMessage: String?

    /// Int↔Double bridge — live editor/menu zoom callers use Int.
    private var fontSizeBinding: Binding<Int> {
        Binding(
            get: { Int(prefs.fontSize.rounded()) },
            set: { prefs.fontSize = Double($0) }
        )
    }

    private var defaultEncodingBinding: Binding<UInt> {
        Binding(
            get: { UInt(prefs.defaultEncodingRaw) },
            set: { prefs.defaultEncodingRaw = Int($0) }
        )
    }

    private var defaultLineEndingBinding: Binding<LineEnding> {
        Binding(
            get: { LineEnding(rawValue: prefs.defaultLineEndingRaw.first ?? "\n") ?? .lf },
            set: { prefs.defaultLineEndingRaw = String($0.rawValue) }
        )
    }

    private var defaultLanguageBinding: Binding<LanguageIdentifier> {
        Binding(
            get: { LanguageIdentifier(rawValue: prefs.defaultLanguage) ?? .plain },
            set: { prefs.defaultLanguage = $0.rawValue }
        )
    }

    private var syntaxLimitBinding: Binding<SyntaxLimit> {
        Binding(
            get: { SyntaxLimit(rawValue: prefs.syntaxLimitBytes) ?? .up5MB },
            set: { prefs.syntaxLimitBytes = $0.rawValue }
        )
    }

    private var themeBinding: Binding<AppThemeName> {
        Binding(
            get: { AppThemeName(stored: prefs.themeName) },
            set: { prefs.themeName = $0.rawValue }
        )
    }

    private var commonEncodings: [String.Encoding] {
        [
            .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .utf32,
            .windowsCP1252, .isoLatin1, .isoLatin2, .macOSRoman,
            .shiftJIS, .japaneseEUC, .iso2022JP
        ]
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: themeBinding) {
                    ForEach(AppThemeName.allCases, id: \.self) { name in
                        Text(name.displayName).tag(name)
                    }
                }
                Picker("App Icon", selection: $appIcon) {
                    ForEach(AppIconChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .disabled(!UIApplication.shared.supportsAlternateIcons)
                .onChange(of: appIcon) { _, choice in
                    changeAppIcon(to: choice)
                }
            }

            Section("Display") {
                Picker("Font", selection: $prefs.fontName) {
                    // Monospaced first — typical code-editor pick.
                    Section("Monospaced") {
                        ForEach(EditorFont.allCases.filter(\.isMonospaced), id: \.rawValue) { face in
                            Text(face.displayName).tag(face.rawValue)
                        }
                    }
                    Section("Proportional") {
                        ForEach(EditorFont.allCases.filter { !$0.isMonospaced }, id: \.rawValue) { face in
                            Text(face.displayName).tag(face.rawValue)
                        }
                    }
                }
                LabeledContent("Font Size") {
                    Stepper(value: fontSizeBinding, in: 9...96, step: 1) {
                        Text("\(fontSizeBinding.wrappedValue) pt")
                            .monospacedDigit()
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                }
                Toggle("Show Line Numbers", isOn: $prefs.showLineNumbers)
                Toggle("Wrap Lines", isOn: $prefs.wrapLines)
                Toggle("Scroll Past Last Line", isOn: $prefs.overscroll)
                Toggle("Show Page Guide", isOn: $prefs.showPageGuide)
                LabeledContent("Page Guide Column") {
                    Stepper(value: $prefs.pageGuideColumn, in: 20...200, step: 1) {
                        Text("\(prefs.pageGuideColumn)")
                            .monospacedDigit()
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                }
            }

            Section {
                Toggle("Show Invisible Characters", isOn: $prefs.showInvisibles)
                CheckboxRow(label: "Space",              isOn: $prefs.showInvisibleSpace)
                CheckboxRow(label: "Tab",                isOn: $prefs.showInvisibleTab)
                CheckboxRow(label: "Newline",            isOn: $prefs.showInvisibleNewline)
                CheckboxRow(label: "Non-Breaking Space", isOn: $prefs.showInvisibleNonBreakingSpace)
            } header: {
                Text("Invisible Characters")
            } footer: {
                Text("The master switch gates the whole effect; tap a row to toggle each mark.")
            }

            Section("Indentation") {
                Picker("Indent With", selection: $prefs.usesTabs) {
                    Text("Spaces").tag(false)
                    Text("Tabs").tag(true)
                }
                LabeledContent("Width") {
                    Stepper(value: $prefs.indentWidth, in: 1...12, step: 1) {
                        Text("\(prefs.indentWidth)")
                            .monospacedDigit()
                            .frame(minWidth: 30, alignment: .trailing)
                    }
                }
            }

            Section("Editing") {
                Toggle("Insert Closing Brackets / Quotes Automatically", isOn: $prefs.insertCharacterPairs)
            }

            Section("Defaults for New Documents") {
                Picker("Text Encoding", selection: defaultEncodingBinding) {
                    ForEach(commonEncodings, id: \.rawValue) { encoding in
                        Text(String.localizedName(of: encoding))
                            .tag(encoding.rawValue)
                    }
                }
                Picker("Line Endings", selection: defaultLineEndingBinding) {
                    ForEach(LineEnding.allCases, id: \.self) { lineEnding in
                        Text("\(lineEnding.label)").tag(lineEnding)
                    }
                }
                Picker("Syntax Language", selection: defaultLanguageBinding) {
                    ForEach(LanguageRegistry.all, id: \.identifier) { language in
                        Text(language.displayName).tag(language.identifier)
                    }
                }
            }

            Section {
                Toggle("Ensure file ends with a newline", isOn: $prefs.ensureTrailingNewline)
                Toggle("Trim trailing whitespace", isOn: $prefs.trimTrailingWhitespaceOnSave)
            } header: {
                Text("On Save")
            } footer: {
                Text("Applied by Save and Save As. Recovery snapshots preserve the exact working buffer. BOM and line endings are handled per document via the encoding and line-ending pickers in the status bar.")
            }

            Section {
                Picker("Apply syntax & folding", selection: syntaxLimitBinding) {
                    ForEach(SyntaxLimit.allCases) { limit in
                        Text(limit.label).tag(limit)
                    }
                }
            } header: {
                Text("Large Files")
            } footer: {
                Text("Files over the limit open in plain-text mode for snappy typing. Tree-sitter syntax highlighting, code folding, and the Markdown inline decorator are all skipped.")
            }
        }
        // Default formStyle (insetGrouped). `.grouped` runs edge-to-edge,
        // which looks broken on iPhone where the sheet = screen width.
        .alert("Couldn't Change App Icon", isPresented: Binding(
            get: { appIconErrorMessage != nil },
            set: { if !$0 { appIconErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appIconErrorMessage ?? "Unknown error")
        }
    }

    private func changeAppIcon(to choice: AppIconChoice) {
        guard choice.alternateIconName != UIApplication.shared.alternateIconName else {
            return
        }
        Task { @MainActor in
            do {
                try await UIApplication.shared.setAlternateIconName(choice.alternateIconName)
            } catch {
                appIcon = .current
                appIconErrorMessage = error.localizedDescription
            }
        }
    }

}
