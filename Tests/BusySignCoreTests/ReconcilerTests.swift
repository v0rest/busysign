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

private func orig(_ cal: String, _ ext: String = "ext", local: String? = nil, start: Date = t0,
                  end: Date? = nil, allDay: Bool = false, recurring: Bool = false,
                  response: MyResponse = .accepted) -> EventSnapshot {
    snap(calendar: cal, localID: local ?? "\(cal)-\(ext)", externalID: ext, occurrenceDate: start,
         isRecurringOccurrence: recurring, start: start, end: end ?? start + 3600, isAllDay: allDay,
         myResponse: response)
}

private func copy(_ cal: String, of o: EventSnapshot, local: String, ext: String? = nil,
                  start: Date? = nil, end: Date? = nil) -> EventSnapshot {
    snap(calendar: cal, localID: local, externalID: ext, start: start ?? o.start, end: end ?? o.end,
         isAllDay: o.isAllDay, marker: Marker.make(for: o))
}

private func spec(_ target: CalendarRef, of o: EventSnapshot) -> CopySpec {
    CopySpec(target: target, marker: Marker.make(for: o)!, start: o.start, end: o.end, isAllDay: o.isAllDay)
}

@Test func mirrorsBothWays() {
    let a = orig("A", "a"), b = orig("B", "b", start: t0 + 7200)
    let r = reconcile(events: [a, b], settings: settings(), window: window)
    #expect(r == [.create(spec(A, of: b)), .create(spec(B, of: a))])
}

@Test func meshOfThree() {
    let a = orig("A", "a")
    let r = reconcile(events: [a], settings: settings([A, B, C]), window: window)
    #expect(r == [.create(spec(B, of: a)), .create(spec(C, of: a))])
}

@Test func movedOriginalUpdatesCopy() {
    let a = orig("A", "a")
    let old = copy("B", of: a, local: "c1", ext: "x", start: t0 - 7200, end: t0 - 3600)
    let r = reconcile(events: [a, old], settings: settings(), window: window)
    #expect(r == [.update(localID: "c1", spec(B, of: a))])
}

@Test func cancelledOriginalDeletesCopy() {
    let a = orig("A", "a")
    let c = copy("B", of: a, local: "c1", ext: "x")
    #expect(reconcile(events: [c], settings: settings(), window: window) == [.delete(localID: "c1", target: B)])
}

@Test func declinedLaterDeletesCopy() {
    let a = orig("A", "a", response: .declined)
    let c = copy("B", of: a, local: "c1", ext: "x")
    #expect(reconcile(events: [a, c], settings: settings(), window: window) == [.delete(localID: "c1", target: B)])
}

@Test func duplicateCopiesCollapseToOne() {
    let a = orig("A", "a")
    let keep = copy("B", of: a, local: "z-high", ext: "ext-1")
    let drop = copy("B", of: a, local: "a-low", ext: "ext-2")
    let r = reconcile(events: [a, drop, keep], settings: settings(), window: window)
    #expect(r == [.delete(localID: "a-low", target: B)])
}

@Test func duplicateUnsyncedCopyLosesToSynced() {
    let a = orig("A", "a")
    let unsynced = copy("B", of: a, local: "a-low", ext: nil)
    let synced = copy("B", of: a, local: "z-high", ext: "ext-9")
    let r = reconcile(events: [a, unsynced, synced], settings: settings(), window: window)
    #expect(r == [.delete(localID: "a-low", target: B)])
}

@Test func realEventSameSlotSuppressesCopy() {
    let a = orig("A", "a")
    let real = orig("B", "b", start: a.start, end: a.end)
    let existing = copy("B", of: a, local: "c1", ext: "x")
    let r = reconcile(events: [a, real, existing], settings: settings(), window: window)
    // A already holds a busy event in the same slot too, so nothing is created either way.
    #expect(r == [.delete(localID: "c1", target: B)])
    #expect(reconcile(events: [a, real], settings: settings(), window: window).isEmpty)
}

