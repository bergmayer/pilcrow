import Observation

/// One pending picker at a time — a single optional, not a flag per
/// intent, so two pickers can never both think they're presenting.
@MainActor
@Observable
final class PickerIntents {

    var pending: PickerIntent?


}

enum PickerIntent: Equatable, Sendable {
    case open
    case saveAs
    case insertFile
    case insertFolder
}
