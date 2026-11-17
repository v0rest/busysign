import Foundation

/// The calendars whose Busy blocks wait for Live (Ruling 19). Dry run writes nothing, so an Apply there removes no
/// Busy blocks: the calendars it would have cleared wait instead, until the switch to Live removes their blocks,
/// "Remove all Busy copies" does in any mode, or an Apply ticks them again in a selection that syncs. Calendar ids
/// and counts only.
public enum PendingRemovals {
    /// The calendars waiting once Apply has made `selected` the applied selection, from `pending` before it.
    /// `clearing`: the calendars Apply clears, the ones it unticks and, when syncing stops, the ones left
    /// (`AppModel.clearing(applying:)`). `listed`: the calendars Calendar lists.
    ///
    /// A waiting calendar leaves when `selected` ticks it and at least two calendars of `selected` are listed: runs
    /// reconcile its Busy blocks from then on. That also frees the one left alone when syncing stopped, which was never
    /// unticked. Ticked in a selection with fewer, it stays, since no run sweeps it. In Dry run the calendars of
    /// `clearing` join, after the ones waiting already, each once; in Live Apply removes them at once, so none join.
    /// None joins while ticked in a selection that syncs, which an Apply's own `clearing` never is; the app also leaves
    /// Apply's removal in Live to Live this way once the mode is Dry run again before it runs.
    public static func afterApply(_ pending: [CalendarRef], selecting selected: [CalendarRef], listed: Set<CalendarRef>,
                                  clearing: [CalendarRef], mode: SyncMode) -> [CalendarRef] {
        let ticked = Set(selected)
        let syncs = ticked.intersection(listed).count >= 2
        var seen = Set<CalendarRef>()
        return (pending + (mode == .dryRun ? clearing : [])).filter {
            !(syncs && ticked.contains($0)) && seen.insert($0).inserted
        }
    }

    /// The calendars still waiting for the applied selection `selected` as Calendar lists calendars now (`listed`):
    /// the leave rule of `afterApply` without an Apply, since a change of the listing alone can make the selection sync
    /// again (a ticked calendar that was missing comes back). One ticked in it then leaves, as runs reconcile it, and
    /// is never cleared. The app applies it whenever the listing changes and before the switch's removal and its
    /// retries.
    public static func stillWaiting(_ pending: [CalendarRef], selected: [CalendarRef],
                                    listed: Set<CalendarRef>) -> [CalendarRef] {
        afterApply(pending, selecting: selected, listed: listed, clearing: [], mode: .live)
    }

    /// The calendars waiting once a removal of Busy copies went ahead: of the ones it covered, `present` (listed,
    /// removed from) leave only when nothing `failed`, since a failure names no calendar, and `missing` (no longer
    /// listed) leave in any case, as they hold nothing to remove; Apply clears no such calendar either.
    public static func afterRemoval(_ pending: [CalendarRef], present: [CalendarRef], missing: [CalendarRef],
                                    failed: Bool) -> [CalendarRef] {
        let done = Set(missing).union(failed ? [] : present)
        return pending.filter { !done.contains($0) }
    }

    /// The count of each of `pending` from a read of the copies (`SyncEngine.countCopies`), which has no entry for a
    /// calendar Calendar does not list: that one holds none, so it never keeps Live waiting.
    public static func counts(of pending: [CalendarRef], read: [CalendarRef: Int]) -> [CalendarRef: Int] {
        Dictionary(pending.map { ($0, read[$0] ?? 0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Whether every one of `pending` has a count; true when none waits.
    public static func allCounted(_ pending: [CalendarRef], counts: [CalendarRef: Int]?) -> Bool {
        pending.allSatisfy { counts?[$0] != nil }
    }

    /// The counts once an Apply leaves `pending` waiting: the ones known before for calendars still waiting, and for
    /// each that the Apply's preview counted (`ChangePreview.removals`, the calendars it clears) that count, which is
    /// fresher. Nil when none is known.
    public static func countsAfterApply(_ counts: [CalendarRef: Int]?, pending: [CalendarRef],
                                        removals: [CalendarRef: Int]) -> [CalendarRef: Int]? {
        var next: [CalendarRef: Int] = [:]
        for ref in pending {
            if let count = removals[ref] ?? counts?[ref] { next[ref] = count }
        }
        return next.isEmpty ? nil : next
    }
}
