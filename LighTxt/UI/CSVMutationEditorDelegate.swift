import Foundation

/// Optional CSV mutation capability layered on the general viewport editor
/// delegate. Keeping this separate lets non-CSV renderers and focused editor
/// harnesses remain independent from the CSV transformation engine.
@MainActor
protocol CSVMutationEditorDelegate: VirtualTextEditorDelegate {
    /// Installs source-coordinate row edits as one undoable transaction.
    /// Completion is always delivered on the main actor.
    func editorApplyCSVRowEdits(
        _ edits: [ByteEdit],
        replacing snapshot: DocumentSnapshot,
        completion: @escaping (Result<Void, Error>) -> Void
    )

    /// Streams a whole-column rewrite in bounded memory. Progress and
    /// completion are always delivered on the main actor.
    func editorApplyCSVColumnMutation(
        _ mutation: CSVColumnMutation,
        snapshot: DocumentSnapshot,
        index: CSVRowIndex,
        progress: @escaping (CSVColumnRewriteProgress) -> Void,
        completion: @escaping (Result<CSVColumnRewriteResult, Error>) -> Void
    )

    func editorCancelCSVMutation()
}
