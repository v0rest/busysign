import Foundation
import Testing
@testable import BusySignCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let window = DateInterval(start: t0 - 86_400, duration: 30 * 86_400)
private let A = CalendarRef(id: "A")
private let B = CalendarRef(id: "B")
private let C = CalendarRef(id: "C")

private func settings(_ cals: [CalendarRef] = [A, B], excluded: Set<String> = []) -> SyncSettings {
    SyncSettings(selected: cals, lookAheadDays: 30, unansweredAsBusy: false, excluded: excluded)
}

/// An original; `occurrence` is the date the series scheduled it for, `start` unless it was moved.
private func orig(_ cal: String, _ ext: String? = "ext", local: String? = nil, start: Date = t0,
                  occurrence: Date? = nil, recurring: Bool = false,
                  response: MyResponse = .accepted) -> EventSnapshot {
    snap(calendar: cal, localID: local ?? "\(cal)-\(ext ?? "none")", externalID: ext,
         occurrenceDate: occurrence ?? start, isRecurringOccurrence: recurring, start: start, end: start + 3600,
         myResponse: response)
}

private func copy(_ cal: String, of o: EventSnapshot, local: String, ext: String? = nil) -> EventSnapshot {
    snap(calendar: cal, localID: local, externalID: ext, start: o.start, end: o.end, isAllDay: o.isAllDay,
         marker: Marker.make(for: o))
}

private func spec(_ target: CalendarRef, of o: EventSnapshot) -> CopySpec {
    CopySpec(target: target, marker: Marker.make(for: o)!, start: o.start, end: o.end, isAllDay: o.isAllDay)
}

/// Three daily occurrences of one series in A, sharing the series' external and local ids; the third is
/// detached, moved an hour later than the series scheduled it.
private func series() -> [EventSnapshot] {
    [
        orig("A", "series", local: "s", start: t0, recurring: true),
        orig("A", "series", local: "s", start: t0 + 86_400, recurring: true),
        orig("A", "series", local: "s", start: t0 + 2 * 86_400 + 3600, occurrence: t0 + 2 * 86_400, recurring: true),
    ]
}

/// Copies in B of each of `originals`, local ids c0, c1, ...
private func copiesInB(of originals: [EventSnapshot]) -> [EventSnapshot] {
    originals.enumerated().map { i, o in copy("B", of: o, local: "c\(i)", ext: "x\(i)") }
}

private func occurrenceKey(_ e: EventSnapshot) throws -> String {
    try #require(ExclusionKey.occurrence(for: e))
}

private func seriesKey(_ e: EventSnapshot) throws -> String {
    try #require(ExclusionKey.series(for: e))
}

private func includeKey(_ e: EventSnapshot) throws -> String {
    try #require(ExclusionKey.include(for: e))
}

private func skipped(_ o: EventSnapshot, _ reason: SkippedOriginal.Reason,
                     underlying: SkippedOriginal.Reason? = nil) -> SkippedOriginal {
    SkippedOriginal(calendar: o.calendar, localID: o.localID, start: o.start, end: o.end, isAllDay: o.isAllDay,
                    reason: reason, occurrenceKey: ExclusionKey.occurrence(for: o),
                    seriesKey: ExclusionKey.series(for: o), includeKey: ExclusionKey.include(for: o),
                    underlyingReason: underlying)
}

// MARK: - Keys

@Suite struct ExclusionKeyTests {
    @Test func deterministic() throws {
        let e = orig("A", "evt", recurring: true)
        #expect(try occurrenceKey(e) == occurrenceKey(e))
        #expect(try seriesKey(e) == seriesKey(e))
        #expect(try occurrenceKey(e) != seriesKey(e))
    }

    /// The vectors of `MarkerTests.goldenVector`: the occurrence key is the marker, the series key the
    /// marker's hash of the external id alone.
    @Test func goldenVectorsReuseTheMarkerHash() {
        let single = orig("A", "evt-ext-123")
        #expect(ExclusionKey.occurrence(for: single) == "o:busysign-v1:3lce_rIAe73d2hqw3odJvE")
        let occurrence = orig("A", "evt-ext-123", start: Date(timeIntervalSince1970: 1_794_562_200), recurring: true)
        #expect(ExclusionKey.occurrence(for: occurrence) == "o:busysign-v1:Vqpt5Bff5HyOq1hE_t_c3W")
        #expect(ExclusionKey.series(for: occurrence) == "s:3lce_rIAe73d2hqw3odJvE")
    }

    @Test func opaque() throws {
        let ext = "AAMkAGI2THVSAAA="
        let e = orig("A", ext, recurring: true)
        let chars = Array(ext)
        for key in [try occurrenceKey(e), try seriesKey(e)] {
            for i in 0...(chars.count - 6) {
                #expect(!key.contains(String(chars[i..<(i + 6)])))
            }
        }
    }

