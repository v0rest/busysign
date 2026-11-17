import Foundation

/// One busy block a run adds, moves, retitles or removes in one target calendar, for display. It carries
/// times, calendars, the original's local id and its opaque exclusion keys only, never event content; the app
/// may look the title up by that id for its own window.
///
/// There is one entry per target and marker. Deletes of duplicate copies (the same original mirrored
/// more than once into one calendar) are folded into that entry as `duplicatesRemoved`. When the copy
/// that stays needs no change, only its duplicates go, and the entry's kind is `.removeDuplicates`.
public struct PlannedChange: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A new copy.
        case add
        /// The copy moves to new times; `previous*` hold its old ones.
        case move
        /// The copy goes: its original is gone, no longer busy, outside the selection, on a pair set to
        /// `nothing`, or now shares its slot with a real event in the target.
        case remove
        /// The copy stays as it is; `duplicatesRemoved` extra copies of it go.
        case removeDuplicates
        /// The copy keeps its times; its title changes to the one its route shows. The entry carries no title.
        case retitle
    }

    public var kind: Kind
    public var target: CalendarRef
    /// The copy's times after the run; for `.remove`, the times of the copy that goes (the earliest one
    /// when several go).
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// For `.move`, the copy's times before the run; nil otherwise.
    public var previousStart: Date?
    public var previousEnd: Date?
    public var previousIsAllDay: Bool?
    /// The original the copy mirrors; nil when no original with the copy's marker is visible outside the
    /// target (a copy is never of its own calendar's original).
    public var source: CalendarRef?
    public var sourceLocalID: String?
    /// Duplicate copies of the same original in the target deleted on top of the change itself.
    public var duplicatesRemoved: Int
    /// The `ExclusionKey`s of `source` (the mirrored original for `.add`, `.move`, `.retitle` and
    /// `.removeDuplicates`, the visible original outside the target for `.remove`); nil without one, and the
    /// series key also for a single event.
    public var occurrenceKey: String?
    public var seriesKey: String?
    public var includeKey: String?

    public init(
        kind: Kind,
        target: CalendarRef,
        start: Date,
        end: Date,
        isAllDay: Bool,
        previousStart: Date? = nil,
        previousEnd: Date? = nil,
        previousIsAllDay: Bool? = nil,
        source: CalendarRef? = nil,
        sourceLocalID: String? = nil,
        duplicatesRemoved: Int = 0,
        occurrenceKey: String? = nil,
        seriesKey: String? = nil,
        includeKey: String? = nil
    ) {
        self.kind = kind
        self.target = target
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.previousStart = previousStart
        self.previousEnd = previousEnd
        self.previousIsAllDay = previousIsAllDay
        self.source = source
        self.sourceLocalID = sourceLocalID
        self.duplicatesRemoved = duplicatesRemoved
        self.occurrenceKey = occurrenceKey
        self.seriesKey = seriesKey
        self.includeKey = includeKey
    }
}

extension PlannedChange {
    /// One busy block a run changes: the target and the original's occurrence key, or, for a removal whose
    /// original is unknown, the target and the slot. `MeetingsCatalog.Removal` ids and `LiveChanges` merges
    /// are built from it.
    var blockKey: String {
        let slot = "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)" + (isAllDay ? "-all-day" : "")
        return "\(target.id)|\(occurrenceKey ?? slot)"
    }
}

/// A busy block the selection calls for, exclusions applied: one per target and original, whether it is
/// already in the target or still to be added. For display, like `PlannedChange`: times, calendars, the
/// original's local id and its opaque exclusion keys only.
public struct MirroredItem: Sendable, Equatable {
    public var target: CalendarRef
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// The original the block mirrors.
    public var source: CalendarRef
    public var sourceLocalID: String
    /// The original's `ExclusionKey`s; the series key is nil for a single event.
    public var occurrenceKey: String?
    public var seriesKey: String?
    public var includeKey: String?

    public init(
        target: CalendarRef, start: Date, end: Date, isAllDay: Bool, source: CalendarRef, sourceLocalID: String,
        occurrenceKey: String? = nil, seriesKey: String? = nil, includeKey: String? = nil
    ) {
        self.target = target
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.source = source
        self.sourceLocalID = sourceLocalID
        self.occurrenceKey = occurrenceKey
        self.seriesKey = seriesKey
        self.includeKey = includeKey
    }
}

