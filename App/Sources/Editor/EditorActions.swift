import EditorEngine

/// App-owned editor view. A concrete type is sufficient: Pilcrow has one
/// editor engine and no alternate conformers or protocol-based test doubles.
/// Per-document editor state belongs here instead of in process-wide statics.
@MainActor
final class PilcrowTextView: EditorEngine.TextView {
    var ignoredSpellingWords: Set<String> = []
}
