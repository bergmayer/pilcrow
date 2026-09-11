import Foundation

/// Shared @Observable state, split per domain so a view that reads
/// find context doesn't re-render when an unrelated palette flag
/// flips. Children are `var` so call sites can build writable
/// `Binding`s through @Bindable.
@MainActor
@Observable
final class AppStateBus: CommandContext {

    static let shared = AppStateBus()

    var find    = FindState()
    var scenes  = SceneRouter()
    @ObservationIgnored private let unownedPickers = PickerIntents()
    var pickers: PickerIntents { scenes.currentSession?.pickers ?? unownedPickers }
    var presentation = PresentationState()

    private init() {}
}

/// DI seam for `CommandActions`. Production passes the bus; tests
/// swap in a stub via `CommandActions.context = stub`.
@MainActor
protocol CommandContext: AnyObject {
    var find: FindState     { get }
    var scenes: SceneRouter  { get }
    var pickers: PickerIntents { get }
    var presentation: PresentationState  { get }
}

@MainActor
final class WeakRef<T: AnyObject> {
    weak var ref: T?
    init(_ ref: T?) { self.ref = ref }
}