/// Every copy `reconcile` wants for the same events, settings and window, exclusions applied: one item per
/// target and marker, from the same `desiredCopies`, sorted by start, then target id (then marker, so ties
/// are stable). Empty with fewer than two selected calendars.
public func mirroredItems(events: [EventSnapshot], settings: SyncSettings, window: DateInterval) -> [MirroredItem] {
    desiredCopies(events: events, settings: settings, window: window)
        .sorted {
            ($0.value.spec.start, $0.key.target.id, $0.key.marker) < ($1.value.spec.start, $1.key.target.id, $1.key.marker)
        }
        .map { key, copy in
            let keys = ExclusionKeys(for: copy.source)
            return MirroredItem(target: key.target, start: copy.spec.start, end: copy.spec.end,
                                isAllDay: copy.spec.isAllDay, source: copy.source.calendar,
                                sourceLocalID: copy.source.localID, occurrenceKey: keys.occurrence,
                                seriesKey: keys.series, includeKey: keys.include)
        }
}

extension MirroredItem {
    var exclusionKeys: ExclusionKeys {
        ExclusionKeys(occurrence: occurrenceKey, series: seriesKey, include: includeKey)
    }
}

/// An original (not a copy) in a selected calendar, overlapping the window, that produces no copy.
public struct SkippedOriginal: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// The user chose not to mirror this meeting or its series.
        case excludedByUser
        case declined
        case free
        case pendingInvitation
        case allDayNotBusy
        /// Calendar has not given it a server identifier yet, so it has no marker.
        case notSyncedYet
        /// A busy real event at the identical slot suppresses its copy in every calendar its own calendar
        /// copies into (`SyncSettings.copies`); this names the first of them in selection order.
        case sameSlot(in: CalendarRef)
        /// The same meeting (same marker) in another selected calendar is copied instead, by the
        /// reconciler's same-marker winner rule; this names that original's calendar (for the first calendar
        /// in selection order that its own calendar copies into and that gets a copy).
        case copiedFrom(CalendarRef)
    }

    public var calendar: CalendarRef
    public var localID: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var reason: Reason
    /// The original's `ExclusionKey`s; nil without an external identifier, and the series key also for a
    /// single event.
    public var occurrenceKey: String?
    public var seriesKey: String?
    public var includeKey: String?
    /// For `.excludedByUser`: why it would produce no copy if the user had not excluded it; nil when it
    /// would be copied, and for every other reason.
    public var underlyingReason: Reason?

    public init(
        calendar: CalendarRef, localID: String, start: Date, end: Date, isAllDay: Bool, reason: Reason,
        occurrenceKey: String? = nil, seriesKey: String? = nil, includeKey: String? = nil,
        underlyingReason: Reason? = nil
    ) {
        self.calendar = calendar
        self.localID = localID
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.reason = reason
        self.occurrenceKey = occurrenceKey
        self.seriesKey = seriesKey
        self.includeKey = includeKey
        self.underlyingReason = underlyingReason
    }

    var exclusionKeys: ExclusionKeys {
        ExclusionKeys(occurrence: occurrenceKey, series: seriesKey, include: includeKey)
    }
}

