import Testing
@testable import BusySignCore

/// Dry run removes nothing (Ruling 19): the calendars an Apply there would clear wait for Live (`PendingRemovals`).
@Suite struct PendingRemovalsTests {
    let a = CalendarRef(id: "a")
    let b = CalendarRef(id: "b")
    let c = CalendarRef(id: "c")
    let d = CalendarRef(id: "d")
    let gone = CalendarRef(id: "gone")
    var listed: Set<CalendarRef> { [a, b, c, d] }

    func afterApply(_ pending: [CalendarRef], selecting selected: [CalendarRef], clearing: [CalendarRef],
                    mode: SyncMode = .dryRun) -> [CalendarRef] {
        PendingRemovals.afterApply(pending, selecting: selected, listed: listed, clearing: clearing, mode: mode)
    }

    /// In Dry run the calendars Apply clears wait for Live, after the ones waiting already, each once.
    @Test func dryRunApplyMakesTheClearedCalendarsPending() {
        // c unticked of a, b and c.
        #expect(afterApply([], selecting: [a, b], clearing: [c]) == [c])
        // b unticked of a and b: syncing stops, and a, left alone, waits too.
        #expect(afterApply([c], selecting: [a], clearing: [b, a]) == [c, b, a])
        // a, waiting already, unticked as well.
        #expect(afterApply([b, a], selecting: [], clearing: [a]) == [b, a])
        // An Apply that clears nothing keeps them.
        #expect(afterApply([c], selecting: [a, b], clearing: []) == [c])
    }

    /// In Live Apply removes the calendars it clears at once, so none join; the ones waiting stay.
    @Test func liveApplyMakesNothingPending() {
        #expect(afterApply([], selecting: [a, b], clearing: [c], mode: .live) == [])
        #expect(afterApply([d], selecting: [a, b], clearing: [c], mode: .live) == [d])
    }

    /// Ticked again in a selection that syncs, a calendar leaves: runs reconcile its Busy blocks from then on. That
    /// also goes for the one left alone when syncing stopped, which was never unticked.
    @Test func tickedInASelectionThatSyncsLeaves() {
        #expect(afterApply([c], selecting: [a, b, c], clearing: []) == [])
        #expect(afterApply([c], selecting: [a, b, c], clearing: [], mode: .live) == [])
        // b ticked again next to a: both sync again.
        #expect(afterApply([b, a], selecting: [a, b], clearing: []) == [])
        // d ticked next to a: a syncs again, b still waits.
        #expect(afterApply([b, a], selecting: [a, d], clearing: []) == [b])
        // Ticked anew while another is unticked: the unticked one takes its place.
        #expect(afterApply([c], selecting: [a, c], clearing: [b]) == [b])
        // Never joins while ticked in a selection that syncs: Apply's removal in Live, deferred once the mode is Dry
        // run again (`AppModel.liveRemovalStillWanted`), for a calendar ticked again meanwhile.
        #expect(afterApply([], selecting: [a, b, c], clearing: [c, d]) == [d])
    }

    /// Ticked in a selection with fewer than two calendars Calendar lists, it stays: no run sweeps it.
    @Test func tickedInASelectionThatDoesNotSyncStays() {
        // Only Look ahead changes while a is ticked alone.
        #expect(afterApply([b, a], selecting: [a], clearing: []) == [b, a])
        // b ticked alone instead of a.
        #expect(afterApply([b, a], selecting: [b], clearing: [a]) == [b, a])
        // Two ticked, but one of them is not listed.
        #expect(afterApply([b, a], selecting: [a, gone], clearing: []) == [b, a])
    }

    /// Without an Apply, a change of the listing can make the applied selection sync again: a, waiting since b was
    /// unticked while x was not listed, is ticked next to x once x is back, so it leaves; b stays. While x is still
    /// missing nothing changes. The same rule as an Apply's, applied to the selection as it is.
    @Test func listingThatMakesTheSelectionSyncFreesTheCalendarsTickedInIt() {
        let x = CalendarRef(id: "x")
        #expect(PendingRemovals.stillWaiting([a, b], selected: [a, x], listed: [a, b, x]) == [b])
        #expect(PendingRemovals.stillWaiting([a, b], selected: [a, x], listed: [a, b]) == [a, b])
        #expect(PendingRemovals.stillWaiting([b], selected: [a, x], listed: [a, b, x]) == [b])
        #expect(PendingRemovals.stillWaiting([], selected: [a, x], listed: [a, x]) == [])
    }

    /// A removal that went ahead drops the calendars it covered: the ones it removed from once nothing failed, since
    /// a failure names no calendar, and the ones Calendar no longer lists, which hold nothing to remove.
    @Test func removalDropsWhatItCovered() {
        #expect(PendingRemovals.afterRemoval([c, d], present: [a, c], missing: [], failed: false) == [d])
        #expect(PendingRemovals.afterRemoval([c, d], present: [a, c, d], missing: [], failed: true) == [c, d])
        #expect(PendingRemovals.afterRemoval([c, gone], present: [a, c], missing: [gone], failed: true) == [c])
        #expect(PendingRemovals.afterRemoval([], present: [a], missing: [], failed: false) == [])
    }

    /// Counts from a read of the copies (`SyncEngine.countCopies`): a calendar Calendar does not list holds none, so
    /// it never keeps Live waiting.
    @Test func countsOfAReadCoverEveryPendingCalendar() {
        #expect(PendingRemovals.counts(of: [c, gone], read: [c: 4, a: 9]) == [c: 4, gone: 0])
        #expect(PendingRemovals.counts(of: [], read: [c: 4]) == [:])
        #expect(PendingRemovals.allCounted([c, gone], counts: [c: 4, gone: 0]))
        #expect(!PendingRemovals.allCounted([c, gone], counts: [c: 4]))
        #expect(!PendingRemovals.allCounted([c], counts: nil))
        #expect(PendingRemovals.allCounted([], counts: nil))
    }

    /// After an Apply: the known counts of the calendars still waiting stay, a calendar that joins takes the
    /// preview's count (fresher than one known before), and one that left goes; nil when none is known.
    @Test func countsAfterApply() {
        #expect(PendingRemovals.countsAfterApply([c: 4, d: 2], pending: [c, b], removals: [b: 7, a: 1]) == [c: 4, b: 7])
        #expect(PendingRemovals.countsAfterApply([a: 3], pending: [a], removals: [a: 5]) == [a: 5])
        #expect(PendingRemovals.countsAfterApply(nil, pending: [c, b], removals: [b: 7]) == [b: 7])
        #expect(PendingRemovals.countsAfterApply(nil, pending: [c], removals: [:]) == nil)
        #expect(PendingRemovals.countsAfterApply([c: 4], pending: [], removals: [c: 4]) == nil)
    }
}
