import Foundation

/// The model of the Meetings window: every meeting BusySign copies or would copy but for the user's choice,
/// one per original, grouped by the selected calendar it comes from, with recurring series as one row,
/// plus the originals that are not copied for other reasons and the busy blocks that go without a row
/// saying so. Times, calendars, local ids and opaque exclusion and hidden-title keys only, never event content;
/// the app joins titles by local id for display.
public struct MeetingsCatalog: Sendable, Equatable {
    public enum Tick: Sendable, Equatable { case on, off, mixed }

    public enum Label: Sendable, Equatable {
        /// Live only, past tense, from the live changes the app keeps (`LiveChanges`: the most recent run that
        /// changed something, merged with earlier ones while a run had failures), for the original's own
        /// copies: added or moved on a ticked row it still mirrors, removed on an unticked one whose
        /// copies are gone.
        case added, moved, removed
        /// Live only: unticked, but the last run still mirrored it; it goes on the next run.
        case pendingRemoval
        /// Live only: ticked, but the last run did not mirror it (it was excluded); it comes on the next run.
        case pendingAddition
    }

    /// One original: a single meeting, or one occurrence of a series.
    public struct Occurrence: Sendable, Equatable, Identifiable {
        /// The occurrence key (`ExclusionKey.occurrence`).
        public var id: String
        public var localID: String
        public var start: Date
        public var end: Date
        public var isAllDay: Bool
        /// Whether it is copied under the current exclusion set: what the next run with that set does.
        public var isOn: Bool
        /// Whether its copies may show its title under the current hidden-title set (the exclusion rule on that
        /// set); a target that shows `busyOnly` writes `Busy` either way. Independent of `isOn`.
        public var titleShown: Bool
        public var label: Label?
        public var seriesKey: String?
        public var includeKey: String?
    }

    public struct Row: Sendable, Equatable, Identifiable {
        /// The series key for a series, the occurrence key for a single meeting.
        public var id: String
        public var isSeries: Bool
        /// `.on` when every occurrence is on, `.off` when none is, `.mixed` otherwise.
        public var tick: Tick
        /// The same for `titleShown`.
        public var titleTick: Tick
        /// Sorted by start.
        public var occurrences: [Occurrence]
        /// The occurrence and include keys a click on the row clears: for a series, those of every
        /// occurrence of it the result knows, in Not copied too (occurrences outside the window are unknown,
        /// so keys the user set on them stay); for a single meeting, its own. Sorted.
        public var relatedKeys: [String]
    }

    public struct Section: Sendable, Equatable, Identifiable {
        /// The source calendar's id.
        public var id: String
        public var source: CalendarRef
        /// The other selected calendars `source` copies into (not on a pair set to `nothing`), in selection order.
        public var targets: [CalendarRef]
        /// Whether the route from `source` to some target shows titles (`CopyTitleFormat.showsTitle`: neither
        /// `busyOnly` nor `nothing`), so the rows' titles can be hidden.
        public var showsTitles: Bool
        /// Sorted by their first start.
        public var rows: [Row]
        /// Meetings from this source that are on.
        public var count: Int
        /// The same under the exclusions in effect (`appliedExcluded`), as the menu counts them: what the
        /// last run's list gives before any staged tick is applied.
        public var appliedCount: Int
    }

    /// An original that produces no copy for a reason other than the user's choice (for an excluded one,
    /// the reason it would have without the exclusion).
    public struct NotCopied: Sendable, Equatable, Identifiable {
        public var id: String
        public var calendar: CalendarRef
        public var localID: String
        public var start: Date
        public var end: Date
        public var isAllDay: Bool
        public var reason: SkippedOriginal.Reason
    }

    /// Busy blocks a run deletes in one target that no row shows with the "removed" label: a copy whose
    /// original is unknown, not copied any more, or still copied elsewhere, or duplicate copies of one
    /// meeting. Times are the change's (for duplicates, those of the copy that stays). The id is the target
    /// and the original's occurrence key, or the slot without one; copies of different unknown originals in
    /// one slot get a `#n` suffix by position, which is enough for a list without actions.
    public struct Removal: Sendable, Equatable, Identifiable {
        public var id: String
        public var target: CalendarRef
        public var start: Date
        public var end: Date
        public var isAllDay: Bool
        /// How many blocks: 1 for a removed copy, the number of duplicates otherwise.
        public var count: Int
        public var isDuplicate: Bool
    }

