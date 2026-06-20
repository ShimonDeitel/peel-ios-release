import SwiftUI

/// Command-based undo/redo over the layer model. Replaces the old all-or-nothing `resetAll`: every edit
/// the user makes is pushed as a reversible snapshot, so a single tap steps back through *granular*
/// changes (move a layer, change one slider, swap an outline) instead of nuking the whole project.
///
/// The model is small and value-typed (`StickerEdit` is `Equatable`/`Codable`), so the pragmatic,
/// bullet-proof representation of a "command" is a before→after snapshot pair. `undo`/`redo` just swap
/// the live edit for the stored snapshot. Coalescing collapses a rapid run of the SAME continuous
/// gesture (e.g. dragging one slider) into one history entry so undo doesn't replay every frame.
@MainActor
final class History: ObservableObject {

    /// One reversible step: the edit BEFORE and AFTER a user action, plus a tag used for coalescing.
    private struct Step {
        var before: StickerEdit
        var after: StickerEdit
        var tag: String?            // continuous-gesture key (e.g. "slider.brightness"); nil = atomic
        var time: Date
    }

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [Step] = []
    private var redoStack: [Step] = []

    /// Snapshot the live edit BEFORE applying a change, so the next `commit` knows where it came from.
    private var pending: StickerEdit?

    private let maxDepth = 80
    /// Continuous edits with the same tag within this window fold into the previous step.
    private let coalesceWindow: TimeInterval = 0.8

    // MARK: - Recording

    /// Call once right before mutating the edit (e.g. at gesture-begin or a control's first change).
    func begin(from edit: StickerEdit) {
        if pending == nil { pending = edit }
    }

    /// Record the completed change. `tag` lets a continuous control coalesce its run into one undo step;
    /// pass `nil` for atomic actions (add layer, apply template, toggle outline). No-ops when nothing
    /// actually changed.
    func commit(_ newEdit: StickerEdit, from oldEdit: StickerEdit? = nil, tag: String? = nil) {
        let before = pending ?? oldEdit ?? newEdit
        pending = nil
        guard before != newEdit else { return }    // nothing changed — don't pollute history

        // Coalesce: same tag, recent, into the top step (extend its `after`, keep the original `before`).
        if let tag,
           var top = undoStack.last,
           top.tag == tag,
           Date().timeIntervalSince(top.time) < coalesceWindow {
            top.after = newEdit
            top.time = Date()
            undoStack[undoStack.count - 1] = top
            redoStack.removeAll()
            refresh()
            return
        }

        undoStack.append(Step(before: before, after: newEdit, tag: tag, time: Date()))
        if undoStack.count > maxDepth { undoStack.removeFirst(undoStack.count - maxDepth) }
        redoStack.removeAll()
        refresh()
    }

    /// Convenience: record an atomic change in one call (snapshots `before` itself).
    func record(before: StickerEdit, after: StickerEdit, tag: String? = nil) {
        pending = before
        commit(after, tag: tag)
    }

    // MARK: - Undo / Redo

    /// Step back. Returns the edit to install, or `nil` when there's nothing to undo.
    func undo() -> StickerEdit? {
        guard let step = undoStack.popLast() else { return nil }
        redoStack.append(step)
        refresh()
        Haptics.tap()
        return step.before
    }

    /// Step forward. Returns the edit to install, or `nil` when there's nothing to redo.
    func redo() -> StickerEdit? {
        guard let step = redoStack.popLast() else { return nil }
        undoStack.append(step)
        refresh()
        Haptics.tap()
        return step.after
    }

    /// Drop all history (e.g. when opening a different project). Does not touch the live edit.
    func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
        pending = nil
        refresh()
    }

    private func refresh() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }
}
