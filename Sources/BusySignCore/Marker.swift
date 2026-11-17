import CryptoKit
import Foundation

/// Opaque, deterministic marker written as the entire notes field of a copy: `prefix` and a body.
/// The format is frozen: copies in real calendars carry it forever.
public enum Marker {
    /// The prefix of every marker.
    public static let prefix = "busysign-v1:"
    private static let digestLength = 22

    /// - Parameter timeZone: the zone EventKit used for the floating dates of all-day events.
    public static func make(for event: EventSnapshot, timeZone: TimeZone = .current) -> String? {
        guard let externalID = event.externalID, !externalID.isEmpty else { return nil }
        var key = externalID
        if event.isRecurringOccurrence {
            key += "|" + (event.isAllDay
                ? calendarDay(event.occurrenceDate, in: timeZone)
                : utcTimestamp(event.occurrenceDate))
        }
        return prefix + digest(of: key)
    }

    /// The first 22 characters of the base64url SHA-256 of `key`: the body of a marker, and of the
    /// series key in `ExclusionKey`.
    static func digest(of key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let base64url = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return String(base64url.prefix(digestLength))
    }

    /// The marker the notes hold as their whole text (surrounding whitespace and BOMs aside), with `prefix`
    /// and a valid body; nil for anything else.
    public static func parse(notes: String?) -> String? {
        guard let notes else { return nil }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard trimmed.hasPrefix(prefix) else { return nil }
        let body = trimmed.dropFirst(prefix.count)
        guard body.utf8.count == digestLength,
              body.utf8.allSatisfy(isBase64URLByte) else { return nil }
        return trimmed
    }

    private static func isBase64URLByte(_ b: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(b)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(b)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b)
            || b == UInt8(ascii: "-") || b == UInt8(ascii: "_")
    }

    private static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    /// `yyyy-MM-dd'T'HH:mm:ss'Z'` in UTC, rounded to the nearest whole second.
    private static func utcTimestamp(_ date: Date) -> String {
        let whole = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded())
        let c = gregorian(TimeZone(identifier: "UTC")!)
            .dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
                      c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// `yyyy-MM-dd` of the date in the given zone.
    private static func calendarDay(_ date: Date, in timeZone: TimeZone) -> String {
        let c = gregorian(timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