@Test func nonBusyRealEventDoesNotSuppress() {
    let a = orig("A", "a")
    let free = snap(calendar: "B", localID: "r", externalID: "r", start: a.start, end: a.end, availability: .free)
    let declined = snap(calendar: "B", localID: "r2", externalID: "r2", start: a.start, end: a.end, myResponse: .declined)
    let r = reconcile(events: [a, free, declined], settings: settings(), window: window)
    #expect(r == [.create(spec(B, of: a))])
}

@Test func copiesAreNotMirrored() {
    let a = orig("A", "a")
    let c = copy("B", of: a, local: "c1", ext: "x")
    #expect(reconcile(events: [a, c], settings: settings(), window: window).isEmpty)
}

@Test func unselectedCalendarIgnored() {
    let a = orig("A", "a")
    let c1 = orig("C", "c", start: t0 + 7200)
    let cc = copy("C", of: orig("A", "other"), local: "cc", ext: "x")
    let r = reconcile(events: [a, c1, cc], settings: settings(), window: window)
    #expect(r == [.create(spec(B, of: a))])
    #expect(!r.contains { if case .create(let s) = $0 { return s.target == C }
                          if case .update(_, let s) = $0 { return s.target == C }
                          if case .delete(_, let t) = $0 { return t == C }
                          return false })
}

@Test func deselectedSourceCopiesRemoved() {
    let fromC = orig("C", "c")
    let c = copy("A", of: fromC, local: "c1", ext: "x")
    #expect(reconcile(events: [c], settings: settings(), window: window) == [.delete(localID: "c1", target: A)])
}

@Test func copyOutsideWindowUntouched() {
    let far = t0 + 90 * 86_400
    let a = orig("A", "a", start: far)
    let c = copy("B", of: a, local: "c1", ext: "x")
    #expect(reconcile(events: [c], settings: settings(), window: window).isEmpty)
    #expect(reconcile(events: [a], settings: settings(), window: window).isEmpty)
}

@Test func unsyncedOriginalIsSkipped() {
    let a = snap(calendar: "A", localID: "l", externalID: nil)
    #expect(reconcile(events: [a], settings: settings(), window: window).isEmpty)
}

@Test func recurringOccurrencesGetSeparateCopies() {
    let o1 = orig("A", "series", local: "o1", start: t0, recurring: true)
    let o2 = orig("A", "series", local: "o2", start: t0 + 86_400, recurring: true)
    let r = reconcile(events: [o1, o2], settings: settings(), window: window)
    #expect(r == [.create(spec(B, of: o1)), .create(spec(B, of: o2))])
    #expect(spec(B, of: o1).marker != spec(B, of: o2).marker)
}

@Test func allDayCopyStaysAllDay() {
    let a = orig("A", "a", end: t0 + 86_400, allDay: true)
    guard case .create(let s)? = reconcile(events: [a], settings: settings(), window: window).first else {
        Issue.record("expected create"); return
    }
    #expect(s.isAllDay)
}

@Test func copyKeepsAbsoluteTimes() {
    // 2026-10-25 01:00Z, running 3 hours: crosses the European DST end (01:00Z).
    // The copy must carry the original's absolute Dates unchanged.
    let start = Date(timeIntervalSince1970: 1_792_882_800), end = start + 3 * 3600
    let a = orig("A", "a", start: start, end: end)
    let w = DateInterval(start: start - 86_400, duration: 30 * 86_400)
    guard case .create(let s)? = reconcile(events: [a], settings: settings(), window: w).first else {
        Issue.record("expected create"); return
    }
    #expect(s.start == start && s.end == end)
}

@Test func fewerThanTwoSelectedDoesNothing() {
    let a = orig("A", "a")
    #expect(reconcile(events: [a], settings: settings([A]), window: window).isEmpty)
    #expect(reconcile(events: [a], settings: settings([]), window: window).isEmpty)
}

@Test func ordersDeletesUpdatesCreates() {
    let a = orig("A", "a"), b = orig("B", "b", start: t0 + 7200)
    let stale = copy("B", of: orig("X", "gone"), local: "del", ext: "d")
    let old = copy("A", of: b, local: "upd", ext: "u", start: t0 + 1, end: t0 + 2)
    let r = reconcile(events: [a, b, stale, old], settings: settings(), window: window)
    #expect(r == [.delete(localID: "del", target: B), .update(localID: "upd", spec(A, of: b)),
                  .create(spec(B, of: a))])
}

