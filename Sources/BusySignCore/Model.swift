import Foundation

public enum Availability: Sendable {
    case busy, free, tentative, unavailable, notSupported
}

public enum MyResponse: Sendable {
    case accepted, tentative, declined, pending
    /// No attendees, or the user organises the event.
    case none
}

public struct CalendarRef: Hashable, Sendable, Codable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct EventSnapshot: Sendable, Equatable {
    public var calendar: CalendarRef
    public var localID: String
    public var externalID: String?
    public var occurrenceDate: Date
    public var isRecurringOccurrence: Bool
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var availability: Availability
    public var myResponse: MyResponse
    /// The marker of one of our copies (`CopyReading`); nil for an original.
    public var marker: String?
    /// The event's title as read, kept in memory only and never printed (`description` redacts it). Nil when
    /// the store did not read it: a copy with a nil title has an unknown title and is never retitled.
    public var title: String?

    public init(
        calendar: CalendarRef,
        localID: String,
        externalID: String?,
        occurrenceDate: Date,
        isRecurringOccurrence: Bool,
        start: Date,
        end: Date,
        isAllDay: Bool,
        availability: Availability,
        myResponse: MyResponse,
        marker: String?,
        title: String? = nil
    ) {
        self.calendar = calendar
        self.localID = localID
        self.externalID = externalID
        self.occurrenceDate = occurrenceDate
        self.isRecurringOccurrence = isRecurringOccurrence
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.availability = availability
        self.myResponse = myResponse
        self.marker = marker
        self.title = title
    }
}

public struct SyncSettings: Sendable, Equatable {
    public var selected: [CalendarRef]
    public var lookAheadDays: Int
    public var unansweredAsBusy: Bool
    /// `ExclusionKey`s of the meetings and series the user chose not to mirror.
    public var excluded: Set<String>
    /// The choice on each route, by the calendar of the original the copies are taken from and the calendar they go
    /// to: whether it copies at all (`nothing` copies nothing, `copies(from:to:)`) and what its copies show; a route
    /// that is missing shows `busyOnly`. Routes from or to a calendar not in `selected` play no part.
    public var copyTitleFormats: [CopyRoute: CopyTitleFormat]
    /// Each source calendar's short name, for `sourceAndTitle`; a source without one shows the title alone.
    public var sourceLabels: [CalendarRef: String]
    /// `ExclusionKey`s of the meetings and series whose copies show `Busy` whatever their route's format, by
    /// the exclusion rule (`SyncSettings.hidesTitle`).
    public var hiddenTitleKeys: Set<String>

    public init(
        selected: [CalendarRef], lookAheadDays: Int = 30, unansweredAsBusy: Bool = false, excluded: Set<String> = [],
        copyTitleFormats: [CopyRoute: CopyTitleFormat] = [:], sourceLabels: [CalendarRef: String] = [:],
        hiddenTitleKeys: Set<String> = []
    ) {
        self.selected = selected
        self.lookAheadDays = lookAheadDays
        self.unansweredAsBusy = unansweredAsBusy
        self.excluded = excluded
        self.copyTitleFormats = copyTitleFormats
        self.sourceLabels = sourceLabels
        self.hiddenTitleKeys = hiddenTitleKeys
    }
}
