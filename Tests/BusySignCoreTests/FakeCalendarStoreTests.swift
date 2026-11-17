import Foundation
import Testing
@testable import BusySignCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let window = DateInterval(start: t0 - 86_400, duration: 30 * 86_400)
private let A = CalendarRef(id: "A")
private let B = CalendarRef(id: "B")
private let R = CalendarRef(id: "R")

private func marker(_ ext: String) -> String {
    Marker.make(for: snap(externalID: ext))!
}

private func copyEvent(_ cal: String, local: String, marker: String, start: Date = t0) -> EventSnapshot {
    snap(calendar: cal, localID: local, externalID: nil, start: start, end: start + 3600,
         myResponse: .none, marker: marker)
}

private func makeStore(events: [EventSnapshot] = [], access: AccessState = .granted) -> FakeCalendarStore {
    FakeCalendarStore(
        calendars: [
            FakeCalendarStore.calendar("A"),
            FakeCalendarStore.calendar("B"),
            FakeCalendarStore.calendar("R", writable: false),
        ],
        events: events,
        access: access
    )
}

@Test func fakeApplyCreatesUpdatesDeletes() async throws {
    let original = snap(calendar: "A", localID: "o1", externalID: "orig")
    let kept = copyEvent("B", local: "c1", marker: marker("orig"), start: t0 - 7200)
    let stale = copyEvent("B", local: "c2", marker: marker("gone"))
    let store = makeStore(events: [original, kept, stale])

    let moved = CopySpec(target: B, marker: marker("orig"), start: t0, end: t0 + 3600, isAllDay: false)
    let added = CopySpec(target: A, marker: marker("new"), start: t0 + 86_400, end: t0 + 86_400 * 2,
                         isAllDay: true)
    let actions: [SyncAction] = [
        .delete(localID: "c2", target: B),
        .update(localID: "c1", moved),
        .create(added),
    ]
    let report = try await store.apply(actions)

    #expect(report == ApplyReport(created: 1, updated: 1, deleted: 1, failures: []))
    #expect(await store.appliedActions == [actions])
    let events = try await store.events(in: [A, B], window: window)
    #expect(events.map(\.localID).sorted() == ["c1", "fake-1", "o1"])
    let updated = try #require(events.first { $0.localID == "c1" })
    #expect(updated.start == t0 && updated.end == t0 + 3600 && !updated.isAllDay)
    let created = try #require(events.first { $0.localID == "fake-1" })
    #expect(created == EventSnapshot(
        calendar: A, localID: "fake-1", externalID: nil, occurrenceDate: added.start,
        isRecurringOccurrence: false, start: added.start, end: added.end, isAllDay: true,
        availability: .busy, myResponse: .none, marker: added.marker, title: added.title))
}

@Test func fakeApplyRefusesUnsafeActions() async throws {
    let original = snap(calendar: "B", localID: "o1", externalID: "orig")
    let copyInB = copyEvent("B", local: "c1", marker: marker("x"))
    let copyInR = copyEvent("R", local: "c2", marker: marker("y"))
    var recurringCopy = copyEvent("B", local: "c3", marker: marker("w"))
    recurringCopy.isRecurringOccurrence = true
    let store = makeStore(events: [original, copyInB, copyInR, recurringCopy])

    let report = try await store.apply([
        .delete(localID: "o1", target: B),                     // no marker
        .delete(localID: "c1", target: A),                     // wrong calendar
        .delete(localID: "c2", target: R),                     // read-only calendar
        .delete(localID: "c3", target: B),                     // recurring
        .update(localID: "missing", CopySpec(target: B, marker: marker("x"), start: t0, end: t0 + 60,
                                             isAllDay: false)),  // unknown
        .update(localID: "c1", CopySpec(target: B, marker: marker("other"), start: t0, end: t0 + 60,
                                        isAllDay: false)),     // marker differs
        .create(CopySpec(target: R, marker: marker("z"), start: t0, end: t0 + 60, isAllDay: false)),
        .create(CopySpec(target: CalendarRef(id: "Q"), marker: marker("z"), start: t0, end: t0 + 60,
                         isAllDay: false)),                    // unknown calendar
        .create(CopySpec(target: A, marker: "not-a-marker", start: t0, end: t0 + 60, isAllDay: false)),
    ])

    #expect(report.created == 0 && report.updated == 0 && report.deleted == 0)
    #expect(report.failures == [
        "delete o1: not a marked copy",
        "delete c1: event is in another calendar",
        "delete c2: calendar is read-only",
        "delete c3: event is recurring",
        "update missing: event not found",
        "update c1: marker mismatch",
        "create in R: calendar is read-only",
        "create in Q: calendar not found",
        "create in A: invalid marker",
    ])
    #expect(await store.storedEvents == [original, copyInB, copyInR, recurringCopy])
}

