import BusySignCore
import EventKit
import Foundation

// Small, separately auditable translations between EventKit objects and BusySignCore values.
// An event's title is read into `EventSnapshot.title` and a copy's title written from `CopySpec.title`, in
// memory only: nothing here logs, stores or prints it. Nothing here reads an event's location, URL or attendee
// identities. The notes are read only to recognise a marker, through `CopyReading`.

func mapAccess(_ status: EKAuthorizationStatus) -> AccessState {
    switch status {
    case .fullAccess: .granted
    case .notDetermined: .notDetermined
    // denied, restricted, write-only and any future status.
    default: .denied
    }
}

func mapAvailability(_ value: EKEventAvailability) -> Availability {
    switch value {
    case .busy: .busy
    case .free: .free
    case .tentative: .tentative
    case .unavailable: .unavailable
    case .notSupported: .notSupported
    @unknown default: .notSupported
    }
}

func mapResponse(_ status: EKParticipantStatus) -> MyResponse {
    switch status {
    case .accepted: .accepted
    case .tentative: .tentative
    case .declined: .declined
    case .pending, .unknown: .pending
    case .delegated, .completed, .inProcess: .accepted
    @unknown default: .accepted
    }
}

/// The user's own response: `.none` for an event the user organises (their own event, whatever status
/// a server lists for them as attendee); otherwise from the attendee marked as the current user, `.none`
/// when there is none. The organizer is used only here, never to recognise copies.
func myResponse(of event: EKEvent) -> MyResponse {
    if event.organizer?.isCurrentUser == true { return .none }
    guard let me = event.attendees?.first(where: \.isCurrentUser) else { return .none }
    return mapResponse(me.participantStatus)
}

enum SnapshotResult {
    case event(EventSnapshot)
    /// Not an original and not a copy: a cancelled meeting kept in the attendee's calendar.
    case dropped
    /// Not an original and not a copy: a valid marker on an event with attendees.
    case droppedMarkedWithAttendees
    /// Missing calendar or dates; the read cannot be trusted.
    case incomplete
}

func snapshot(of event: EKEvent) -> SnapshotResult {
    guard let calendar = event.calendar, let start = event.startDate, let end = event.endDate else {
        return .incomplete
    }
    let marker: String?
    switch CopyReading(hasAttendees: event.hasAttendees, notes: event.notes) {
    case let .copy(found): marker = found
    case .drop: return .droppedMarkedWithAttendees
    case .original: marker = nil
    }
    if event.status == .canceled && marker == nil { return .dropped }
    let externalID = event.calendarItemExternalIdentifier.flatMap { $0.isEmpty ? nil : $0 }
    return .event(EventSnapshot(
        calendar: CalendarRef(id: calendar.calendarIdentifier),
        localID: event.calendarItemIdentifier,
        externalID: externalID,
        occurrenceDate: event.occurrenceDate ?? start,
        isRecurringOccurrence: event.hasRecurrenceRules || event.isDetached,
        start: start,
        end: end,
        isAllDay: event.isAllDay,
        availability: mapAvailability(event.availability),
        myResponse: myResponse(of: event),
        marker: marker,
        // As read, nil staying nil; the core normalises it.
        title: event.title
    ))
}

/// Writes the complete copy shape: the title the core chose (`CopySpec.title`: `Busy`, the meeting's title or
/// `<source>: <title>`, normalised), busy, no alarms, location or URL, the marker as the only notes. Dates pass
/// through exactly as the spec holds them (they came from EventKit), so a copy read back equals its spec.
func applyCopyShape(to event: EKEvent, spec: CopySpec) {
    event.title = spec.title
    event.availability = .busy
    event.alarms = nil
    event.location = nil
    event.structuredLocation = nil
    event.url = nil
    event.notes = spec.marker
    event.isAllDay = spec.isAllDay
    // A copy that turns from all-day into timed must not stay floating.
    if !spec.isAllDay && event.timeZone == nil { event.timeZone = .current }
    event.startDate = spec.start
    event.endDate = spec.end
}

func accountKind(of source: EKSource?) -> String {
    guard let source else { return "Other" }
    switch source.sourceType {
    case .exchange: return "Exchange"
    case .calDAV: return "CalDAV"
    case .local: return "On My Mac"
    case .mobileMe: return "iCloud"
    case .subscribed: return "Subscribed"
    case .birthdays: return "Birthdays"
    @unknown default: return "Other"
    }
}

func mapKind(_ type: EKCalendarType) -> CalendarKind {
    switch type {
    case .local: .local
    case .calDAV: .calDAV
    case .exchange: .exchange
    case .subscription: .subscription
    case .birthday: .birthday
    @unknown default: .other
    }
}