/// Describes `planned`, the output of `reconcile` for the same events, settings and window, as one
/// `PlannedChange` per target and marker, sorted by start, then target id (then marker, so ties are
/// stable). The source of an add, move, retitle or duplicates removal is the original the reconciler mirrors; a
/// remove names an original only when one with the copy's marker is still visible outside the target. Every
/// entry carries its source's exclusion keys. An update of a copy whose start, end and all-day flag stay is a
/// `.retitle` when the copy reads another title than the wanted one (`titleDiffers`); any other update is a
/// `.move`.
public func plannedChanges(
    for planned: [SyncAction], events: [EventSnapshot], settings: SyncSettings, window: DateInterval
) -> [PlannedChange] {
    let selected = Set(settings.selected)
    let inScope = events.filter { selected.contains($0.calendar) }
    let desired = desiredCopies(events: events, settings: settings, window: window)

    // The occurrences of a recurring event share a local id, so lookups by it keep the first and never trap.
    struct ItemID: Hashable { let calendar: CalendarRef; let localID: String }
    let copies = Dictionary(
        inScope.filter { $0.marker != nil }.map { (ItemID(calendar: $0.calendar, localID: $0.localID), $0) },
        uniquingKeysWith: { first, _ in first }
    )

    struct Group {
        var create: CopySpec?
        var update: (localID: String, spec: CopySpec)?
        var deletes: [EventSnapshot] = []
    }
    var groups: [CopyKey: Group] = [:]
    for action in planned {
        switch action {
        case let .create(spec):
            groups[CopyKey(target: spec.target, marker: spec.marker), default: Group()].create = spec
        case let .update(localID, spec), let .replace(localID, spec):
            groups[CopyKey(target: spec.target, marker: spec.marker), default: Group()].update = (localID, spec)
        case let .delete(localID, target):
            // `reconcile` deletes only copies it was given; anything else has no marker to group by.
            guard let copy = copies[ItemID(calendar: target, localID: localID)], let marker = copy.marker else {
                continue
            }
            groups[CopyKey(target: target, marker: marker), default: Group()].deletes.append(copy)
        }
    }

    var originalsByMarker: [String: [EventSnapshot]] = [:]
    for e in inScope where e.marker == nil {
        if let marker = Marker.make(for: e) { originalsByMarker[marker, default: []].append(e) }
    }
    /// A copy in `target` is never of `target`'s own original, so only originals elsewhere count.
    func visibleOriginal(_ marker: String, outside target: CalendarRef) -> EventSnapshot? {
        originalsByMarker[marker]?.filter { $0.calendar != target }.min { a, b in
            if precedesAsSource(a, b) || precedesAsSource(b, a) { return precedesAsSource(a, b) }
            return a.localID < b.localID
        }
    }

    var entries: [(marker: String, change: PlannedChange)] = []
    for (key, group) in groups {
        let mirrored = desired[key]?.source
        var change: PlannedChange
        let source: EventSnapshot?
        if let spec = group.create {
            source = mirrored
            change = PlannedChange(kind: .add, target: key.target, start: spec.start, end: spec.end,
                                   isAllDay: spec.isAllDay, duplicatesRemoved: group.deletes.count)
        } else if let update = group.update {
            source = mirrored
            let old = copies[ItemID(calendar: key.target, localID: update.localID)]
            // Times first, then the title; nil for a move.
            let inPlace: PlannedChange.Kind?
            if let old, old.start == update.spec.start, old.end == update.spec.end,
               old.isAllDay == update.spec.isAllDay {
                inPlace = titleDiffers(old, from: update.spec) ? .retitle : nil
            } else {
                inPlace = nil
            }
            if let inPlace {
                change = PlannedChange(kind: inPlace, target: key.target, start: update.spec.start,
                                       end: update.spec.end, isAllDay: update.spec.isAllDay,
                                       duplicatesRemoved: group.deletes.count)
            } else {
                change = PlannedChange(kind: .move, target: key.target, start: update.spec.start,
                                       end: update.spec.end, isAllDay: update.spec.isAllDay,
                                       previousStart: old?.start, previousEnd: old?.end,
                                       previousIsAllDay: old?.isAllDay, duplicatesRemoved: group.deletes.count)
            }
        } else if let kept = desired[key] {
            source = kept.source
            change = PlannedChange(kind: .removeDuplicates, target: key.target, start: kept.spec.start,
                                   end: kept.spec.end, isAllDay: kept.spec.isAllDay,
                                   duplicatesRemoved: group.deletes.count)
        } else if let first = group.deletes.min(by: {
            ($0.start, $0.end, $0.localID) < ($1.start, $1.end, $1.localID)
        }) {
            source = visibleOriginal(key.marker, outside: key.target)
            change = PlannedChange(kind: .remove, target: key.target, start: first.start, end: first.end,
                                   isAllDay: first.isAllDay, duplicatesRemoved: group.deletes.count - 1)
        } else {
            continue
        }
        let keys = source.map(ExclusionKeys.init(for:))
        change.source = source?.calendar
        change.sourceLocalID = source?.localID
        change.occurrenceKey = keys?.occurrence
        change.seriesKey = keys?.series
        change.includeKey = keys?.include
        entries.append((key.marker, change))
    }
    return entries.sorted {
        ($0.change.start, $0.change.target.id, $0.marker) < ($1.change.start, $1.change.target.id, $1.marker)
    }.map(\.change)
}

