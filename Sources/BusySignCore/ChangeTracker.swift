import CryptoKit
import Foundation

/// Remembers, per calendar, the real (non-copy) events seen in the last observed window and when they
/// last changed, so a calendar that has stopped updating can be reported as stale.
///
/// The window moves every day and may grow, so events leaving it at the start or entering it at the end
/// are not changes. Only the part both windows cover is compared: an event added, removed or edited
/// there is a change. A calendar that turns empty keeps its last change, so it never looks freshly alive.
/// When the two windows do not overlap at all, the read counts as a first observation.
public struct ChangeTracker: Codable, Equatable, Sendable {
    /// One event as a hashed key plus its end, which places it against the next window.
    private struct Key: Codable, Equatable, Sendable {
        var digest: String
        var end: Date

        // Short names: the tracker is saved after every run and holds one key per event in the window.
        private enum CodingKeys: String, CodingKey {
            case digest = "d"
            case end = "e"
        }
    }

    private struct Entry: Codable, Equatable, Sendable {
        var window: DateInterval
        var keys: [Key]
        var lastChange: Date
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// Records the events of `calendar` read for `window` at `at`. Only events of that calendar without a
    /// marker that overlap `window` count; one that merely touches an edge of it is outside it.
    public mutating func observe(_ events: [EventSnapshot], in calendar: CalendarRef, at: Date, window: DateInterval) {
        let current = events
            .filter {
                $0.calendar == calendar && $0.marker == nil && $0.start < window.end && $0.end > window.start
            }
            .map { (event: $0, digest: Self.digest(of: $0)) }
            .sorted { $0.digest < $1.digest }
        var lastChange = at
        // Without any overlap with the previous window there is nothing to compare (re-selected after a
        // long break, or the Mac was off longer than the look-ahead): it counts as a first observation.
        // Windows that only touch (a 1-day look-ahead across midnight) are continuous.
        if let previous = entries[calendar.id],
           previous.window.start <= window.end, window.start <= previous.window.end {
            // Events that ended before the new window started have left it; events starting at or after
            // the previous window's end were never seen before.
            let before = previous.keys.filter { $0.end > window.start }.map(\.digest)
            let now = current.filter { $0.event.start < previous.window.end }.map(\.digest)
            if before == now || current.isEmpty { lastChange = previous.lastChange }
        }
        let keys = current.map { Key(digest: $0.digest, end: $0.event.end) }
        entries[calendar.id] = Entry(window: window, keys: keys, lastChange: lastChange)
    }

    public func lastChange(for calendar: CalendarRef) -> Date? {
        entries[calendar.id]?.lastChange
    }

    /// Calendars whose last change is strictly more than `threshold` seconds before `now`.
    /// Calendars never observed are not stale.
    public func stale(_ calendars: [CalendarRef], at now: Date, threshold: TimeInterval) -> [CalendarRef] {
        calendars.filter { calendar in
            guard let last = entries[calendar.id]?.lastChange else { return false }
            return now.timeIntervalSince(last) > threshold
        }
    }

    // MARK: - Keys

    /// First 16 bytes of the SHA-256 of the event's fields, base64url: deterministic across launches,
    /// and the event's identifiers are not stored in clear.
    private static func digest(of event: EventSnapshot) -> String {
        let fields = [
            event.localID,
            event.externalID ?? "",
            time(event.occurrenceDate),
            event.isRecurringOccurrence ? "recurring" : "single",
            time(event.start),
            time(event.end),
            event.isAllDay ? "all-day" : "timed",
            name(event.availability),
            name(event.myResponse),
        ]
        let digest = SHA256.hash(data: Data(fields.joined(separator: "\u{1F}").utf8))
        return Data(digest.prefix(16)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func time(_ date: Date) -> String {
        String(format: "%.3f", date.timeIntervalSince1970)
    }

    private static func name(_ value: Availability) -> String {
        switch value {
        case .busy: "busy"
        case .free: "free"
        case .tentative: "tentative"
        case .unavailable: "unavailable"
        case .notSupported: "notSupported"
        }
    }

    private static func name(_ value: MyResponse) -> String {
        switch value {
        case .accepted: "accepted"
        case .tentative: "tentative"
        case .declined: "declined"
        case .pending: "pending"
        case .none: "none"
        }
    }
}