    @Test func seriesKeyIsSharedByEveryOccurrenceDetachedIncluded() throws {
        let occurrences = series()
        let keys = try occurrences.map(seriesKey)
        #expect(keys.count == 3)
        #expect(Set(keys).count == 1)
    }

    @Test func occurrenceKeysDifferPerOccurrence() throws {
        let occurrences = series()
        let keys = try occurrences.map(occurrenceKey)
        #expect(Set(keys).count == occurrences.count)
    }

    @Test func singleEventHasNoSeriesKey() {
        let single = orig("A", "single")
        #expect(ExclusionKey.occurrence(for: single) != nil)
        #expect(ExclusionKey.series(for: single) == nil)
    }

    @Test func includeKeyFormat() throws {
        let e = orig("A", "evt", recurring: true)
        let marker = try #require(Marker.make(for: e))
        #expect(ExclusionKey.include(for: e) == "i:" + marker)
        #expect(ExclusionKey.include(for: orig("A", nil, recurring: true)) == nil)
    }

    @Test func noExternalIDNoKeys() {
        for ext in [nil, ""] as [String?] {
            let unsynced = orig("A", ext, recurring: true)
            #expect(ExclusionKey.occurrence(for: unsynced) == nil)
            #expect(ExclusionKey.series(for: unsynced) == nil)
        }
    }
}

// MARK: - Behaviour

@Suite struct ExclusionBehaviourTests {
    @Test func excludingAnOccurrenceRemovesOnlyItsCopy() throws {
        let occurrences = series()
        let events = occurrences + copiesInB(of: occurrences)
        let s = settings(excluded: [try occurrenceKey(occurrences[1])])
        #expect(reconcile(events: events, settings: s, window: window) == [.delete(localID: "c1", target: B)])
    }

