import Foundation

/// Keys for the meetings and recurring series the user chose not to mirror. Opaque and deterministic,
/// built with the marker's one-way hash and never from a title, so the settings that keep them reveal
/// nothing about the meetings.
public enum ExclusionKey {
    /// One meeting: a single event, or one occurrence of a series. `o:` and the event's marker; nil when
    /// it has no marker (no external identifier yet).
    public static func occurrence(for event: EventSnapshot) -> String? {
        Marker.make(for: event).map { "o:" + $0 }
    }

    /// Every occurrence of a recurring series, detached ones included: `s:` and the hash of the external
    /// identifier alone, which the occurrences share. Nil for a single event or without an external
    /// identifier.
    public static func series(for event: EventSnapshot) -> String? {
        guard event.isRecurringOccurrence, let externalID = event.externalID, !externalID.isEmpty else { return nil }
        return "s:" + Marker.digest(of: externalID)
    }

    /// One occurrence the user keeps mirrored although its series is excluded: `i:` and the event's
    /// marker. Nil when it has no marker.
    public static func include(for event: EventSnapshot) -> String? {
        Marker.make(for: event).map { "i:" + $0 }
    }
}

/// An original's three `ExclusionKey`s, built once.
struct ExclusionKeys: Equatable {
    var occurrence: String?
    var series: String?
    var include: String?

    init(occurrence: String?, series: String?, include: String?) {
        self.occurrence = occurrence
        self.series = series
        self.include = include
    }

    init(for event: EventSnapshot) {
        self.init(occurrence: ExclusionKey.occurrence(for: event), series: ExclusionKey.series(for: event),
                  include: ExclusionKey.include(for: event))
    }

    /// The exclusion rule: the occurrence key is in `excluded`, or the series key is and the include key
    /// is not.
    func isExcluded(in excluded: Set<String>) -> Bool {
        if let occurrence, excluded.contains(occurrence) { return true }
        guard let series, excluded.contains(series) else { return false }
        return !(include.map(excluded.contains) ?? false)
    }
}

extension SyncSettings {
    /// Whether the user excluded this original (`ExclusionKeys.isExcluded`). Never true for a copy.
    func excludes(_ event: EventSnapshot) -> Bool {
        guard !excluded.isEmpty, event.marker == nil else { return false }
        return ExclusionKeys(for: event).isExcluded(in: excluded)
    }

    /// Whether the user hid this original's title (`hiddenTitleKeys`, by the exclusion rule): its copies show
    /// `Busy` in every target. Never true for a copy.
    func hidesTitle(_ original: EventSnapshot) -> Bool {
        guard !hiddenTitleKeys.isEmpty, original.marker == nil else { return false }
        return ExclusionKeys(for: original).isExcluded(in: hiddenTitleKeys)
    }
}
