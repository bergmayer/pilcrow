import Foundation

/// Data carried by a specific editor-window request. Unlike a process-global
/// queue, SwiftUI delivers this value only to the scene created for it.
enum EditorRoute: Codable, Hashable {
    case newDocument(UUID = UUID())
    case openDocument(URL, line: Int? = nil, requestID: UUID = UUID())
    case moveTab(UUID)
    case restoreSession(String)
    case restoreClosedWindow(UUID)
}

/// Each utility request records its owner and launch. Restored utility
/// windows cannot consume a request meant for a new window.
struct UtilityWindowRequest: Codable, Hashable {
    let id: UUID
    let launchID: String
    let ownerSessionID: String?

    init(launchID: String, ownerSessionID: String?) {
        id = UUID()
        self.launchID = launchID
        self.ownerSessionID = ownerSessionID
    }
}

@MainActor
@Observable
final class SceneRouter {

    weak var currentEditor: EditorState?
    weak var currentSession: EditorSession?

    /// Installed once at app start by `WindowOpenerInstaller`; bridges
    /// non-View callers to SwiftUI's `@Environment(\.openWindow)`,
    /// which can't be reached outside a View body.
    var openWindow: ((SceneID) -> Void)?
    var openEditorWindow: ((EditorRoute) -> Void)?
    var openPreviewWindow: ((UUID) -> Void)?

    var pendingShortcut: HomeShortcut?
    var hasAppliedLaunchBehavior = false

    // MARK: Session registry

    private var sessionRegistry: [WeakRef<EditorSession>] = []

    func registerSession(_ session: EditorSession) {
        sessionRegistry.removeAll { $0.ref == nil || $0.ref === session }
        sessionRegistry.append(WeakRef(session))
    }

    func deregisterSession(_ session: EditorSession) {
        sessionRegistry.removeAll { $0.ref == nil || $0.ref === session }
    }

    /// If the system closed the focused scene, move the global focus pointer
    /// to a surviving editor so the post-close Restore banner has one stable
    /// owner instead of appearing in every Stage Manager window.
    func focusSurvivingSession(excludingSceneUUID sceneUUID: String) {
        guard currentSession?.sceneUUID == sceneUUID else { return }
        let replacement = allOpenSessions.last { $0.sceneUUID != sceneUUID }
        currentSession = replacement
        currentEditor = replacement?.activeTab.state
    }

    /// Read-only; never prune on read — that would be a write inside
    /// a getter, which freezes SwiftUI bindings in a tight
    /// invalidation loop. Stale slots clear next register/deregister.
    var allOpenSessions: [EditorSession] {
        sessionRegistry.compactMap { $0.ref }
    }

    /// iPad multi-window scenePhase ordering is unstable; per-window
    /// chrome calls this on tap so the upcoming sheet / command lands
    /// on the right scene.
    func claimFocus(session: EditorSession) {
        if currentSession !== session { currentSession = session }
        if !session.activeTab.owns(currentEditor) { currentEditor = session.activeTab.state }
    }

    func claimFocus(state: EditorState) {
        if currentEditor !== state { currentEditor = state }
        if let session = currentSession, session.tabs.contains(where: { $0.owns(state) }) {
            return
        }
        for candidate in allOpenSessions where candidate.tabs.contains(where: { $0.owns(state) }) {
            currentSession = candidate
            return
        }
        // Fail closed: a stale currentSession from another window would
        // route OR-gated sheets/pickers to the wrong scene.
        currentSession = nil
    }

    /// Window chrome preserves whichever split pane the user selected.
    func claimFocus(preservingPaneOf state: EditorState) {
        if let session = allOpenSessions.first(where: { $0.activeTab.owns(state) }) {
            claimFocus(session: session)
        } else {
            claimFocus(state: state)
        }
    }

    func session(containing tabID: UUID) -> EditorSession? {
        allOpenSessions.first { $0.tabs.contains { $0.id == tabID } }
    }

    /// Single source of truth for "is this scene the foreground one."
    /// Used to gate per-scene sheets/pickers/alerts so a shared bus flag
    /// surfaces them on the focused window only. EditorView and
    /// EditorScene both call this; keeping the policy here (not inlined
    /// at each call site) is the difference between a one-line edit and
    /// dredging up every modifier when the focus model evolves.
    func isActive(_ state: EditorState) -> Bool {
        currentEditor === state || currentEditor?.siblingState === state
    }


}

enum SceneID: String {
    case editor
    case preferences
    case multiFileSearch = "multi-file-search"
    case fileBrowser     = "file-browser"
    case markdownPreview = "markdown-preview"
}

/// `rawValue` must match the `UIApplicationShortcutItemType` strings
/// declared in Info.plist under `UIApplicationShortcutItems`.
enum HomeShortcut: String {
    case newFile        = "com.palefire.pilcrow.shortcut.newFile"
    case commandPalette = "com.palefire.pilcrow.shortcut.commandPalette"
}