    @Test func excludingASeriesRemovesEveryOccurrencesCopy() throws {
        let occurrences = series()
        let other = orig("A", "other", start: t0 + 7200)
        let events = occurrences + copiesInB(of: occurrences) + [other, copy("B", of: other, local: "co", ext: "xo")]
        let s = settings(excluded: [try seriesKey(occurrences[0])])
        #expect(reconcile(events: events, settings: s, window: window) == [
            .delete(localID: "c0", target: B), .delete(localID: "c1", target: B), .delete(localID: "c2", target: B),
        ])
    }

    @Test func includeOverridesSeriesExclusion() throws {
        let occurrences = series()
        let s = settings(excluded: [try seriesKey(occurrences[0]), try includeKey(occurrences[1])])
        #expect(reconcile(events: occurrences, settings: s, window: window) == [.create(spec(B, of: occurrences[1]))])
    }

    @Test func occurrenceExclusionBeatsInclude() throws {
        let occurrences = series()
        let s = settings(excluded: [try occurrenceKey(occurrences[0]), try includeKey(occurrences[0])])
        #expect(reconcile(events: [occurrences[0]], settings: s, window: window).isEmpty)
    }

    @Test func includeWithoutSeriesIsNoop() throws {
        let occurrences = series()
        let s = settings(excluded: [try includeKey(occurrences[0])])
        #expect(reconcile(events: occurrences, settings: s, window: window)
            == reconcile(events: occurrences, settings: settings(), window: window))
    }

    @Test func existingKeysUnchanged() throws {
        let occurrences = series()
        let events = occurrences + copiesInB(of: occurrences)
        let secondOccurrence = try occurrenceKey(occurrences[1])
        #expect(reconcile(events: events, settings: settings(excluded: [secondOccurrence]),
                          window: window) == [.delete(localID: "c1", target: B)])
        let wholeSeries = try seriesKey(occurrences[0])
        #expect(reconcile(events: events, settings: settings(excluded: [wholeSeries]),
                          window: window) == [
            .delete(localID: "c0", target: B), .delete(localID: "c1", target: B), .delete(localID: "c2", target: B),
        ])
    }

    @Test func excludedOriginalGetsNoNewCopy() throws {
        let occurrences = series()
        let single = orig("A", "single", start: t0 + 7200)
        let s = settings(excluded: [try seriesKey(occurrences[0]), try occurrenceKey(single)])
        #expect(reconcile(events: occurrences + [single], settings: s, window: window).isEmpty)
    }

    /// An excluded event is still busy in its own calendar: no copy lands on top of it there.
    @Test func excludedEventStillSuppressesACopyAtItsSlot() throws {
        let a = orig("A", "a")
        let b = orig("B", "b")
        let s = settings([A, B, C], excluded: [try occurrenceKey(a)])
        #expect(reconcile(events: [a, b], settings: s, window: window) == [.create(spec(C, of: b))])
    }

    @Test func unExcludingRestoresTheCopies() throws {
        let occurrences = series()
        let excluded = settings(excluded: [try seriesKey(occurrences[0])])
        #expect(reconcile(events: occurrences, settings: excluded, window: window).isEmpty)
        #expect(reconcile(events: occurrences, settings: settings(), window: window)
            == occurrences.map { .create(spec(B, of: $0)) })
    }

    /// Keys computed from a copy's own fields never touch it; it goes only when its original is excluded.
    @Test func copiesAreNeverAffectedByExclusionKeys() throws {
        let a = orig("A", "a")
        var c = copy("B", of: a, local: "c1", ext: "x")
        c.isRecurringOccurrence = true
        let s = settings(excluded: [try occurrenceKey(c), try seriesKey(c)])
        #expect(!s.excludes(c))
        #expect(reconcile(events: [a, c], settings: s, window: window).isEmpty)
        #expect(notBusyOriginals(events: [a, c], settings: s, window: window).isEmpty)
    }

    /// Exclusion comes before the busy verdict, so a declined or same-slot event that is excluded reads
    /// as excluded; the reason it would have without the exclusion comes along.
    @Test func excludedEventsAreListedAsExcludedByUser() throws {
        let occurrences = series()
        let declined = orig("A", "declined", start: t0 + 7200, response: .declined)
        let sameSlot = orig("B", "b")
        let s = settings(excluded: [try seriesKey(occurrences[0]), try occurrenceKey(declined),
                                    try occurrenceKey(occurrences[0]), try occurrenceKey(sameSlot)])
        #expect(notBusyOriginals(events: occurrences + [declined, sameSlot], settings: s, window: window) == [
            skipped(occurrences[0], .excludedByUser, underlying: .sameSlot(in: B)),
            skipped(sameSlot, .excludedByUser, underlying: .sameSlot(in: A)),
            skipped(declined, .excludedByUser, underlying: .declined),
            skipped(occurrences[1], .excludedByUser),
            skipped(occurrences[2], .excludedByUser),
        ])
    }

    /// Without the exclusion, the same meeting in A and B at the same time is copied from A into C: A's
    /// original has no underlying reason, B's is copied from A.
    @Test func underlyingReasonUsesTheSameMarkerWinner() throws {
        let inA = orig("A", "x", local: "la")
        let inB = orig("B", "x", local: "lb")
        let s = settings([A, B, C], excluded: [try occurrenceKey(inA)])
        #expect(notBusyOriginals(events: [inA, inB], settings: s, window: window) == [
            skipped(inA, .excludedByUser),
            skipped(inB, .excludedByUser, underlying: .copiedFrom(A)),
        ])
    }

    @Test func skippedOriginalsCarryTheirKeys() throws {
        let declined = orig("A", "declined", recurring: true, response: .declined)
        let unsynced = orig("A", nil, start: t0 + 7200)
        let listed = notBusyOriginals(events: [declined, unsynced], settings: settings(), window: window)
        #expect(listed.map(\.reason) == [.declined, .notSyncedYet])
        let declinedOccurrence = try occurrenceKey(declined)
        #expect(listed.map(\.occurrenceKey) == [declinedOccurrence, nil])
        let declinedSeries = try seriesKey(declined)
        #expect(listed.map(\.seriesKey) == [declinedSeries, nil])
    }

    @Test func addAndMoveCarryTheOriginalsKeys() throws {
        let occurrences = series()
        var moved = copy("B", of: occurrences[1], local: "c1", ext: "x1")
        moved.start -= 7200
        moved.end -= 7200
        let single = orig("A", "single", start: t0 + 7200)
        let events = occurrences + [moved, single]
        let changes = plannedChanges(for: reconcile(events: events, settings: settings(), window: window),
                                     events: events, settings: settings(), window: window)
        #expect(changes.map(\.kind) == [.add, .add, .move, .add])
        let keysInOrder: [String?] = [
            try occurrenceKey(occurrences[0]), try occurrenceKey(single),
            try occurrenceKey(occurrences[1]), try occurrenceKey(occurrences[2]),
        ]
        #expect(changes.map(\.occurrenceKey) == keysInOrder)
        let seriesOfAll = try seriesKey(occurrences[0])
        #expect(changes.map(\.seriesKey) == [seriesOfAll, nil, seriesOfAll, seriesOfAll])
    }

    /// In dry run the copy of an excluded original is a Remove that still names the original and its keys.
    @Test func excludedOriginalsCopyShowsAsRemove() throws {
        let a = orig("A", "a")
        let c = copy("B", of: a, local: "c1", ext: "x")
        let s = settings(excluded: [try occurrenceKey(a)])
        let changes = plannedChanges(for: reconcile(events: [a, c], settings: s, window: window),
                                     events: [a, c], settings: s, window: window)
        let keyOfA = try occurrenceKey(a)
        let includeOfA = try includeKey(a)
        #expect(changes == [
            PlannedChange(kind: .remove, target: B, start: a.start, end: a.end, isAllDay: false,
                          source: A, sourceLocalID: a.localID, occurrenceKey: keyOfA,
                          includeKey: includeOfA),
        ])
    }
}

