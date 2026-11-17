import Foundation
import Testing
@testable import BusySignCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let window = DateInterval(start: t0 - 86_400, duration: 30 * 86_400)
private let A = CalendarRef(id: "A")
private let B = CalendarRef(id: "B")
private let C = CalendarRef(id: "C")

private func settings(_ cals: [CalendarRef] = [A, B], unanswered: Bool = false) -> SyncSettings {
    SyncSettings(selected: cals, lookAheadDays: 30, unansweredAsBusy: unanswered)
}

private func orig(_ cal: String, _ ext: String? = "ext", local: String? = nil, start: Date = t0,
                  end: Date? = nil, allDay: Bool = false, availability: Availability = .busy,
                  response: MyResponse = .accepted) -> EventSnapshot {
    snap(calendar: cal, localID: local ?? "\(cal)-\(ext ?? "none")", externalID: ext, occurrenceDate: start,
         start: start, end: end ?? start + 3600, isAllDay: allDay, availability: availability, myResponse: response)
}

private func copy(_ cal: String, of o: EventSnapshot, local: String, ext: String? = nil,
                  start: Date? = nil, end: Date? = nil, allDay: Bool? = nil) -> EventSnapshot {
    snap(calendar: cal, localID: local, externalID: ext, start: start ?? o.start, end: end ?? o.end,
         isAllDay: allDay ?? o.isAllDay, marker: Marker.make(for: o))
}

private func changes(_ events: [EventSnapshot], _ s: SyncSettings = settings()) -> [PlannedChange] {
    plannedChanges(for: reconcile(events: events, settings: s, window: window), events: events, settings: s,
                   window: window)
}

private func notBusy(_ events: [EventSnapshot], _ s: SyncSettings = settings()) -> [SkippedOriginal] {
    notBusyOriginals(events: events, settings: s, window: window)
}

private func skipped(_ o: EventSnapshot, _ reason: SkippedOriginal.Reason) -> SkippedOriginal {
    SkippedOriginal(calendar: o.calendar, localID: o.localID, start: o.start, end: o.end, isAllDay: o.isAllDay,
                    reason: reason, occurrenceKey: ExclusionKey.occurrence(for: o),
                    seriesKey: ExclusionKey.series(for: o), includeKey: ExclusionKey.include(for: o))
}

// MARK: - changes