    /// One per selected calendar that copies into another one, in selection order, also without meetings; with one
    /// calendar selected, that one.
    public var sections: [Section]
    public var notCopied: [NotCopied]
    public var removals: [Removal]
    /// Meetings that are on, over all sections.
    public var copiedCount: Int
    public var notCopiedCount: Int
}

/// Builds the Meetings window's model from the last run's result, the current exclusion set, the current
/// hidden-title set and the current formats of the routes between the selected calendars.
///
/// - A section's targets are the selected calendars its source copies into under `titleFormats` (not on a pair set
///   to `nothing`). A source that copies into none of the other selected calendars has no section, and none of its
///   originals is a row or under Not copied: the pair choices are the user's own, like an unticked calendar.
/// - Rows are the originals the result mirrors, one per source calendar and occurrence key, and the ones
///   the user excluded that would be copied without the exclusion; each lands in its source calendar's
///   section, if that is still selected and has one. Occurrences sharing a series key form one series row, others are
///   single rows. `isOn` applies the exclusion rule to `excluded`, which may be newer than the result, so it
///   is what the next run with that set does.
/// - Labels, in Live only, by whether a row is on under `appliedExcluded`, the exclusions in effect (nil:
///   `excluded`): a tick only staged changes `isOn` and `count` but no label, since nothing happens before Apply.
///   `pendingRemoval` for a row that is off but the result mirrors, `pendingAddition` for one that is on but the
///   result does not mirror. Otherwise, from `lastLiveChanges` of the same source calendar and occurrence key
///   (only those whose target and source, when known, are in `selected`: the changes of a calendar unticked since
///   are gone with it): `added` (before `moved`) on a row that is on, `removed` on a row that is off and not
///   mirrored, whose copies are gone. In Dry run, no labels. A section's `appliedCount` counts the rows on under
///   `appliedExcluded` as `count` counts them under `excluded`.
/// - `titleShown` applies the same rule to `hiddenTitles`, and `titleTick` follows it as `tick` follows `isOn`;
///   neither changes `isOn`, labels or counts. A section `showsTitles` when the route from its source to one of
///   its targets shows titles in `titleFormats` (`CopyTitleFormat.showsTitle`; missing is `busyOnly`); routes into
///   the source and routes from or to a calendar not in `selected` do not count.
/// - `notCopied` lists the result's other skipped originals of the calendars with a section, an excluded one with
///   its underlying reason.
/// - `removals` covers every copy deleted by the result's changes (Dry run) or by those `lastLiveChanges` (Live),
///   in their order: one entry per remove that no row labelled `removed` of the same source calendar and
///   occurrence key covers, and one per entry with duplicates removed (any kind). With two selected
///   calendars each such label covers exactly one remove, so the removals' counts plus the `removed`
///   labels are the run's deletes; with more, one label covers the original's removes in every target.
public func meetingsCatalog(result: SyncResult, selected: [CalendarRef], excluded: Set<String>,
                            lastLiveChanges: [PlannedChange], hiddenTitles: Set<String> = [],
                            titleFormats: [CopyRoute: CopyTitleFormat] = [:],
                            appliedExcluded: Set<String>? = nil) -> MeetingsCatalog {
    let inEffect = appliedExcluded ?? excluded
    var seen = Set<CalendarRef>()
    let order = selected.filter { seen.insert($0).inserted }
    var targetsBySource: [CalendarRef: [CalendarRef]] = [:]
    for source in order { targetsBySource[source] = order.filter { titleFormats.copies(from: source, to: $0) } }
    // The sources with a section: those that copy into another calendar, or the one calendar selected.
    let shown = Set(order.filter { order.count < 2 || !(targetsBySource[$0] ?? []).isEmpty })
    let live = result.mode == .live
    let liveChanges = lastLiveChanges.filter { change in
        seen.contains(change.target) && (change.source.map(seen.contains) ?? true)
    }

    var lastKinds: [OriginalID: Set<PlannedChange.Kind>] = [:]
    for change in live ? liveChanges : [] {
        guard let source = change.source, let key = change.occurrenceKey else { continue }
        lastKinds[OriginalID(calendar: source, key: key), default: []].insert(change.kind)
    }
    func label(_ id: OriginalID, isOn: Bool, isMirrored: Bool) -> MeetingsCatalog.Label? {
        guard live else { return nil }
        let kinds = lastKinds[id] ?? []
        switch (isOn, isMirrored) {
        case (false, true): return .pendingRemoval
        case (true, false): return .pendingAddition
        case (true, true): return kinds.contains(.add) ? .added : kinds.contains(.move) ? .moved : nil
        case (false, false): return kinds.contains(.remove) ? .removed : nil
        }
    }

    var listed = Set<OriginalID>()
    /// The rows off under the exclusions in effect.
    var offInEffect = Set<OriginalID>()
    var byCalendar: [CalendarRef: [MeetingsCatalog.Occurrence]] = [:]
    func add(calendar: CalendarRef, localID: String, start: Date, end: Date, isAllDay: Bool, keys: ExclusionKeys,
             isMirrored: Bool) {
        guard let key = keys.occurrence, shown.contains(calendar) else { return }
        let id = OriginalID(calendar: calendar, key: key)
        guard listed.insert(id).inserted else { return }
        let isOn = !keys.isExcluded(in: excluded)
        let isOnInEffect = !keys.isExcluded(in: inEffect)
        if !isOnInEffect { offInEffect.insert(id) }
        byCalendar[calendar, default: []].append(MeetingsCatalog.Occurrence(
            id: key, localID: localID, start: start, end: end, isAllDay: isAllDay, isOn: isOn,
            titleShown: !keys.isExcluded(in: hiddenTitles),
            label: label(id, isOn: isOnInEffect, isMirrored: isMirrored),
            seriesKey: keys.series, includeKey: keys.include))
    }
    for item in result.mirroredItems {
        add(calendar: item.source, localID: item.sourceLocalID, start: item.start, end: item.end,
            isAllDay: item.isAllDay, keys: item.exclusionKeys, isMirrored: true)
    }
    for skipped in result.notBusy where skipped.reason == .excludedByUser && skipped.underlyingReason == nil {
        add(calendar: skipped.calendar, localID: skipped.localID, start: skipped.start, end: skipped.end,
            isAllDay: skipped.isAllDay, keys: skipped.exclusionKeys, isMirrored: false)
    }

    // Every occurrence and include key the result knows per series, rows and Not copied alike.
    var seriesKeys: [String: Set<String>] = [:]
    for keys in result.mirroredItems.map(\.exclusionKeys) + result.notBusy.map(\.exclusionKeys) {
        guard let series = keys.series else { continue }
        seriesKeys[series, default: []].formUnion([keys.occurrence, keys.include].compactMap { $0 })
    }

    let sections = order.filter(shown.contains).map { source in
        let rows = sectionRows(byCalendar[source] ?? [], seriesKeys: seriesKeys)
        let targets = targetsBySource[source] ?? []
        return MeetingsCatalog.Section(
            id: source.id, source: source, targets: targets,
            showsTitles: targets.contains { titleFormats.format(from: source, to: $0).showsTitle },
            rows: rows,
            count: rows.reduce(0) { $0 + $1.occurrences.filter(\.isOn).count },
            appliedCount: rows.reduce(0) { total, row in
                total + row.occurrences.count { !offInEffect.contains(OriginalID(calendar: source, key: $0.id)) }
            })
    }

    var notCopiedIDs = Set<String>()
    let notCopied: [MeetingsCatalog.NotCopied] = result.notBusy.compactMap { skipped in
        let reason = skipped.reason == .excludedByUser ? skipped.underlyingReason : skipped.reason
        guard let reason, shown.contains(skipped.calendar) else { return nil }
        let id = skipped.calendar.id + "|"
            + (skipped.occurrenceKey ?? "\(skipped.localID)@\(skipped.start.timeIntervalSince1970)")
        guard notCopiedIDs.insert(id).inserted else { return nil }
        return MeetingsCatalog.NotCopied(id: id, calendar: skipped.calendar, localID: skipped.localID,
                                         start: skipped.start, end: skipped.end, isAllDay: skipped.isAllDay,
                                         reason: reason)
    }

    let labelledRemoved = Set(sections.flatMap { section in
        section.rows.flatMap(\.occurrences).filter { $0.label == .removed }
            .map { OriginalID(calendar: section.source, key: $0.id) }
    })
    var removalIDs: [String: Int] = [:]
    var removals: [MeetingsCatalog.Removal] = []
    func addRemoval(_ change: PlannedChange, count: Int, isDuplicate: Bool) {
        let base = change.blockKey + (isDuplicate ? "|duplicates" : "")
        removalIDs[base, default: 0] += 1
        let n = removalIDs[base] ?? 1
        removals.append(MeetingsCatalog.Removal(
            id: n == 1 ? base : "\(base)#\(n)", target: change.target, start: change.start, end: change.end,
            isAllDay: change.isAllDay, count: count, isDuplicate: isDuplicate))
    }
    for change in live ? liveChanges : result.changes {
        if change.kind == .remove {
            let covered = change.source.flatMap { source in
                change.occurrenceKey.map { labelledRemoved.contains(OriginalID(calendar: source, key: $0)) }
            } ?? false
            if !covered { addRemoval(change, count: 1, isDuplicate: false) }
        }
        if change.duplicatesRemoved > 0 { addRemoval(change, count: change.duplicatesRemoved, isDuplicate: true) }
    }

    return MeetingsCatalog(sections: sections, notCopied: notCopied, removals: removals,
                           copiedCount: sections.reduce(0) { $0 + $1.count }, notCopiedCount: notCopied.count)
}