@Test func fakeDropsMarkedEventsWithAttendees() async throws {
    let meeting = snap(calendar: "A", localID: "m1", externalID: "meeting")
    let markedInvite = copyEvent("B", local: "c1", marker: marker("orig"))
    let copy = copyEvent("B", local: "c2", marker: marker("other"))
    let store = makeStore(events: [copy])
    await store.addEvents([meeting, markedInvite], withAttendees: true)

    let events = try await store.events(in: [A, B], window: window)
    #expect(events.map(\.localID).sorted() == ["c2", "m1"])
    #expect(events.first { $0.localID == "m1" }?.marker == nil)
    #expect(events.first { $0.localID == "c2" }?.marker == marker("other"))

    let report = try await store.apply([
        .delete(localID: "c1", target: B),
        .update(localID: "c1", CopySpec(target: B, marker: marker("orig"), start: t0, end: t0 + 60, isAllDay: false)),
    ])
    #expect(report.deleted == 0 && report.updated == 0)
    #expect(report.failures == ["delete c1: event has attendees", "update c1: event has attendees"])
    #expect(await store.storedEvents == [copy, meeting, markedInvite])
}

@Test func fakeReadsNotesThroughCopyReading() async throws {
    let unmarked = snap(calendar: "A", localID: "n1", externalID: "n1", marker: "Agenda")
    let padded = snap(calendar: "B", localID: "c1", externalID: nil, marker: " \(marker("x"))\n")
    let store = makeStore(events: [unmarked, padded])
    let events = try await store.events(in: [A, B], window: window)
    #expect(events.first { $0.localID == "n1" }?.marker == nil)
    #expect(events.first { $0.localID == "c1" }?.marker == marker("x"))
}

/// Another Mac removed the copy first: the delete is done, not a failure. Updates of a missing event,
/// and deletes in a missing or read-only calendar, still fail.
@Test func fakeDeleteOfGoneEventSucceeds() async throws {
    let copy = copyEvent("B", local: "c1", marker: marker("x"))
    let store = makeStore(events: [copy])

    let report = try await store.apply([
        .delete(localID: "c1", target: B),
        .delete(localID: "gone", target: B),
        .delete(localID: "c1", target: B),
        .update(localID: "gone", CopySpec(target: B, marker: marker("x"), start: t0, end: t0 + 60, isAllDay: false)),
        .delete(localID: "gone", target: R),
        .delete(localID: "gone", target: CalendarRef(id: "Q")),
    ])

    #expect(report.deleted == 3)
    #expect(report.updated == 0 && report.created == 0)
    #expect(report.failures == [
        "update gone: event not found",
        "delete gone: calendar is read-only",
        "delete gone: calendar not found",
    ])
    #expect(await store.storedEvents.isEmpty)
}

@Test func fakeThrowsWhenTold() async throws {
    struct Boom: Error {}
    let store = makeStore(events: [copyEvent("B", local: "c1", marker: marker("x"))])

    await store.setCalendarsError(Boom())
    await #expect(throws: Boom.self) { try await store.calendars() }
    _ = try await store.events(in: [A, B], window: window)

    await store.setCalendarsError(nil)
    await store.setEventsError(Boom())
    _ = try await store.calendars()
    await #expect(throws: Boom.self) { try await store.events(in: [A], window: window) }

    await store.setApplyError(Boom())
    await #expect(throws: Boom.self) { try await store.apply([.delete(localID: "c1", target: B)]) }
    #expect(await store.appliedActions == [[.delete(localID: "c1", target: B)]])
    #expect(await store.storedEvents.count == 1)
}

@Test func fakeOmittedCalendarIsMissing() async throws {
    let store = makeStore()
    await store.omit(B)

    #expect(try await store.calendars().map(\.ref) == [A, R])
    await #expect(throws: CalendarStoreError.calendarNotFound(id: "B")) {
        try await store.events(in: [A, B], window: window)
    }
    let report = try await store.apply([
        .create(CopySpec(target: B, marker: marker("x"), start: t0, end: t0 + 60, isAllDay: false)),
    ])
    #expect(report.created == 0 && report.failures.count == 1)
}

@Test func fakeAccessStates() async throws {
    let store = makeStore(access: .notDetermined)
    #expect(await store.accessState() == .notDetermined)
    await #expect(throws: CalendarStoreError.accessNotGranted) { try await store.calendars() }
    await #expect(throws: CalendarStoreError.accessNotGranted) {
        try await store.events(in: [A], window: window)
    }
    await #expect(throws: CalendarStoreError.accessNotGranted) { try await store.apply([]) }

    #expect(await store.requestAccess())
    #expect(await store.accessState() == .granted)
    #expect(await store.requestAccessCount == 1)

    await store.setAccess(.denied)
    #expect(await store.requestAccess() == false)
    #expect(await store.accessState() == .denied)
}

