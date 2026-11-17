import Foundation

/// What applying staged settings would do, worked out as a dry run of them (`SyncEngine.preview`): counts only.
public struct ChangePreview: Equatable, Sendable {
    /// What the dry run plans: creates, deletes (`SyncResult.plannedCounts`) and retitles
    /// (`SyncResult.plannedRetitles`), past the empty-read hold while it holds (`heldReason`). 0 while syncing stops
    /// or the plan is skipped.
    public var add: Int
    public var remove: Int
    public var retitle: Int
    /// Per calendar Apply clears: the Busy copies in it from today to +400 days, as "Remove all Busy copies"
    /// finds them, which Apply removes in Live and leaves to the switch to Live in Dry run (`PendingRemovals`). A
    /// calendar Calendar does not list has no entry.
    public var removals: [CalendarRef: Int]
    /// Fewer than two calendars stay ticked: nothing is planned, and the calendar left is cleared too.
    public var syncingStops: Bool
    /// Why the counts could not all be worked out: the reason the dry run would skip (`SyncEngine`), or why the
    /// copies to remove could not be read. Nil when every count holds. Apply waits until it is nil.
    public var skippedReason: String?
    /// `SyncEngine.emptyRead` while the empty-read guard holds a calendar back that previews have found held for
    /// less than the hold (`SyncEngine.preview`): the counts are those of the run once the hold has passed, which a
    /// preview plans instead of skipping, since it never arms the guard. Nil otherwise. Runs keep holding. Apply
    /// waits until a later preview is not held (the preview's own wait has passed or the events are back), except
    /// for a shorter staged look-ahead (`heldPreviewIsApplicable`).
    public var heldReason: String?
    /// The calendars that make the preview held, in selection order: not one whose hold has passed already, nor
    /// one previews have found held for the whole hold; the counts take those as emptied too. Empty when nothing
    /// is held.
    public var heldCalendars: [CalendarRef]

    public init(add: Int = 0, remove: Int = 0, retitle: Int = 0, removals: [CalendarRef: Int] = [:],
                syncingStops: Bool = false, skippedReason: String? = nil, heldReason: String? = nil,
                heldCalendars: [CalendarRef] = []) {
        self.add = add
        self.remove = remove
        self.retitle = retitle
        self.removals = removals
        self.syncingStops = syncingStops
        self.skippedReason = skippedReason
        self.heldReason = heldReason
        self.heldCalendars = heldCalendars
    }

    /// How long to wait before working a preview out again when the latest one cannot be applied (a skip reason,
    /// a missing removal count, a hold): every 10 s for the first minute (`elapsed`) since the first such preview,
    /// then every 60 s.
    public static func retryDelay(sinceFirstUnusable elapsed: TimeInterval) -> TimeInterval {
        elapsed < 60 ? 10 : 60
    }
}

/// Whether Apply may act at once on the counts of a held preview (`ChangePreview.heldReason`, Ruling 18): only when
/// the staged look-ahead is shorter than the applied one. A calendar can easily have no meeting of its own in the
/// shorter window while the runs of the longer one read its meetings, so the hold is the shorter window's false
/// alarm. Otherwise Apply waits for the preview's own wait (`SyncEngine.preview`) or for the events to come back.
public func heldPreviewIsApplicable(stagedLookAheadDays: Int, appliedLookAheadDays: Int) -> Bool {
    stagedLookAheadDays < appliedLookAheadDays
}