@Test func inProgressCopyOfShortenedOriginalIsDeleted() {
    // Original now ends before the window starts; the copy still reaches into the window.
    let a = orig("A", "a", start: window.start - 7200, end: window.start - 3600)
    let c = copy("B", of: a, local: "c1", ext: "x", start: window.start - 7200, end: window.start + 3600)
    #expect(reconcile(events: [a, c], settings: settings(), window: window) == [.delete(localID: "c1", target: B)])
}

@Test func sameMarkerInTwoCalendarsPicksEarliest() {
    let a = orig("A", "x", local: "la", start: t0 + 7200)
    let b = orig("B", "x", local: "lb", start: t0)
    let r = reconcile(events: [a, b], settings: settings([A, B, C]), window: window)
    let inC = r.filter { if case .create(let s) = $0 { return s.target == C }; return false }
    #expect(inC == [.create(spec(C, of: b))])
}

@Test func sameMarkerSameSlotSuppressEachOtherAndCGetsOne() {
    let a = orig("A", "x", local: "la")
    let b = orig("B", "x", local: "lb")
    let r = reconcile(events: [a, b], settings: settings([A, B, C]), window: window)
    #expect(r == [.create(spec(C, of: a))])
}

@Test func nearMissSlotDoesNotSuppress() {
    let a = orig("A", "a")
    let otherEnd = snap(calendar: "B", localID: "r1", externalID: "r1", start: a.start, end: a.end + 60)
    #expect(reconcile(events: [a, otherEnd], settings: settings(), window: window).contains(.create(spec(B, of: a))))
    let allDay = snap(calendar: "B", localID: "r2", externalID: "r2", start: a.start, end: a.end, isAllDay: true)
    #expect(reconcile(events: [a, allDay], settings: settings(), window: window).contains(.create(spec(B, of: a))))
}

@Test func allDayFlagChangeUpdatesCopy() {
    let a = orig("A", "a", end: t0 + 86_400, allDay: true)
    var c = copy("B", of: a, local: "c1", ext: "x")
    c.isAllDay = false
    #expect(reconcile(events: [a, c], settings: settings(), window: window) == [.update(localID: "c1", spec(B, of: a))])
}

// MARK: - Which copy stays when one target holds several of one original

@Test func twoCorrectCopiesKeepTheFirst() {
    let a = orig("A", "a")
    let first = copy("B", of: a, local: "z", ext: "e1")
    let second = copy("B", of: a, local: "a", ext: "e2")
    let r = reconcile(events: [a, second, first], settings: settings(), window: window)
    #expect(r == [.delete(localID: "a", target: B)])
}

/// The copy that is already at the wanted times stays, even when a stale one comes first in the order;
/// otherwise the stale one would be moved and the correct one deleted.
@Test func staleAndCorrectKeepsCorrect() {
    let a = orig("A", "a")
    let stale = copy("B", of: a, local: "c-stale", ext: "e1", start: t0 - 7200, end: t0 - 3600)
    let correct = copy("B", of: a, local: "c-right", ext: "e2")
    let r = reconcile(events: [a, correct, stale], settings: settings(), window: window)
    #expect(r == [.delete(localID: "c-stale", target: B)])
    // A copy with only the start, only the end or only the all-day flag wrong is not at the wanted times.
    let shortened = copy("B", of: a, local: "c-short", ext: "e0", start: t0, end: t0 + 1800)
    var flipped = copy("B", of: a, local: "c-flip", ext: "e00")
    flipped.isAllDay = true
    let earlyStart = copy("B", of: a, local: "c-early", ext: "e01", start: t0 - 1800)
    #expect(earlyStart.end == a.end)
    #expect(reconcile(events: [a, correct, shortened, flipped, earlyStart], settings: settings(), window: window)
        == [.delete(localID: "c-early", target: B), .delete(localID: "c-flip", target: B),
            .delete(localID: "c-short", target: B)])
}

