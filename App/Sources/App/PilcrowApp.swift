import SwiftUI
import UIKit

@main
struct PilcrowApp: App {

    /// Bridges UIKit's quick-action callbacks (Info.plist
    /// `UIApplicationShortcutItems`) into `AppStateBus.pendingShortcut`
    /// so the SwiftUI scene system can react.
    @UIApplicationDelegateAdaptor(AppDelegateBridge.self) private var appDelegate

    init() {
        AppPreferenceDefaults.register()
        TemplatesStore.shared.seedIfNeeded()
        Task { @MainActor in
            await DraftsStore.shared.migrateLegacyRecovery()
        }
    }

    var body: some Scene {
        WindowGroup(
            "Editor",
            id: SceneID.editor.rawValue,
            for: EditorRoute.self
        ) { route in
            EditorScene(route: route)
                .background(WindowOpenerInstaller())
        }
        .commands {
            EditorCommands()
        }

        // Settings as a separate scene. On iPadOS this opens as a
        // separate window when invoked via `@Environment(\.openWindow)`.
        WindowGroup("Settings", id: SceneID.preferences.rawValue) {
            PreferencesView()
        }
        .defaultSize(width: 560, height: 460)
        .commandsRemoved()

        // Multi-File Search lives in its own scene so it stays on
        // screen while the user opens result files in editor tabs/
        // windows. Each request captures the originating editor session;
        // its launch identity prevents restoring a stale utility window.
        WindowGroup("Multi-File Search", id: SceneID.multiFileSearch.rawValue, for: UtilityWindowRequest.self) { request in
            MultiFileSearchSheet(request: request.wrappedValue)
        }
        .defaultSize(width: 560, height: 640)
        .commandsRemoved()

        // File Browser as its own scene — the "iPad way" of opening
        // documents. UIDocumentBrowserViewController hosted in a
        // real window (not a modal sheet). The window stays open so
        // the user can pick file after file; each pick spawns a
        // new editor window via `CommandActions.routeOpenURL`.
        WindowGroup("File Browser", id: SceneID.fileBrowser.rawValue, for: UtilityWindowRequest.self) { request in
            FileBrowserScene(request: request.wrappedValue)
        }
        .defaultSize(width: 720, height: 600)
        .commandsRemoved()

        WindowGroup("Markdown Preview", id: SceneID.markdownPreview.rawValue, for: UUID.self) { tabID in
            MarkdownPreviewScene(tabID: tabID.wrappedValue)
        }
        .defaultSize(width: 720, height: 880)
        .commandsRemoved()
    }
}

/// Installed once at the editor `WindowGroup` so non-View callers
/// can spawn named scenes. SwiftUI's `openWindow` action only
/// lives inside a View body; storing it as a process-lifetime
/// closure on `SceneRouter` is the cleanest bridge.
private struct WindowOpenerInstaller: View {

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                guard AppStateBus.shared.scenes.openWindow == nil else { return }
                AppStateBus.shared.scenes.openWindow = { id in
                    switch id {
                    case .editor:
                        openWindow(id: id.rawValue, value: EditorRoute.newDocument())
                    case .fileBrowser, .multiFileSearch:
                        let request = UtilityWindowRequest(launchID: SessionsStore.shared.currentLaunchID,
                            ownerSessionID: AppStateBus.shared.scenes.currentSession?.sceneUUID)
                        openWindow(id: id.rawValue, value: request)
                    default:
                        openWindow(id: id.rawValue)
                    }
                }
                AppStateBus.shared.scenes.openPreviewWindow = { tabID in
                    openWindow(id: SceneID.markdownPreview.rawValue, value: tabID)
                }
                AppStateBus.shared.scenes.openEditorWindow = { route in
                    openWindow(id: SceneID.editor.rawValue, value: route)
                }
            }
    }
}

@MainActor
final class AppDelegateBridge: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let item = options.shortcutItem { apply(item) }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }

    /// Called after iPadOS permanently discards sessions. There is no
    /// confirmation opportunity when the process is already gone. Preserve
    /// any work without an explicit Save/Don’t Save decision as exceptional
    /// recovery; a deliberate close marks its live session before destruction.
    /// If the process was not running at close time, UIKit delivers this on
    /// the next launch and the same recovery path still applies.
    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {
        let backgroundTask = application.beginBackgroundTask(
            withName: "Archive discarded editor windows"
        )
        Task { @MainActor in
            defer {
                if backgroundTask != .invalid {
                    application.endBackgroundTask(backgroundTask)
                }
            }
            for session in sceneSessions {
                let persistentID = session.persistentIdentifier
                if let record = await recoveryRecord(forPersistentIdentifier: persistentID) {
                    _ = ClosedWindowsStore.shared.archive(record)
                    AppStateBus.shared.scenes.focusSurvivingSession(
                        excludingSceneUUID: record.sceneUUID
                    )
                }
                SessionsStore.shared.removeRecord(forPersistentIdentifier: persistentID)
                DraftsStore.shared.enforceCapNow()
            }
        }
    }

    /// When another window keeps the process alive, UIKit may deliver the
    /// discard callback while the closing EditorSession is still registered.
    /// Capture its exact live text synchronously. If teardown has already
    /// deregistered it, EditorScene.onDisappear has persisted the same
    /// information and the stored record is the fallback.
    private func recoveryRecord(
        forPersistentIdentifier persistentID: String
    ) async -> SessionRecord? {
        if let live = AppStateBus.shared.scenes.allOpenSessions.first(where: {
            SessionsStore.shared.persistentIdentifier(
                forSceneUUID: $0.sceneUUID
            ) == persistentID
        }) {
            guard !live.isClosingWindow else { return nil }
            do {
                try await live.checkpointDocuments()
            } catch {
                AppStateBus.shared.presentation.openErrorMessage =
                    "Couldn't finish preserving a closed window: \(error.localizedDescription)"
                return SessionsStore.shared.record(
                    forPersistentIdentifier: persistentID
                )
            }
            guard !live.isClosingWindow else { return nil }
            var record = SessionRecord(scene: live.sceneUUID, session: live)
            record.persistentIdentifier = persistentID
            return record
        }
        return SessionsStore.shared.record(
            forPersistentIdentifier: persistentID
        )
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        apply(shortcutItem)
        completionHandler(true)
    }

    private func apply(_ item: UIApplicationShortcutItem) {
        guard let action = HomeShortcut(rawValue: item.type) else { return }
        AppStateBus.shared.scenes.pendingShortcut = action
    }
}
