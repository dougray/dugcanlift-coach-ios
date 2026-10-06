import Foundation

/// A recipe Safari handed over, waiting for the coach to review it.
struct QueuedRecipe: Identifiable, Equatable {
    let id = UUID()
    let item: PendingRecipeImports.Item
}

/// When a recipe Safari handed over may open, as a value type with no view in
/// it: the rule MacroFields follows, because a rule in a view's `@State`
/// cannot be tested and this one decides whether a recipe is lost -- the file
/// queue is emptied the moment it is drained.
///
/// SwiftUI shows one presentation at a time on a view and silently drops a
/// second one, so a recipe must never be offered while an alert, the Paste a
/// Link sheet, or a sheet RootView cannot see is up. Three things follow:
///
/// - `next(canPresent:)` offers nothing unless the caller says it is clear.
/// - A sheet that was offered but never appeared (`markAppeared` never came)
///   was dropped; `activated()` puts it back at the front for another try.
/// - A link report arriving while a recipe is under review would be dropped
///   the same way, so it is held and shown when the review ends, before the
///   next recipe.
///
/// `Report` is whatever the caller shows for a link import; it is only held.
struct RecipeReviewQueue<Report> {

    private(set) var waiting: [QueuedRecipe] = []
    private(set) var reviewing: QueuedRecipe?
    private(set) var reviewingAppeared = false
    private(set) var heldReport: Report?

    mutating func enqueue(_ items: [PendingRecipeImports.Item]) {
        waiting += items.map { QueuedRecipe(item: $0) }
    }

    /// Starts the next review, only when nothing is under review and the
    /// caller has nothing else on screen.
    mutating func next(canPresent: Bool) -> QueuedRecipe? {
        guard canPresent, reviewing == nil, !waiting.isEmpty else { return nil }
        let queued = waiting.removeFirst()
        reviewing = queued
        reviewingAppeared = false
        return queued
    }

    /// The review sheet's content came on screen.
    mutating func markAppeared() {
        if reviewing != nil { reviewingAppeared = true }
    }

    /// The app became active. A review that never appeared was dropped by
    /// SwiftUI and will never report its own dismissal: retry it first.
    mutating func activated() {
        guard let stuck = reviewing, !reviewingAppeared else { return }
        waiting.insert(stuck, at: 0)
        reviewing = nil
    }

    /// The review sheet closed. True when this ended a review, so the caller
    /// advances once however many times SwiftUI says it closed.
    @discardableResult
    mutating func dismissed() -> Bool {
        guard reviewing != nil else { return false }
        reviewing = nil
        reviewingAppeared = false
        return true
    }

    /// A link report is ready: returned to be shown now, or held (nil) while a
    /// recipe is under review. A second report held over the first replaces it;
    /// both imports have already happened and the Roster shows them.
    mutating func report(_ report: Report) -> Report? {
        guard reviewing != nil else { return report }
        heldReport = report
        return nil
    }

    mutating func takeHeldReport() -> Report? {
        defer { heldReport = nil }
        return heldReport
    }
}