@Test func fakeEventsFilterByCalendarAndWindow() async throws {
    let inA = snap(calendar: "A", localID: "a1", externalID: "a1", start: t0, end: t0 + 3600)
    let inB = snap(calendar: "B", localID: "b1", externalID: "b1", start: t0, end: t0 + 3600)
    let endsAtWindowStart = snap(calendar: "A", localID: "a2", externalID: "a2",
                                 start: window.start - 3600, end: window.start)
    let overlapsStart = snap(calendar: "A", localID: "a3", externalID: "a3",
                             start: window.start - 3600, end: window.start + 1)
    let startsAtWindowEnd = snap(calendar: "A", localID: "a4", externalID: "a4",
                                 start: window.end, end: window.end + 3600)
    let store = makeStore(events: [inA, inB, endsAtWindowStart, overlapsStart, startsAtWindowEnd])

    let events = try await store.events(in: [A], window: window)
    #expect(events.map(\.localID) == ["a1", "a3"])
    #expect(try await store.events(in: [], window: window).isEmpty)
}

@Test func storeErrorMessagesAreFixed() {
    #expect(CalendarStoreError.commitFailed.localizedDescription == "Saving calendar changes failed")
    #expect(CalendarStoreError.accessNotGranted.localizedDescription == "Calendar access not granted")
    #expect(CalendarStoreError.calendarNotFound(id: "A").localizedDescription == "A selected calendar is missing")
    #expect(CalendarStoreError.incompleteEvent(calendarID: "A").localizedDescription
        == "A calendar returned an incomplete event")
}

@Test func fakeFailsCreatesPlainAndInReplacements() async throws {
    let old = copyEvent("B", local: "c1", marker: marker("orig"), start: t0 - 7200)
    let store = makeStore(events: [old])
    await store.setFailsCreates(true)
    let spec = CopySpec(target: B, marker: marker("orig"), start: t0, end: t0 + 3600, isAllDay: false)
    let report = try await store.apply([.create(spec), .replace(localID: "c1", spec)])
    #expect(report == ApplyReport(failures: ["create in B: create failed", "replace c1: create failed"]))
    #expect(await store.storedEvents == [old])
}

/// A removal that fails leaves the event, for a plain delete and for the delete half of a replacement, whose new
/// copy stays and counts as created. Other ids, and an id that is already gone, are removed as usual.
@Test func fakeFailsRemovesPlainAndInReplacements() async throws {
    let old = copyEvent("B", local: "c1", marker: marker("orig"), start: t0 - 7200)
    let stuck = copyEvent("B", local: "c2", marker: marker("other"))
    let free = copyEvent("B", local: "c3", marker: marker("third"))
    let store = makeStore(events: [old, stuck, free])
    await store.setFailsRemoves(["c1", "c2", "gone"])
    let spec = CopySpec(target: B, marker: marker("orig"), start: t0, end: t0 + 3600, isAllDay: false)
    let report = try await store.apply([.replace(localID: "c1", spec), .delete(localID: "c2", target: B),
                                        .delete(localID: "c3", target: B), .delete(localID: "gone", target: B)])
    #expect(report == ApplyReport(created: 1, deleted: 2,
                                  failures: ["replace c1: remove failed", "delete c2: remove failed"]))
    let stored = await store.storedEvents
    #expect(stored.map(\.localID) == ["c1", "c2", "fake-1"])
    #expect(stored.last?.start == t0 && stored.last?.marker == marker("orig"))
}

/// A create and a replacement store the spec's title as the copy's title, as the EventKit store writes it.
@Test func createdCopyKeepsTitle() async throws {
    let old = copyEvent("B", local: "c1", marker: marker("orig"), start: t0 - 7200)
    let store = makeStore(events: [old])
    let created = CopySpec(target: A, marker: marker("new"), start: t0, end: t0 + 3600, isAllDay: false,
                           title: "Weekly sync")
    let replacement = CopySpec(target: B, marker: marker("orig"), start: t0, end: t0 + 3600, isAllDay: false,
                               title: "Acme: Weekly sync")
    let report = try await store.apply([.create(created), .replace(localID: "c1", replacement)])
    #expect(report == ApplyReport(created: 1, replaced: 1))
    let events = try await store.events(in: [A, B], window: window)
    #expect(events.map(\.localID).sorted() == ["fake-1", "fake-2"])
    #expect(events.first { $0.calendar == A }?.title == "Weekly sync")
    #expect(events.first { $0.calendar == B }?.title == "Acme: Weekly sync")
}