// MARK: - Mirrored items

private func item(_ target: CalendarRef, of o: EventSnapshot) -> MirroredItem {
    MirroredItem(target: target, start: o.start, end: o.end, isAllDay: o.isAllDay, source: o.calendar,
                 sourceLocalID: o.localID, occurrenceKey: ExclusionKey.occurrence(for: o),
                 seriesKey: ExclusionKey.series(for: o), includeKey: ExclusionKey.include(for: o))
}

private func mirrored(_ events: [EventSnapshot], _ s: SyncSettings = settings()) -> [MirroredItem] {
    mirroredItems(events: events, settings: s, window: window)
}

@Suite struct MirroredItemsTests {
    /// Steady state in Live: the copy is already there, so no change is planned, but the meeting is listed
    /// and can be excluded from that row.
    @Test func alreadyMirroredMeetingIsListed() {
        let a = orig("A", "a")
        let c = copy("B", of: a, local: "c1", ext: "x")
        #expect(reconcile(events: [a, c], settings: settings(), window: window).isEmpty)
        #expect(mirrored([a, c]) == [item(B, of: a)])
    }

    @Test func sortedByStartThenTargetID() {
        let occurrences = series()
        let b = orig("B", "b", start: t0 + 7200)
        #expect(mirrored(occurrences + [b], settings([C, B, A])) == [
            item(B, of: occurrences[0]), item(C, of: occurrences[0]),
            item(A, of: b), item(C, of: b),
            item(B, of: occurrences[1]), item(C, of: occurrences[1]),
            item(B, of: occurrences[2]), item(C, of: occurrences[2]),
        ])
    }

    /// One item per desired copy: with no copies yet, exactly the copies `reconcile` creates.
    @Test func equalsTheDesiredCopies() {
        let occurrences = series()
        let b = orig("B", "b", start: t0 + 7200)
        let sameSlotInC = orig("C", "c")
        let declined = orig("A", "d", start: t0 + 3 * 3600, response: .declined)
        let s = settings([A, B, C])
        let events = occurrences + [b, sameSlotInC, declined]
        let items = mirrored(events, s)
        #expect(items.count == desiredCopies(events: events, settings: s, window: window).count)
        let creates = reconcile(events: events, settings: s, window: window).compactMap { action -> CopySpec? in
            if case let .create(spec) = action { return spec }
            return nil
        }
        func slot(_ target: CalendarRef, _ start: Date, _ end: Date, _ allDay: Bool) -> String {
            "\(target.id)|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(allDay)"
        }
        #expect(Set(items.map { slot($0.target, $0.start, $0.end, $0.isAllDay) })
            == Set(creates.map { slot($0.target, $0.start, $0.end, $0.isAllDay) }))
        #expect(items.count == creates.count)
        #expect(items.allSatisfy { $0.occurrenceKey.map { key in creates.contains { "o:" + $0.marker == key } } ?? false })
    }

    @Test func excludedOriginalsAreAbsent() throws {
        let occurrences = series()
        let single = orig("A", "single", start: t0 + 7200)
        let events = occurrences + [single, copy("B", of: single, local: "c1", ext: "x")]
        let wholeSeries = try seriesKey(occurrences[0])
        #expect(mirrored(events, settings(excluded: [wholeSeries])) == [item(B, of: single)])
        let secondOccurrence = try occurrenceKey(occurrences[1])
        let singleOccurrence = try occurrenceKey(single)
        #expect(mirrored(events, settings(excluded: [secondOccurrence, singleOccurrence]))
            == [item(B, of: occurrences[0]), item(B, of: occurrences[2])])
    }

    @Test func notBusySameSlotAndOutsideWindowAreAbsent() {
        let a = orig("A", "a")
        let sameSlot = orig("B", "b")
        let declined = orig("A", "d", start: t0 + 7200, response: .declined)
        let late = orig("A", "late", start: window.end)
        #expect(mirrored([a, sameSlot, declined, late]).isEmpty)
        #expect(mirrored([orig("A", "a")], settings([A])).isEmpty)
    }
}
