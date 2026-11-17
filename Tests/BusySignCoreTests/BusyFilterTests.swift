import Foundation
import Testing
@testable import BusySignCore

func snap(
    calendar: String = "cal-a",
    localID: String = "local-1",
    externalID: String? = "ext-1",
    occurrenceDate: Date = Date(timeIntervalSince1970: 1_800_000_000),
    isRecurringOccurrence: Bool = false,
    start: Date = Date(timeIntervalSince1970: 1_800_000_000),
    end: Date = Date(timeIntervalSince1970: 1_800_003_600),
    isAllDay: Bool = false,
    availability: Availability = .busy,
    myResponse: MyResponse = .accepted,
    marker: String? = nil
) -> EventSnapshot {
    EventSnapshot(
        calendar: CalendarRef(id: calendar),
        localID: localID,
        externalID: externalID,
        occurrenceDate: occurrenceDate,
        isRecurringOccurrence: isRecurringOccurrence,
        start: start,
        end: end,
        isAllDay: isAllDay,
        availability: availability,
        myResponse: myResponse,
        marker: marker
    )
}

@Test func acceptedIsBusy() {
    #expect(countsAsBusy(snap(), unansweredAsBusy: false))
}

@Test func tentativeResponseIsBusy() {
    #expect(countsAsBusy(snap(myResponse: .tentative), unansweredAsBusy: false))
}

@Test func declinedIsNotBusy() {
    #expect(!countsAsBusy(snap(myResponse: .declined), unansweredAsBusy: false))
}

@Test func pendingIsNotBusyByDefault() {
    #expect(!countsAsBusy(snap(myResponse: .pending), unansweredAsBusy: false))
}

@Test func pendingIsBusyWhenSettingOn() {
    #expect(countsAsBusy(snap(myResponse: .pending), unansweredAsBusy: true))
}

@Test func freeIsNotBusyEvenIfAccepted() {
    #expect(!countsAsBusy(snap(availability: .free), unansweredAsBusy: false))
}

@Test func ownEventIsBusy() {
    #expect(countsAsBusy(snap(myResponse: .none), unansweredAsBusy: false))
}

@Test func allDayBusyIsBusy() {
    #expect(countsAsBusy(snap(isAllDay: true, availability: .busy), unansweredAsBusy: false))
}

@Test func allDayOutOfOfficeIsBusy() {
    #expect(countsAsBusy(snap(isAllDay: true, availability: .unavailable), unansweredAsBusy: false))
}

@Test func allDayFreeIsNotBusy() {
    #expect(!countsAsBusy(snap(isAllDay: true, availability: .free), unansweredAsBusy: false))
}

@Test func allDayTentativeIsNotBusy() {
    #expect(!countsAsBusy(snap(isAllDay: true, availability: .tentative), unansweredAsBusy: false))
}

@Test func allDayBusyDeclinedIsNotBusy() {
    #expect(!countsAsBusy(snap(isAllDay: true, availability: .busy, myResponse: .declined), unansweredAsBusy: false))
}

@Test func copiesAreNeverSources() {
    #expect(!countsAsBusy(snap(marker: "busysign:v1:abc"), unansweredAsBusy: true))
}

@Test func exchangePendingTentativeIsNotBusy() {
    #expect(!countsAsBusy(snap(availability: .tentative, myResponse: .pending), unansweredAsBusy: false))
}

@Test func syncSettingsDefaults() {
    let s = SyncSettings(selected: [CalendarRef(id: "a"), CalendarRef(id: "b")])
    #expect(s.lookAheadDays == 30)
    #expect(!s.unansweredAsBusy)
}

// MARK: - busyVerdict

@Test func verdictBusyForAcceptedTentativeOwnAndAllDayBusy() {
    for e in [snap(), snap(myResponse: .tentative), snap(myResponse: .none),
              snap(isAllDay: true, availability: .busy), snap(isAllDay: true, availability: .unavailable)] {
        #expect(busyVerdict(e, unansweredAsBusy: false) == .busy)
    }
}

@Test func verdictCopyBeatsEverything() {
    #expect(busyVerdict(snap(marker: "busysign-v1:x"), unansweredAsBusy: true) == .copy)
    #expect(busyVerdict(snap(isAllDay: true, availability: .free, myResponse: .declined, marker: "m"),
                        unansweredAsBusy: false) == .copy)
}

@Test func verdictDeclined() {
    #expect(busyVerdict(snap(myResponse: .declined), unansweredAsBusy: true) == .declined)
    #expect(busyVerdict(snap(isAllDay: true, availability: .busy, myResponse: .declined),
                        unansweredAsBusy: false) == .declined)
}

@Test func verdictFreeComesBeforeResponse() {
    #expect(busyVerdict(snap(availability: .free), unansweredAsBusy: false) == .free)
    #expect(busyVerdict(snap(availability: .free, myResponse: .declined), unansweredAsBusy: false) == .free)
    #expect(busyVerdict(snap(availability: .free, myResponse: .pending), unansweredAsBusy: true) == .free)
}

@Test func verdictPendingInvitation() {
    #expect(busyVerdict(snap(myResponse: .pending), unansweredAsBusy: false) == .pendingInvitation)
    #expect(busyVerdict(snap(myResponse: .pending), unansweredAsBusy: true) == .busy)
}

/// Exchange may file an unanswered invitation as tentative; the user's response decides, not availability.
@Test func verdictExchangePendingTentative() {
    let e = snap(availability: .tentative, myResponse: .pending)
    #expect(busyVerdict(e, unansweredAsBusy: false) == .pendingInvitation)
    #expect(busyVerdict(e, unansweredAsBusy: true) == .busy)
}

@Test func verdictAllDayNotBusyComesBeforeFreeAndResponse() {
    for availability in [Availability.free, .tentative, .notSupported] {
        #expect(busyVerdict(snap(isAllDay: true, availability: availability), unansweredAsBusy: false) == .allDayNotBusy)
    }
    #expect(busyVerdict(snap(isAllDay: true, availability: .free, myResponse: .declined),
                        unansweredAsBusy: false) == .allDayNotBusy)
}

@Test func countsAsBusyEqualsVerdictBusyForEveryCombination() {
    let availabilities: [Availability] = [.busy, .free, .tentative, .unavailable, .notSupported]
    let responses: [MyResponse] = [.accepted, .tentative, .declined, .pending, .none]
    for availability in availabilities {
        for response in responses {
            for allDay in [false, true] {
                for marker in [nil, "busysign-v1:x"] as [String?] {
                    for unanswered in [false, true] {
                        let e = snap(isAllDay: allDay, availability: availability, myResponse: response, marker: marker)
                        #expect(countsAsBusy(e, unansweredAsBusy: unanswered)
                            == (busyVerdict(e, unansweredAsBusy: unanswered) == .busy))
                    }
                }
            }
        }
    }
}