/// Originals (not copies) in the selected calendars, overlapping the window, that produce no copy, with
/// the reason and their exclusion keys, sorted by start (then calendar id and local id). Only the calendars an
/// original's own calendar copies into count (`SyncSettings.copies`, its targets), and the originals of a calendar
/// that copies into none are not listed at all: the user chose that none of its meetings is copied. In order:
/// `excludedByUser` when the user excluded it, whatever its verdict; the busy verdict when it is not
/// busy; `notSyncedYet` without a marker; `copiedFrom` when targets get copies of the
/// same marker, but all of them from originals in other calendars (the reconciler's same-marker winner);
/// `sameSlot` when no target gets a copy of it, naming the first target in selection order. Such an original is
/// busy, has a marker and overlaps the window, so it competes for every target; with no copy desired there,
/// a real busy event sits at the winning slot in each of them. An original whose calendar supplies a copy
/// of its marker to at least one other calendar is at least partly mirrored and not listed. An excluded
/// original carries the reason it would have without exclusions (this function on the same events with
/// none, matched by calendar and occurrence key). Empty with fewer than two selected calendars.
public func notBusyOriginals(events: [EventSnapshot], settings: SyncSettings, window: DateInterval) -> [SkippedOriginal] {
    var seen = Set<CalendarRef>()
    let order = settings.selected.filter { seen.insert($0).inserted }
    guard order.count >= 2 else { return [] }
    let desired = desiredCopies(events: events, settings: settings, window: window)
    var targets: [CalendarRef: [CalendarRef]] = [:]
    for source in order { targets[source] = order.filter { settings.copies(from: source, to: $0) } }

    func reason(_ e: EventSnapshot) -> SkippedOriginal.Reason? {
        if settings.excludes(e) { return .excludedByUser }
        switch busyVerdict(e, unansweredAsBusy: settings.unansweredAsBusy) {
        case .copy: return nil
        case .declined: return .declined
        case .free: return .free
        case .pendingInvitation: return .pendingInvitation
        case .allDayNotBusy: return .allDayNotBusy
        case .busy:
            guard let marker = Marker.make(for: e) else { return .notSyncedYet }
            let others = targets[e.calendar] ?? []
            let copies = others.compactMap { desired[CopyKey(target: $0, marker: marker)] }
            if copies.contains(where: { $0.source.calendar == e.calendar }) { return nil }
            if let winner = copies.first { return .copiedFrom(winner.source.calendar) }
            return others.first.map { .sameSlot(in: $0) }
        }
    }

    struct OriginalID: Hashable { let calendar: CalendarRef; let key: String }
    var underlying: [OriginalID: SkippedOriginal.Reason] = [:]
    if !settings.excluded.isEmpty {
        var plain = settings
        plain.excluded = []
        for skipped in notBusyOriginals(events: events, settings: plain, window: window) {
            guard let key = skipped.occurrenceKey else { continue }
            underlying[OriginalID(calendar: skipped.calendar, key: key)] = skipped.reason
        }
    }

    var result: [SkippedOriginal] = []
    for e in events where e.marker == nil && !(targets[e.calendar] ?? []).isEmpty
        && e.start < window.end && e.end > window.start {
        guard let why = reason(e) else { continue }
        let keys = ExclusionKeys(for: e)
        let whyWithout = why == .excludedByUser
            ? keys.occurrence.flatMap { underlying[OriginalID(calendar: e.calendar, key: $0)] } : nil
        result.append(SkippedOriginal(calendar: e.calendar, localID: e.localID, start: e.start, end: e.end,
                                      isAllDay: e.isAllDay, reason: why, occurrenceKey: keys.occurrence,
                                      seriesKey: keys.series, includeKey: keys.include,
                                      underlyingReason: whyWithout))
    }
    return result.sorted { ($0.start, $0.calendar.id, $0.localID) < ($1.start, $1.calendar.id, $1.localID) }
}
