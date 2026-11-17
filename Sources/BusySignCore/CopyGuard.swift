import Foundation

/// How an event read from a calendar relates to BusySign's copies, decided from the only two fields that
/// matter. Every `CalendarStore` reads events through this, so they all agree on what a copy is.
public enum CopyReading: Equatable, Sendable {
    /// One of our copies, carrying this marker.
    case copy(marker: String)
    /// A valid marker on an event with attendees: neither a source of busy time nor one of our copies.
    /// It is left out of the read, so it is never mirrored, updated or deleted.
    case drop
    /// Anything else: an ordinary event.
    case original

    public init(hasAttendees: Bool, notes: String?) {
        guard let marker = Marker.parse(notes: notes) else {
            self = .original
            return
        }
        self = hasAttendees ? .drop : .copy(marker: marker)
    }
}

/// What the write path knows about the existing event an update or delete names.
public struct ExistingEvent: Equatable, Sendable {
    public var hasAttendees: Bool
    public var notes: String?
    public var isRecurring: Bool
    /// The calendar the event is in; nil when the store gives none.
    public var calendarID: String?

    public init(hasAttendees: Bool, notes: String?, isRecurring: Bool, calendarID: String?) {
        self.hasAttendees = hasAttendees
        self.notes = notes
        self.isRecurring = isRecurring
        self.calendarID = calendarID
    }
}

/// Fixed reasons for refusing to update or delete an existing event. The raw value is the text that goes
/// into `ApplyReport.failures`.
public enum CopyWriteRefusal: String, Equatable, Sendable {
    case eventNotFound = "event not found"
    case hasAttendees = "event has attendees"
    case notMarkedCopy = "not a marked copy"
    case markerMismatch = "marker mismatch"
    case otherCalendar = "event is in another calendar"
    case recurring = "event is recurring"
}

/// Why `event` (nil: no such event) may not be updated or deleted as our copy in the calendar `targetID`,
/// or nil when it may. It must have no attendees, a valid marker equal to `expectedMarker` when one is
/// given (updates; deletes pass nil), sit in the target calendar and not be recurring. That the target
/// calendar exists and is writable is checked before this.
public func copyWriteRefusal(_ event: ExistingEvent?, targetID: String, expectedMarker: String?) -> CopyWriteRefusal? {
    guard let event else { return .eventNotFound }
    if event.hasAttendees { return .hasAttendees }
    guard let marker = Marker.parse(notes: event.notes) else { return .notMarkedCopy }
    if let expectedMarker, marker != expectedMarker { return .markerMismatch }
    guard event.calendarID == targetID else { return .otherCalendar }
    if event.isRecurring { return .recurring }
    return nil
}
