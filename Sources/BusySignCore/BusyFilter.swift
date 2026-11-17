import Foundation

/// Why an event is or is not a source of busy time.
public enum BusyVerdict: Sendable, Equatable {
    case busy
    /// One of our copies (marker present); copies are never sources.
    case copy
    case declined
    /// Marked Free.
    case free
    /// An invitation the user has not answered, while "Treat unanswered invitations as busy" is off. Keys
    /// on the user's own response, not on availability: Exchange may file it as tentative.
    case pendingInvitation
    /// An all-day event that is neither Busy nor Out of Office, such as a plain all-day reminder.
    case allDayNotBusy
}

/// The busy rules, in order: copies, all-day availability, Free, then the user's response.
public func busyVerdict(_ e: EventSnapshot, unansweredAsBusy: Bool) -> BusyVerdict {
    if e.marker != nil { return .copy }
    if e.isAllDay && e.availability != .busy && e.availability != .unavailable { return .allDayNotBusy }
    if e.availability == .free { return .free }
    switch e.myResponse {
    case .declined: return .declined
    case .pending: return unansweredAsBusy ? .busy : .pendingInvitation
    default: return .busy
    }
}

/// Whether an event is a source of busy time. Our own copies (marker present) never are.
public func countsAsBusy(_ e: EventSnapshot, unansweredAsBusy: Bool) -> Bool {
    busyVerdict(e, unansweredAsBusy: unansweredAsBusy) == .busy
}
