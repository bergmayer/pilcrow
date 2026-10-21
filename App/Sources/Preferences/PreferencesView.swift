import SwiftUI

struct PreferencesView: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            EditorPreferencesTab()
                .tabItem { Label("Editor", systemImage: "text.justify") }

            TypingPreferencesTab()
                .tabItem { Label("Typing", systemImage: "keyboard") }

            ToolbarPreferencesTab()
                .tabItem { Label(DeviceIdiom.isPhone ? EditorChrome.toolMenuTitle : "Toolbar", systemImage: "rectangle.topthird.inset.filled") }
        }
        // iPad-only minimum frame — iPhone presents as a sheet at
        // screen width, where forcing 520pt would clip.
        .frame(minWidth: DeviceIdiom.isPhone ? nil : 520,
               minHeight: DeviceIdiom.isPhone ? nil : 420)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(DeviceIdiom.isPhone ? .inline : .automatic)
        .toolbar {
            // iPhone sheet has no system-supplied dismiss.
            if DeviceIdiom.isPhone {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .bold()
                }
            }
        }
    }
}