/// An original in the catalog: its calendar and occurrence key.
private struct OriginalID: Hashable {
    let calendar: CalendarRef
    let key: String
}

/// One section's rows: occurrences sharing a series key form one series row, the others single rows;
/// rows by their first start, occurrences by start (then id, so ties are stable). `seriesKeys` holds the
/// known occurrence and include keys of each series.
private func sectionRows(_ occurrences: [MeetingsCatalog.Occurrence],
                         seriesKeys: [String: Set<String>]) -> [MeetingsCatalog.Row] {
    let sorted = occurrences.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    var series: [String: [MeetingsCatalog.Occurrence]] = [:]
    var rows: [MeetingsCatalog.Row] = []
    for occurrence in sorted {
        if let key = occurrence.seriesKey {
            series[key, default: []].append(occurrence)
        } else {
            let own = [occurrence.id, occurrence.includeKey].compactMap { $0 }.sorted()
            rows.append(MeetingsCatalog.Row(id: occurrence.id, isSeries: false, tick: occurrence.isOn ? .on : .off,
                                            titleTick: occurrence.titleShown ? .on : .off,
                                            occurrences: [occurrence], relatedKeys: own))
        }
    }
    for (key, days) in series {
        let own = days.flatMap { [$0.id, $0.includeKey].compactMap { $0 } }
        rows.append(MeetingsCatalog.Row(id: key, isSeries: true, tick: tick(days.map(\.isOn)),
                                        titleTick: tick(days.map(\.titleShown)), occurrences: days,
                                        relatedKeys: seriesKeys[key, default: []].union(own).sorted()))
    }
    return rows.sorted { ($0.occurrences[0].start, $0.id) < ($1.occurrences[0].start, $1.id) }
}