@Suite struct PlannedChangesTests {
    @Test func addCarriesSourceAndTimes() {
        let a = orig("A", "a")
        #expect(changes([a]) == [
            PlannedChange(kind: .add, target: B, start: a.start, end: a.end, isAllDay: false,
                          source: A, sourceLocalID: a.localID, occurrenceKey: ExclusionKey.occurrence(for: a),
                          includeKey: ExclusionKey.include(for: a)),
        ])
    }

    @Test func sortedByStartThenTargetID() {
        let c = orig("C", "c", start: t0)
        let a = orig("A", "a", start: t0 + 3600)
        let b = orig("B", "b", start: t0 + 7200)
        let r = changes([b, a, c], settings([C, B, A]))
        #expect(r.allSatisfy { $0.kind == .add })
        #expect(r.map { "\($0.target.id)@\(Int($0.start.timeIntervalSince(t0)))" }
            == ["A@0", "B@0", "B@3600", "C@3600", "A@7200", "C@7200"])
        #expect(r.map(\.sourceLocalID) == [c.localID, c.localID, a.localID, a.localID, b.localID, b.localID])
    }

    @Test func moveCarriesPreviousTimes() {
        let a = orig("A", "a")
        let old = copy("B", of: a, local: "c1", ext: "x", start: t0 - 7200, end: t0 - 3600)
        #expect(changes([a, old]) == [
            PlannedChange(kind: .move, target: B, start: a.start, end: a.end, isAllDay: false,
                          previousStart: t0 - 7200, previousEnd: t0 - 3600, previousIsAllDay: false,
                          source: A, sourceLocalID: a.localID, occurrenceKey: ExclusionKey.occurrence(for: a),
                          includeKey: ExclusionKey.include(for: a)),
        ])
    }

    @Test func moveFromTimedToAllDay() {
        let a = orig("A", "a", end: t0 + 86_400, allDay: true)
        let old = copy("B", of: a, local: "c1", ext: "x", allDay: false)
        #expect(changes([a, old]) == [
            PlannedChange(kind: .move, target: B, start: a.start, end: a.end, isAllDay: true,
                          previousStart: a.start, previousEnd: a.end, previousIsAllDay: false,
                          source: A, sourceLocalID: a.localID, occurrenceKey: ExclusionKey.occurrence(for: a),
                          includeKey: ExclusionKey.include(for: a)),
        ])
    }

    @Test func removeWhenOriginalIsGone() {
        let gone = orig("A", "gone")
        let c = copy("B", of: gone, local: "c1", ext: "x", start: t0 + 600, end: t0 + 1200)
        #expect(changes([c]) == [
            PlannedChange(kind: .remove, target: B, start: t0 + 600, end: t0 + 1200, isAllDay: false),
        ])
    }

    @Test func removeNamesAnOriginalThatIsStillVisible() {
        let a = orig("A", "a", response: .declined)
        let c = copy("B", of: a, local: "c1", ext: "x")
        #expect(changes([a, c]) == [
            PlannedChange(kind: .remove, target: B, start: a.start, end: a.end, isAllDay: false,
                          source: A, sourceLocalID: a.localID, occurrenceKey: ExclusionKey.occurrence(for: a),
                          includeKey: ExclusionKey.include(for: a)),
        ])
    }

    @Test func removeWhenRealEventTakesTheSlot() {
        let a = orig("A", "a")
        let real = orig("B", "b", start: a.start, end: a.end)
        let existing = copy("B", of: a, local: "c1", ext: "x")
        #expect(changes([a, real, existing]) == [
            PlannedChange(kind: .remove, target: B, start: a.start, end: a.end, isAllDay: false,
                          source: A, sourceLocalID: a.localID, occurrenceKey: ExclusionKey.occurrence(for: a),
                          includeKey: ExclusionKey.include(for: a)),
        ])
    }

    /// A copy in B is never of B's own original: with the marker's only original in B, the original is
    /// unknown.
    @Test func removeNeverNamesAnOriginalInTheTarget() {
        let gone = orig("A", "x", local: "la")
        let inB = orig("B", "x", local: "lb", start: t0 + 3600, response: .declined)
        let c = copy("B", of: gone, local: "c1", ext: "e")
        #expect(changes([inB, c]) == [
            PlannedChange(kind: .remove, target: B, start: gone.start, end: gone.end, isAllDay: false),
        ])
    }

    @Test func removeOfSeveralCopiesIsOneEntryWithTheEarliestTimes() {
        let gone = orig("A", "gone")
        let late = copy("B", of: gone, local: "c1", ext: "x1", start: t0 + 3600, end: t0 + 7200)
        let early = copy("B", of: gone, local: "c2", ext: "x2", start: t0, end: t0 + 3600)
        #expect(changes([late, early]) == [
            PlannedChange(kind: .remove, target: B, start: t0, end: t0 + 3600, isAllDay: false, duplicatesRemoved: 1),
        ])
    }

    @Test func duplicatesOfAnUnchangedCopyAreOneEntry() {
        let a = orig("A", "a")
        let keep = copy("B", of: a, local: "z-high", ext: "ext-1")
        let drop1 = copy("B", of: a, local: "a-low", ext: "ext-2")
        let drop2 = copy("B", of: a, local: "b-low", ext: "ext-3")
        #expect(changes([a, drop1, keep, drop2]) == [
            PlannedChange(kind: .removeDuplicates, target: B, start: a.start, end: a.end, isAllDay: false,
                          source: A, sourceLocalID: a.localID, duplicatesRemoved: 2,
                          occurrenceKey: ExclusionKey.occurrence(for: a), includeKey: ExclusionKey.include(for: a)),
        ])
    }

    @Test func moveFoldsInItsDuplicates() {
        let a = orig("A", "a")
        let keep = copy("B", of: a, local: "z", ext: "e1", start: t0 - 7200, end: t0 - 3600)
        let drop = copy("B", of: a, local: "a", ext: "e2", start: t0 - 7200, end: t0 - 3600)
        #expect(changes([a, drop, keep]) == [
            PlannedChange(kind: .move, target: B, start: a.start, end: a.end, isAllDay: false,
                          previousStart: t0 - 7200, previousEnd: t0 - 3600, previousIsAllDay: false,
                          source: A, sourceLocalID: a.localID, duplicatesRemoved: 1,
                          occurrenceKey: ExclusionKey.occurrence(for: a), includeKey: ExclusionKey.include(for: a)),
        ])
    }

    @Test func sourceIsTheReconcilersSameMarkerWinner() {
        let a = orig("A", "x", local: "la", start: t0 + 7200)
        let b = orig("B", "x", local: "lb", start: t0)
        let r = changes([a, b], settings([A, B, C]))
        #expect(r.filter { $0.target == C } == [
            PlannedChange(kind: .add, target: C, start: b.start, end: b.end, isAllDay: false,
                          source: B, sourceLocalID: "lb", occurrenceKey: ExclusionKey.occurrence(for: b),
                          includeKey: ExclusionKey.include(for: b)),
        ])
        #expect(r.filter { $0.target == B }.map(\.sourceLocalID) == ["la"])
        #expect(r.filter { $0.target == A }.map(\.sourceLocalID) == ["lb"])
    }

    @Test func sameMarkerTieBreaksOnCalendarID() {
        let a = orig("A", "x", local: "la")
        let b = orig("B", "x", local: "lb")
        #expect(changes([b, a], settings([A, B, C])) == [
            PlannedChange(kind: .add, target: C, start: a.start, end: a.end, isAllDay: false,
                          source: A, sourceLocalID: "la", occurrenceKey: ExclusionKey.occurrence(for: a),
                          includeKey: ExclusionKey.include(for: a)),
        ])
    }

    /// An earlier original with the same marker that is not busy never wins.
    @Test func sourceIgnoresNonBusyOriginalWithSameMarker() {
        let declined = orig("A", "x", local: "la", start: t0, response: .declined)
        let accepted = orig("B", "x", local: "lb", start: t0 + 3600)
        let r = changes([declined, accepted], settings([A, B, C]))
        #expect(r.filter { $0.target == C }.map(\.sourceLocalID) == ["lb"])
    }

    @Test func emptyWhenNothingToDo() {
        let a = orig("A", "a")
        let c = copy("B", of: a, local: "c1", ext: "x")
        #expect(changes([a, c]).isEmpty)
        #expect(changes([a], settings([A])).isEmpty)
    }

    /// An update whose times stay and whose copy reads another title is a retitle; one whose times change too is
    /// a move.
    @Test func retitleKind() {
        var a = orig("A", "a")
        a.title = "Weekly sync"
        let s = SyncSettings(selected: [A, B], lookAheadDays: 30,
                             copyTitleFormats: [CopyRoute(source: A, target: B): .title])
        func titled(_ e: EventSnapshot, _ title: String) -> EventSnapshot {
            var e = e
            e.title = title
            return e
        }
        let renamed = titled(copy("B", of: a, local: "c1", ext: "x"), "Old name")
        let retitle = PlannedChange(kind: .retitle, target: B, start: a.start, end: a.end, isAllDay: false,
                                    source: A, sourceLocalID: a.localID,
                                    occurrenceKey: ExclusionKey.occurrence(for: a),
                                    includeKey: ExclusionKey.include(for: a))
        #expect(changes([a, renamed], s) == [retitle])

        let movedAndRenamed = titled(copy("B", of: a, local: "c1", ext: "x", start: t0 - 7200, end: t0 - 3600),
                                     "Old name")
        #expect(changes([a, movedAndRenamed], s) == [
            PlannedChange(kind: .move, target: B, start: a.start, end: a.end, isAllDay: false,
                          previousStart: t0 - 7200, previousEnd: t0 - 3600, previousIsAllDay: false,
                          source: A, sourceLocalID: a.localID, occurrenceKey: ExclusionKey.occurrence(for: a),
                          includeKey: ExclusionKey.include(for: a)),
        ])

        // A held title plans nothing, so there is nothing to describe.
        let spec = CopySpec(target: B, marker: Marker.make(for: a)!, start: a.start, end: a.end, isAllDay: false,
                            title: "Weekly sync")
        let held = reconcile(events: [a, renamed], settings: s, window: window, noRetitle: [spec.slotKey])
        #expect(plannedChanges(for: held, events: [a, renamed], settings: s, window: window).isEmpty)
    }

    // MARK: - notBusy

    @Test func everyVerdictReasonIsListedSortedByStart() {
        let busy = orig("A", "busy", start: t0)
        let declined = orig("A", "d", start: t0 + 5 * 3600, response: .declined)
        let free = orig("B", "f", start: t0 + 1 * 3600, availability: .free)
        let pending = orig("A", "p", start: t0 + 4 * 3600, response: .pending)
        let allDay = orig("B", "ad", start: t0 + 2 * 3600, end: t0 + 86_400, allDay: true, availability: .free)
        let unsynced = orig("B", nil, local: "u", start: t0 + 3 * 3600)
        #expect(notBusy([busy, declined, free, pending, allDay, unsynced]) == [
            skipped(free, .free),
            skipped(allDay, .allDayNotBusy),
            skipped(unsynced, .notSyncedYet),
            skipped(pending, .pendingInvitation),
            skipped(declined, .declined),
        ])
    }

    @Test func exchangePendingTentativeIsListedUntilTheSettingIsOn() {
        let invite = orig("A", "inv", availability: .tentative, response: .pending)
        #expect(notBusy([invite]) == [skipped(invite, .pendingInvitation)])
        #expect(notBusy([invite], settings(unanswered: true)).isEmpty)
    }

    @Test func notSyncedYetComesAfterTheVerdict() {
        let declinedUnsynced = orig("A", nil, local: "u", response: .declined)
        #expect(notBusy([declinedUnsynced]) == [skipped(declinedUnsynced, .declined)])
    }

    @Test func sameSlotWithTwoCalendars() {
        let a = orig("A", "a")
        let real = orig("B", "b", start: a.start, end: a.end)
        #expect(notBusy([a, real]) == [skipped(a, .sameSlot(in: B)), skipped(real, .sameSlot(in: A))])
    }

    @Test func sameSlotNamesTheFirstOtherCalendarInSelectionOrder() {
        let a = orig("A", "a")
        let inB = orig("B", "b", start: a.start, end: a.end)
        let inC = orig("C", "c", start: a.start, end: a.end)
        let r = notBusy([a, inB, inC], settings([C, B, A]))
        #expect(r.first { $0.localID == a.localID }?.reason == .sameSlot(in: C))
        #expect(r.first { $0.localID == inB.localID }?.reason == .sameSlot(in: C))
        #expect(r.first { $0.localID == inC.localID }?.reason == .sameSlot(in: B))
        #expect(r.count == 3)
    }

    /// Suppressed in one calendar but copied into another: partly mirrored, not listed.
    @Test func partlyMirroredIsNotListed() {
        let a = orig("A", "a")
        let real = orig("B", "b", start: a.start, end: a.end)
        #expect(notBusy([a, real], settings([A, B, C])).isEmpty)
    }

    /// The same event in two calendars: the loser's busy time reaches C through the winner's copy, so it
    /// is listed as copied from the winner's calendar.
    @Test func sameMarkerLoserIsListedAsCopiedFrom() {
        let a = orig("A", "x", local: "la")
        let b = orig("B", "x", local: "lb")
        #expect(notBusy([a, b], settings([A, B, C])) == [skipped(b, .copiedFrom(A))])
        #expect(notBusy([a, b]) == [skipped(a, .sameSlot(in: B)), skipped(b, .sameSlot(in: A))])
    }

    @Test func copiesUnselectedAndOutsideWindowAreNotListed() {
        let a = orig("A", "a")
        let ownCopy = copy("B", of: a, local: "c1", ext: "x")
        let unselected = orig("C", "c", response: .declined)
        let after = orig("A", "late", start: window.end, response: .declined)
        let before = orig("A", "early", start: window.start - 3600, end: window.start, response: .declined)
        #expect(notBusy([a, ownCopy, unselected, after, before]).isEmpty)
    }

    @Test func busyMirroredOriginalsAreNotListed() {
        #expect(notBusy([orig("A", "a"), orig("B", "b", start: t0 + 3600)]).isEmpty)
    }

    @Test func nothingListedWithFewerThanTwoCalendars() {
        #expect(notBusy([orig("A", "a", response: .declined)], settings([A])).isEmpty)
    }
}
