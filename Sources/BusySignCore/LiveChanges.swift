import Foundation

/// The changes the Meetings window labels in Live (`meetingsCatalog`'s `lastLiveChanges`), and when they
/// were saved. The app keeps one in memory across runs and passes every run's result to `updated(after:selected:)`.
public struct LiveChanges: Sendable, Equatable {
    public var changes: [PlannedChange]
    /// When the last live run that saved something ran; nil before one did.
    public var at: Date?
    /// Whether `changes` belong to a failure streak: they start with a run that had failures, and later runs
    /// merge into them until the first run without failures has merged too.
    public var hadFailures: Bool

    public init(changes: [PlannedChange] = [], at: Date? = nil, hadFailures: Bool = false) {
        self.changes = changes
        self.at = at
        self.hadFailures = hadFailures
    }

    /// After a run with the calendars `selected`. Only a live run that went ahead with changes counts; any
    /// other, such as the empty run after our own writes, leaves this as it is. The Meetings window labels no
    /// retitle, so `.retitle` entries are dropped first unless they removed duplicates, and a run with nothing
    /// else leaves this as it is too.
    ///
    /// Outside a failure streak, a run's changes replace the stored ones, as they do when it has failures: that
    /// starts a streak with its own changes, never with older ones. In a streak every run merges in, a newer
    /// change of the same target and original (`occurrenceKey`; for a removal without one, its slot) replacing
    /// the older one, and stored changes whose target or source is not in `selected` any more are dropped. The
    /// first run without failures merges too, so the deletes the streak saved stay listed, and ends the
    /// streak; the run after it replaces again. `at` moves only when the run saved something (created, updated,
    /// replaced or deleted a block).
    public func updated(after result: SyncResult, selected: [CalendarRef]) -> LiveChanges {
        let runChanges = result.changes.filter { $0.kind != .retitle || $0.duplicatesRemoved > 0 }
        guard result.mode == .live, result.skippedReason == nil, !runChanges.isEmpty else { return self }
        let report = result.report ?? ApplyReport()
        let saved = report.created + report.updated + report.replaced + report.deleted > 0
        let failed = !report.failures.isEmpty
        let changes: [PlannedChange]
        if hadFailures {
            let inScope = Set(selected)
            let kept = self.changes.filter { inScope.contains($0.target) && ($0.source.map(inScope.contains) ?? true) }
            changes = Self.merged(kept, runChanges)
        } else {
            changes = runChanges
        }
        return LiveChanges(changes: changes, at: saved ? result.at : at, hadFailures: failed)
    }

    /// `older` without the entries `newer` has a change for, plus `newer`, by start, then target id (then
    /// older first, each in its own order).
    private static func merged(_ older: [PlannedChange], _ newer: [PlannedChange]) -> [PlannedChange] {
        let replaced = Set(newer.map(\.blockKey))
        let all = older.filter { !replaced.contains($0.blockKey) } + newer
        return all.enumerated()
            .sorted { ($0.element.start, $0.element.target.id, $0.offset) < ($1.element.start, $1.element.target.id, $1.offset) }
            .map(\.element)
    }
}