/// `.on` when every flag is set, `.off` when none is, `.mixed` otherwise.
private func tick(_ flags: [Bool]) -> MeetingsCatalog.Tick {
    let on = flags.filter { $0 }.count
    return on == flags.count ? .on : on == 0 ? .off : .mixed
}

/// The exclusion set after the user ticks (`on`) or unticks one occurrence or single meeting: unticking
/// drops its include key when its series is excluded, else adds its occurrence key; ticking drops its
/// occurrence key and, when its series is excluded, adds its include key. The hidden-title set changes the same
/// way, with `on` for a title shown.
public func toggling(_ occurrence: MeetingsCatalog.Occurrence, to on: Bool, in excluded: Set<String>) -> Set<String> {
    var keys = excluded
    let seriesExcluded = occurrence.seriesKey.map(excluded.contains) ?? false
    if on {
        keys.remove(occurrence.id)
        if seriesExcluded, let include = occurrence.includeKey { keys.insert(include) }
    } else if seriesExcluded {
        if let include = occurrence.includeKey { keys.remove(include) }
    } else {
        keys.insert(occurrence.id)
    }
    return keys
}

/// The exclusion set after the user clicks a row's checkbox (`toggling(_:tick:in:)` with the row's `tick`).
public func toggling(_ row: MeetingsCatalog.Row, in excluded: Set<String>) -> Set<String> {
    toggling(row, tick: row.tick, in: excluded)
}