/// No copy is at the wanted times: the first in the order stays, as before, and is updated; the others go.
@Test func noCorrectCopyKeepsFirstAsToday() {
    let a = orig("A", "a")
    let first = copy("B", of: a, local: "z", ext: "e1", start: t0 - 7200, end: t0 - 3600)
    let second = copy("B", of: a, local: "a", ext: "e2", start: t0 + 7200, end: t0 + 10_800)
    #expect(reconcile(events: [a, second, first], settings: settings(), window: window)
        == [.delete(localID: "a", target: B), .update(localID: "z", spec(B, of: a))])
}

/// `e` as an occurrence of a recurring event, which the EventKit guard never replaces or deletes as a copy.
private func recurring(_ e: EventSnapshot) -> EventSnapshot {
    var e = e
    e.isRecurringOccurrence = true
    return e
}

/// A recurring copy at the wanted times, first in the order, does not stay: it could never be put right,
/// while our single copy, already right, would go. Only the recurring one is deleted, and nothing is updated.
@Test func recurringCopyAtRightTimeIsNotKept() {
    let a = orig("A", "a")
    let series = recurring(copy("B", of: a, local: "c-series", ext: "e1"))
    let single = copy("B", of: a, local: "c-single", ext: "e2")
    #expect(reconcile(events: [a, single, series], settings: settings(), window: window)
        == [.delete(localID: "c-series", target: B)])
    // Nor when our single copy is at old times: it stays and moves.
    let staleSingle = copy("B", of: a, local: "c-single", ext: "e2", start: t0 - 7200, end: t0 - 3600)
    #expect(reconcile(events: [a, staleSingle, series], settings: settings(), window: window)
        == [.delete(localID: "c-series", target: B), .update(localID: "c-single", spec(B, of: a))])
}

/// No copy is right and the first in the order is recurring: our single copy stays and moves, the recurring
/// one goes.
@Test func recurringCopyIsNotKeptWhenNoCopyIsRight() {
    let a = orig("A", "a")
    let series = recurring(copy("B", of: a, local: "c-series", ext: "e1", start: t0 + 7200, end: t0 + 10_800))
    let single = copy("B", of: a, local: "c-single", ext: "e2", start: t0 - 7200, end: t0 - 3600)
    #expect(reconcile(events: [a, single, series], settings: settings(), window: window)
        == [.delete(localID: "c-series", target: B), .update(localID: "c-single", spec(B, of: a))])
}

/// Every copy is recurring: the first in the order stays, as before, and is updated; the others go.
@Test func onlyRecurringCopiesKeepTheFirst() {
    let a = orig("A", "a")
    let first = recurring(copy("B", of: a, local: "z", ext: "e1", start: t0 - 7200, end: t0 - 3600))
    let second = recurring(copy("B", of: a, local: "a", ext: "e2", start: t0 + 7200, end: t0 + 10_800))
    #expect(reconcile(events: [a, second, first], settings: settings(), window: window)
        == [.delete(localID: "a", target: B), .update(localID: "z", spec(B, of: a))])
}

/// Occurrences of one series that someone made out of a copy: the one at the right time stays, so the plan is the
/// duplicates removal alone, not a move the write guard would refuse.
@Test func onlyRecurringCopiesKeepTheRightOne() {
    let a = orig("A", "a")
    let wrong = recurring(copy("B", of: a, local: "s", ext: "e1", start: t0 - 7200, end: t0 - 3600))
    let right = recurring(copy("B", of: a, local: "s", ext: "e1"))
    #expect(reconcile(events: [a, wrong, right], settings: settings(), window: window)
        == [.delete(localID: "s", target: B)])
}

@Test func updateAlsoDeletesDuplicates() {
    let a = orig("A", "a")
    let keep = copy("B", of: a, local: "z", ext: "e1", start: t0 - 7200, end: t0 - 3600)
    let drop = copy("B", of: a, local: "a", ext: "e2", start: t0 - 7200, end: t0 - 3600)
    let r = reconcile(events: [a, drop, keep], settings: settings(), window: window)
    #expect(r == [.delete(localID: "a", target: B), .update(localID: "z", spec(B, of: a))])
}

@Test func windowBoundaries() {
    let far = orig("A", "far", start: window.end)
    let atEnd = copy("B", of: far, local: "c1", ext: "x")
    #expect(reconcile(events: [atEnd], settings: settings(), window: window).isEmpty)
    let past = orig("A", "past", start: window.start - 3600, end: window.start)
    let endsAtStart = copy("B", of: past, local: "c2", ext: "y")
    #expect(reconcile(events: [endsAtStart], settings: settings(), window: window).isEmpty)
    #expect(reconcile(events: [past], settings: settings(), window: window).isEmpty)
}

