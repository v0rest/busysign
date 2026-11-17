import Foundation
import Testing
@testable import BusySignCore

@Suite struct CopyReadingTests {
    let marker = "busysign-v1:AAAAAAAAAAAAAAAAAAAAAA"

    @Test func validMarkerWithoutAttendeesIsACopy() {
        #expect(CopyReading(hasAttendees: false, notes: marker) == .copy(marker: marker))
        #expect(CopyReading(hasAttendees: false, notes: "\u{FEFF} \(marker)\n") == .copy(marker: marker))
    }

    @Test func validMarkerWithAttendeesIsDropped() {
        #expect(CopyReading(hasAttendees: true, notes: marker) == .drop)
        #expect(CopyReading(hasAttendees: true, notes: " \(marker)\n") == .drop)
    }

    @Test func noValidMarkerIsAnOriginal() {
        for attendees in [false, true] {
            #expect(CopyReading(hasAttendees: attendees, notes: nil) == .original)
            #expect(CopyReading(hasAttendees: attendees, notes: "") == .original)
            #expect(CopyReading(hasAttendees: attendees, notes: "Agenda: \(marker)") == .original)
            #expect(CopyReading(hasAttendees: attendees, notes: "busysign-v1:short") == .original)
            #expect(CopyReading(hasAttendees: attendees, notes: "busysign-v2:AAAAAAAAAAAAAAAAAAAAAA") == .original)
        }
    }
}

@Suite struct CopyWriteGuardTests {
    let marker = "busysign-v1:AAAAAAAAAAAAAAAAAAAAAA"
    let other = "busysign-v1:BBBBBBBBBBBBBBBBBBBBBB"

    func event(attendees: Bool = false, notes: String? = nil, recurring: Bool = false,
               calendar: String? = "T") -> ExistingEvent {
        ExistingEvent(hasAttendees: attendees, notes: notes ?? marker, isRecurring: recurring, calendarID: calendar)
    }

    @Test func acceptsOurCopy() {
        #expect(copyWriteRefusal(event(), targetID: "T", expectedMarker: marker) == nil)
        #expect(copyWriteRefusal(event(), targetID: "T", expectedMarker: nil) == nil)
        #expect(copyWriteRefusal(event(notes: " \(marker)\n"), targetID: "T", expectedMarker: marker) == nil)
    }

    @Test func refusesMissingEvent() {
        #expect(copyWriteRefusal(nil, targetID: "T", expectedMarker: marker) == .eventNotFound)
        #expect(copyWriteRefusal(nil, targetID: "T", expectedMarker: nil) == .eventNotFound)
    }

    @Test func refusesEventWithAttendees() {
        #expect(copyWriteRefusal(event(attendees: true), targetID: "T", expectedMarker: marker) == .hasAttendees)
        #expect(copyWriteRefusal(event(attendees: true), targetID: "T", expectedMarker: nil) == .hasAttendees)
    }

    @Test func refusesEventWithoutValidMarker() {
        #expect(copyWriteRefusal(ExistingEvent(hasAttendees: false, notes: nil, isRecurring: false, calendarID: "T"),
                                 targetID: "T", expectedMarker: nil) == .notMarkedCopy)
        #expect(copyWriteRefusal(event(notes: "Agenda"), targetID: "T", expectedMarker: nil) == .notMarkedCopy)
        #expect(copyWriteRefusal(event(notes: "busysign-v1:short"), targetID: "T", expectedMarker: nil) == .notMarkedCopy)
    }

    @Test func refusesOtherMarker() {
        #expect(copyWriteRefusal(event(), targetID: "T", expectedMarker: other) == .markerMismatch)
    }

    @Test func refusesEventInAnotherCalendar() {
        #expect(copyWriteRefusal(event(calendar: "U"), targetID: "T", expectedMarker: marker) == .otherCalendar)
        #expect(copyWriteRefusal(event(calendar: nil), targetID: "T", expectedMarker: nil) == .otherCalendar)
    }

    @Test func refusesRecurringEvent() {
        #expect(copyWriteRefusal(event(recurring: true), targetID: "T", expectedMarker: marker) == .recurring)
        #expect(copyWriteRefusal(event(recurring: true), targetID: "T", expectedMarker: nil) == .recurring)
    }

    @Test func checksInFixedOrder() {
        let everything = event(attendees: true, notes: "Agenda", recurring: true, calendar: "U")
        #expect(copyWriteRefusal(everything, targetID: "T", expectedMarker: other) == .hasAttendees)
        let unmarked = event(notes: "Agenda", recurring: true, calendar: "U")
        #expect(copyWriteRefusal(unmarked, targetID: "T", expectedMarker: other) == .notMarkedCopy)
        let mismatched = event(recurring: true, calendar: "U")
        #expect(copyWriteRefusal(mismatched, targetID: "T", expectedMarker: other) == .markerMismatch)
        #expect(copyWriteRefusal(mismatched, targetID: "T", expectedMarker: marker) == .otherCalendar)
    }

    @Test func refusalTextsAreFixed() {
        #expect(CopyWriteRefusal.eventNotFound.rawValue == "event not found")
        #expect(CopyWriteRefusal.hasAttendees.rawValue == "event has attendees")
        #expect(CopyWriteRefusal.notMarkedCopy.rawValue == "not a marked copy")
        #expect(CopyWriteRefusal.markerMismatch.rawValue == "marker mismatch")
        #expect(CopyWriteRefusal.otherCalendar.rawValue == "event is in another calendar")
        #expect(CopyWriteRefusal.recurring.rawValue == "event is recurring")
    }
}