/// The key set after the user clicks a row's box that shows `tick`: the exclusion set with the row's `tick`, the
/// hidden-title set with its `titleTick`. A series row that is on adds the series key; one that is off or mixed
/// drops it. Either way the occurrence and include keys of every occurrence of the series the catalog knows
/// (`relatedKeys`) go; keys set on occurrences outside the window stay. A single meeting's row toggles its
/// occurrence (`toggling(_:to:in:)`), on unless `tick` is on.
public func toggling(_ row: MeetingsCatalog.Row, tick: MeetingsCatalog.Tick, in keys: Set<String>) -> Set<String> {
    guard row.isSeries else {
        guard let occurrence = row.occurrences.first else { return keys }
        return toggling(occurrence, to: tick != .on, in: keys)
    }
    var result = keys.subtracting(row.relatedKeys)
    if tick == .on { result.insert(row.id) } else { result.remove(row.id) }
    return result
}

/// A short description of when a series meets, for display; `time` holds the hour and minute, and is
/// empty for an all-day series.
public enum SeriesPattern: Sendable, Equatable {
    /// Every working day, Monday to Friday, at the same time.
    case weekdays(time: DateComponents)
    /// On one weekday (`Calendar` numbering, 1 is Sunday) at the same time.
    case weekly(weekday: Int, time: DateComponents)
    /// Every day at the same time.
    case daily(time: DateComponents)
    /// Anything else; `first` is the earliest start.
    case irregular(first: Date)
}

/// The pattern of a series' starts, read in `calendar` (its time zone decides hour, minute and weekday):
/// all on one weekday at the same time is `weekly` (so is a single start); consecutive working days at the
/// same time, Friday followed by Monday, is `weekdays`; consecutive days at the same time is `daily`;
/// anything else, or no starts (`distantPast`), is `irregular`.
public func seriesPattern(_ starts: [Date], isAllDay: Bool, calendar: Calendar) -> SeriesPattern {
    let sorted = starts.sorted()
    guard let first = sorted.first else { return .irregular(first: .distantPast) }
    func time(_ date: Date) -> DateComponents {
        guard !isAllDay else { return DateComponents() }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return DateComponents(hour: c.hour, minute: c.minute)
    }
    let firstTime = time(first)
    guard sorted.allSatisfy({ time($0) == firstTime }) else { return .irregular(first: first) }

    let weekdays = sorted.map { calendar.component(.weekday, from: $0) }
    if Set(weekdays).count == 1 { return .weekly(weekday: weekdays[0], time: firstTime) }

    let gaps = zip(sorted, sorted.dropFirst()).map { earlier, later in
        calendar.dateComponents([.day], from: calendar.startOfDay(for: earlier),
                                to: calendar.startOfDay(for: later)).day ?? 0
    }
    let monday = 2, friday = 6
    let onWorkingDays = weekdays.allSatisfy { (monday...friday).contains($0) }
    let noWorkingDaySkipped = zip(gaps, weekdays.dropFirst()).allSatisfy { gap, next in
        gap == 1 || (gap == 3 && next == monday)
    }
    if onWorkingDays && noWorkingDaySkipped { return .weekdays(time: firstTime) }
    if gaps.allSatisfy({ $0 == 1 }) { return .daily(time: firstTime) }
    return .irregular(first: first)
}