@Test func copyInOwnSourceCalendarIsDeleted() {
    let a = orig("A", "a")
    let own = copy("A", of: a, local: "own", ext: "x")
    let r = reconcile(events: [a, own], settings: settings(), window: window)
    #expect(r == [.delete(localID: "own", target: A), .create(spec(B, of: a))])
}

// MARK: - Pairs set to Nothing

/// `cals` with the pairs in `nothing` set to `Nothing`; every other pair shows `Busy only`.
private func settings(_ cals: [CalendarRef], nothing: [(CalendarRef, CalendarRef)]) -> SyncSettings {
    var s = settings(cals)
    for (source, target) in nothing { s.copyTitleFormats[CopyRoute(source: source, target: target)] = .nothing }
    return s
}

/// A→C on Nothing: C gets no copy of A's meeting while B does, and a copy of it already in C goes; C's own and B's
/// meetings still reach the other calendars.
@Test func nothingRouteWantsNoCopy() {
    let a = orig("A", "a")
    let b = orig("B", "b", start: t0 + 7200)
    let s = settings([A, B, C], nothing: [(A, C)])
    #expect(s.copies(from: A, to: B) && !s.copies(from: A, to: C) && s.copies(from: C, to: A))
    #expect(reconcile(events: [a, b], settings: s, window: window)
        == [.create(spec(A, of: b)), .create(spec(B, of: a)), .create(spec(C, of: b))])

    let inC = copy("C", of: a, local: "c-a", ext: "x")
    let r = reconcile(events: [a, b, inC, copy("B", of: a, local: "b-a", ext: "y")], settings: s, window: window)
    #expect(r == [.delete(localID: "c-a", target: C), .create(spec(A, of: b)), .create(spec(C, of: b))])
    #expect(mirroredItems(events: [a, b], settings: s, window: window).map { "\($0.source.id)>\($0.target.id)" }
        == ["A>B", "B>A", "B>C"])
}

/// The same meeting in A and B, A's the winner by the usual rule (it starts first): with A→C on Nothing, A does not
/// compete for C, so C's copy is taken from B, at B's times; B's original is mirrored, not copied from A.
@Test func nothingRouteDoesNotCompete() {
    let inA = orig("A", "x", local: "la", start: t0)
    let inB = orig("B", "x", local: "lb", start: t0 + 1800)
    #expect(precedesAsSource(inA, inB))
    let everywhere = settings([A, B, C])
    let inCBefore = mirroredItems(events: [inA, inB], settings: everywhere, window: window).filter { $0.target == C }
    #expect(inCBefore.map(\.sourceLocalID) == ["la"])

    let s = settings([A, B, C], nothing: [(A, C)])
    let inC = mirroredItems(events: [inA, inB], settings: s, window: window).filter { $0.target == C }
    #expect(inC.map(\.sourceLocalID) == ["lb"])
    #expect(inC.map(\.start) == [inB.start])
    let r = reconcile(events: [inA, inB], settings: s, window: window)
    #expect(r.filter { if case .create(let spec) = $0 { return spec.target == C }; return false }
        == [.create(spec(C, of: inB))])
    #expect(!notBusyOriginals(events: [inA, inB], settings: s, window: window).contains { $0.localID == "lb" })

    // An existing copy in C taken from A moves to B's times.
    let fromA = copy("C", of: inA, local: "c1", ext: "e1")
    #expect(reconcile(events: [inA, inB, fromA], settings: s, window: window)
        .contains(.update(localID: "c1", spec(C, of: inB))))
}

/// Two calendars, A→B shows `Busy only`, B→A Nothing: only B gets copies, A none, and the copies of B's meetings
/// already in A go. The run after the plan is applied plans nothing.
@Test func oneWaySync() {
    let a = orig("A", "a")
    let b = orig("B", "b", start: t0 + 7200)
    let oldInA = copy("A", of: b, local: "a-b", ext: "z")
    let s = settings([A, B], nothing: [(B, A)])
    let first = reconcile(events: [a, b, oldInA], settings: s, window: window)
    #expect(first == [.delete(localID: "a-b", target: A), .create(spec(B, of: a))])

    var events = [a, b]
    for case let .create(spec) in first {
        events.append(snap(calendar: spec.target.id, localID: "new", externalID: "new", start: spec.start,
                           end: spec.end, isAllDay: spec.isAllDay, marker: spec.marker))
    }
    #expect(reconcile(events: events, settings: s, window: window).isEmpty)
    #expect(mirroredItems(events: events, settings: s, window: window).map(\.target) == [B])
}

/// The reasons an original is not copied only look at the calendars its own calendar copies into: `sameSlot`
/// names such a calendar, and a calendar that copies into none lists none of its originals.
@Test func notCopiedReasonsOnlyCountCopiedTargets() {
    let a = orig("A", "a")
    let realInC = orig("C", "c", start: a.start, end: a.end)
    let declined = orig("A", "d", start: t0 + 7200, response: .declined)
    let s = settings([A, B, C], nothing: [(A, B)])
    let skipped = notBusyOriginals(events: [a, realInC, declined], settings: s, window: window)
    #expect(skipped.filter { $0.calendar == A }.map(\.reason) == [.sameSlot(in: C), .declined])

    let silent = settings([A, B, C], nothing: [(A, B), (A, C)])
    // C's meeting is copied into B, so nothing is left to list.
    #expect(notBusyOriginals(events: [a, realInC, declined], settings: silent, window: window).isEmpty)
}

/// A real busy event still keeps another calendar's copy off its slot when its own calendar's pair is Nothing: with
/// A→B on Nothing, B's meeting at the time of A's gets no copy in A (one already there goes) and is listed as the
/// same slot in A, while A's meeting, which goes nowhere, is not listed.
@Test func nothingPairStillHoldsItsSlot() {
    let inA = orig("A", "p"), inB = orig("B", "q")
    let s = settings([A, B], nothing: [(A, B)])
    #expect(reconcile(events: [inA, inB], settings: s, window: window).isEmpty)
    #expect(reconcile(events: [inA, inB, copy("A", of: inB, local: "a-q", ext: "x")], settings: s, window: window)
        == [.delete(localID: "a-q", target: A)])
    let skipped = notBusyOriginals(events: [inA, inB], settings: s, window: window)
    #expect(skipped.map(\.localID) == [inB.localID])
    #expect(skipped.map(\.reason) == [.sameSlot(in: A)])
}

/// An account that lags: the meeting is at 10:00 in A and in C, which was invited too, and still at 10:30 in B. With
/// every pair on Busy only, C's copy would be A's at 10:00, where C holds the meeting itself, so C gets none. With A→C
/// on Nothing, B's original alone competes for C, and C gets a block at 10:30.
@Test func nothingPairLetsALaggingOriginalThrough() {
    let inA = orig("A", "m", local: "la"), inC = orig("C", "m", local: "lc")
    let inB = orig("B", "m", local: "lb", start: t0 + 1800)
    func createsInC(_ s: SyncSettings) -> [SyncAction] {
        reconcile(events: [inA, inB, inC], settings: s, window: window).filter {
            if case .create(let spec) = $0 { return spec.target == C }
            return false
        }
    }
    #expect(createsInC(settings([A, B, C])).isEmpty)
    // Accepted: a pair on Nothing does not compete for its target, so the lagging original wins C.
    #expect(createsInC(settings([A, B, C], nothing: [(A, C)])) == [.create(spec(C, of: inB))])
}

// MARK: - Updates handed to the store as replacements

@Test func replacingUpdatesMapsOnlyUpdates() {
    let a = orig("A", "a"), b = orig("B", "b", start: t0 + 7200)
    let actions: [SyncAction] = [.delete(localID: "x", target: B), .update(localID: "c1", spec(B, of: a)),
                                 .create(spec(A, of: b))]
    #expect(replacingUpdates(actions)
        == [.delete(localID: "x", target: B), .replace(localID: "c1", spec(B, of: a)), .create(spec(A, of: b))])
    #expect(replacingUpdates([]).isEmpty)
}
