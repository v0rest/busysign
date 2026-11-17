import Foundation
import Testing
@testable import BusySignCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400
private let window = DateInterval(start: t0 - day, duration: 30 * day)
private let A = CalendarRef(id: "A")
private let B = CalendarRef(id: "B")
private let C = CalendarRef(id: "C")

/// The route from `source` to `target`.
private func route(_ source: CalendarRef, _ target: CalendarRef) -> CopyRoute {
    CopyRoute(source: source, target: target)
}

/// An original of one hour, or of one day when all-day.
private func orig(_ cal: String, _ ext: String? = "ext", local: String? = nil, start: Date = t0,
                  recurring: Bool = false, allDay: Bool = false, availability: Availability = .busy,
                  response: MyResponse = .accepted) -> EventSnapshot {
    snap(calendar: cal, localID: local ?? "\(cal)-\(ext ?? "none")", externalID: ext, occurrenceDate: start,
         isRecurringOccurrence: recurring, start: start, end: start + (allDay ? day : 3600), isAllDay: allDay,
         availability: availability, myResponse: response)
}

/// `count` daily occurrences of one series in `cal`, sharing its external and local ids.
private func series(_ cal: String, _ ext: String, count: Int, from: Date = t0) -> [EventSnapshot] {
    (0..<count).map { orig(cal, ext, local: "\(cal)-\(ext)", start: from + Double($0) * day, recurring: true) }
}

/// A copy of `o`, at its times or moved to `start`.
private func copy(_ cal: String, of o: EventSnapshot, local: String, ext: String? = nil,
                  start: Date? = nil) -> EventSnapshot {
    let begin = start ?? o.start
    return snap(calendar: cal, localID: local, externalID: ext, start: begin,
                end: begin + o.end.timeIntervalSince(o.start), isAllDay: o.isAllDay, marker: Marker.make(for: o))
}

/// Applies a plan to the events the way a store would.
private func apply(_ planned: [SyncAction], to events: [EventSnapshot]) -> [EventSnapshot] {
    var out = events
    for (n, action) in planned.enumerated() {
        switch action {
        case let .create(spec):
            out.append(snap(calendar: spec.target.id, localID: "new-\(n)", externalID: nil, start: spec.start,
                            end: spec.end, isAllDay: spec.isAllDay, marker: spec.marker))
        case let .update(localID, spec):
            if let i = out.firstIndex(where: { $0.localID == localID && $0.calendar == spec.target }) {
                out[i].start = spec.start
                out[i].end = spec.end
                out[i].isAllDay = spec.isAllDay
            }
        case let .replace(localID, spec):
            out.append(snap(calendar: spec.target.id, localID: "new-\(n)", externalID: nil, start: spec.start,
                            end: spec.end, isAllDay: spec.isAllDay, marker: spec.marker))
            out.removeAll { $0.localID == localID && $0.calendar == spec.target }
        case let .delete(localID, target):
            out.removeAll { $0.localID == localID && $0.calendar == target }
        }
    }
    return out
}

/// What `SyncEngine.runOnce` reports for these events, built from the same functions; `formats` are the pairs'
/// choices (none: every pair `Busy only`).
private func result(_ events: [EventSnapshot], _ cals: [CalendarRef] = [A, B],
                    formats: [CopyRoute: CopyTitleFormat] = [:], excluded: Set<String> = [],
                    mode: SyncMode = .dryRun, in window: DateInterval = window) -> SyncResult {
    let s = SyncSettings(selected: cals, excluded: excluded, copyTitleFormats: formats)
    let planned = reconcile(events: events, settings: s, window: window)
    return SyncResult(at: t0, mode: mode, planned: planned,
                      changes: plannedChanges(for: planned, events: events, settings: s, window: window),
                      notBusy: notBusyOriginals(events: events, settings: s, window: window),
                      mirroredItems: mirroredItems(events: events, settings: s, window: window))
}

/// The catalog right after a run with the same exclusions.
private func catalog(_ events: [EventSnapshot], _ cals: [CalendarRef] = [A, B], excluded: Set<String> = [],
                     mode: SyncMode = .dryRun, lastLive: [PlannedChange] = []) -> MeetingsCatalog {
    meetingsCatalog(result: result(events, cals, excluded: excluded, mode: mode), selected: cals,
                    excluded: excluded, lastLiveChanges: lastLive)
}

/// For runs through `SyncEngine`, whose window starts today: a clock at 10:00 on t0's day, and an original
/// (or, with a marker, a copy) `hours` after it.
private let engineNow = Calendar.current.startOfDay(for: t0).addingTimeInterval(10 * 3600)
private let engineA = CalendarRef(id: "cal-a")
private let engineB = CalendarRef(id: "cal-b")

private func engineEvent(_ cal: String, _ id: String, hours: Double, marker: String? = nil,
                         response: MyResponse = .accepted) -> EventSnapshot {
    let start = engineNow.addingTimeInterval(hours * 3600)
    return snap(calendar: cal, localID: id, externalID: marker == nil ? "ext-\(id)" : nil, occurrenceDate: start,
                start: start, end: start.addingTimeInterval(3600), myResponse: response, marker: marker)
}

/// Two live runs over `events` in cal-a and cal-b: the one that changes things and the follow-up.
private func twoLiveRuns(_ events: [EventSnapshot], excluded: Set<String>) async
    -> (first: SyncResult, second: SyncResult) {
    let store = FakeCalendarStore(
        calendars: [FakeCalendarStore.calendar("cal-a"), FakeCalendarStore.calendar("cal-b")], events: events)
    let engine = SyncEngine(store: store, now: { engineNow })
    let settings = SyncSettings(selected: [engineA, engineB], excluded: excluded)
    let first = await engine.runOnce(settings: settings, mode: .live, tracker: ChangeTracker(), staleThreshold: 86_400)
    let second = await engine.runOnce(settings: settings, mode: .live, tracker: first.tracker,
                                      staleThreshold: 86_400)
    return (first.result, second.result)
}

private func deletes(_ planned: [SyncAction]) -> Int {
    planned.filter { if case .delete = $0 { true } else { false } }.count
}

/// The deletes a catalog shows: the listed removals' blocks plus the rows labelled "removed". With two
/// selected calendars each such label stands for one copy.
private func shownDeletes(_ c: MeetingsCatalog) -> Int {
    c.removals.reduce(0) { $0 + $1.count } + c.allOccurrences.filter { $0.label == .removed }.count
}

/// The next run with `excluded` over the same events: a row is on exactly when that run mirrors its
/// original, and the copied count is that run's meetings.
private func expectAgreesWithNextRun(_ c: MeetingsCatalog, _ events: [EventSnapshot], _ cals: [CalendarRef],
                                     excluded: Set<String>, sourceLocation: SourceLocation = #_sourceLocation) {
    let next = result(events, cals, excluded: excluded)
    let mirrored = Set(next.mirroredItems.map { "\($0.source.id)|\($0.occurrenceKey ?? "")" })
    for section in c.sections {
        for occurrence in section.rows.flatMap(\.occurrences) {
            #expect(occurrence.isOn == mirrored.contains("\(section.id)|\(occurrence.id)"),
                    "\(section.id) \(occurrence.localID) at \(occurrence.start)", sourceLocation: sourceLocation)
        }
    }
    #expect(c.copiedCount == mirrored.count, sourceLocation: sourceLocation)
}

private func key(_ e: EventSnapshot) throws -> String { try #require(ExclusionKey.occurrence(for: e)) }
private func seriesKey(_ e: EventSnapshot) throws -> String { try #require(ExclusionKey.series(for: e)) }
private func includeKey(_ e: EventSnapshot) throws -> String { try #require(ExclusionKey.include(for: e)) }

private extension MeetingsCatalog {
    func section(_ cal: CalendarRef) throws -> Section { try #require(sections.first { $0.source == cal }) }
    func row(_ id: String, in cal: CalendarRef = A) throws -> Row {
        try #require(try section(cal).rows.first { $0.id == id })
    }
    func occurrence(_ id: String, in cal: CalendarRef = A) throws -> Occurrence {
        try #require(try section(cal).rows.flatMap(\.occurrences).first { $0.id == id })
    }
    var allOccurrences: [Occurrence] { sections.flatMap { $0.rows.flatMap(\.occurrences) } }
}

@Suite struct MeetingsCatalogTests {
    // MARK: - Catalog

    @Test func groupsBySourceThenSeries() throws {
        let standUp = series("A", "standup", count: 3)
        let before = orig("A", "before", start: t0 - 3600)
        let between = orig("A", "between", start: t0 + 3600)
        let inB = orig("B", "b", start: t0 + 7200)
        let r = catalog(standUp.reversed() + [between, inB, before], [B, A])

        #expect(r.sections.map(\.id) == ["B", "A"])
        #expect(r.sections.map(\.source) == [B, A])
        #expect(r.sections.map(\.targets) == [[A], [B]])
        let a = try r.section(A)
        #expect(a.rows.map(\.id) == (try [key(before), seriesKey(standUp[0]), key(between)]))
        #expect(a.rows.map(\.isSeries) == [false, true, false])
        #expect(a.rows[1].occurrences.map(\.id) == (try standUp.map(key)))
        #expect(a.rows[1].occurrences.map(\.start) == standUp.map(\.start))
        #expect(a.rows[1].occurrences.allSatisfy { $0.localID == "A-standup" && $0.isOn && $0.label == nil })
        #expect(a.rows[1].occurrences.map(\.seriesKey) == Array(repeating: try seriesKey(standUp[0]), count: 3))
        #expect(a.rows[1].occurrences.map(\.includeKey) == (try standUp.map(includeKey)))
        #expect(a.rows[0].occurrences == [
            MeetingsCatalog.Occurrence(id: try key(before), localID: before.localID, start: before.start,
                                       end: before.end, isAllDay: false, isOn: true, titleShown: true, label: nil,
                                       seriesKey: nil, includeKey: try includeKey(before)),
        ])
        #expect(a.count == 5)
        #expect(try r.section(B).rows.map(\.id) == [try key(inB)])
        #expect(try r.section(B).count == 1)
        #expect(r.copiedCount == 6)
        #expect(r.notCopied.isEmpty)
        #expect(r.notCopiedCount == 0)
        #expect(r.removals.isEmpty)
    }

    /// One section per selected calendar, in selection order, even without meetings; originals of a
    /// calendar no longer selected are left out.
    @Test func everySelectedCalendarHasASection() throws {
        let a = orig("A", "a")
        let r = catalog([a], [A, B, C])
        #expect(r.sections.map(\.id) == ["A", "B", "C"])
        #expect(r.sections.map(\.count) == [1, 0, 0])
        #expect(r.sections.map(\.targets) == [[B, C], [A, C], [A, B]])

        let declined = orig("A", "d", start: t0 + 3600, response: .declined)
        let narrowed = meetingsCatalog(result: result([a, declined], [A, B, C]), selected: [B, C, B],
                                       excluded: [], lastLiveChanges: [])
        #expect(narrowed.sections.map(\.id) == ["B", "C"])
        #expect(narrowed.sections.map(\.rows.count) == [0, 0])
        #expect(narrowed.notCopied.isEmpty)
        #expect(narrowed.copiedCount == 0)
    }

    @Test func seriesTickMixed() throws {
        let days = series("A", "s", count: 3)
        let id = try seriesKey(days[0])

        #expect(try catalog(days).row(id).tick == .on)

        let mixed = catalog(days, excluded: [try key(days[1])])
        #expect(try mixed.row(id).tick == .mixed)
        #expect(try mixed.row(id).occurrences.map(\.isOn) == [true, false, true])
        #expect(try mixed.section(A).count == 2)
        #expect(mixed.copiedCount == 2)

        let off = catalog(days, excluded: [id])
        #expect(try off.row(id).tick == .off)
        #expect(try off.row(id).occurrences.map(\.isOn) == [false, false, false])
        #expect(off.copiedCount == 0)

        let oneIncluded = catalog(days, excluded: [id, try includeKey(days[2])])
        #expect(try oneIncluded.row(id).tick == .mixed)
        #expect(try oneIncluded.row(id).occurrences.map(\.isOn) == [false, false, true])
    }

    @Test func excludedMeetingStaysInItsSection() throws {
        let a = orig("A", "a")
        let declined = orig("A", "d", start: t0 + 3600, response: .declined)
        let r = catalog([a, declined], excluded: [try key(a)])

        let rows = try r.section(A).rows
        #expect(rows.map(\.id) == [try key(a)])
        #expect(rows.map(\.tick) == [.off])
        #expect(rows[0].occurrences.map(\.isOn) == [false])
        #expect(rows[0].occurrences.map(\.localID) == [a.localID])
        #expect(try r.section(A).count == 0)
        #expect(r.copiedCount == 0)

        #expect(r.notCopied.map(\.localID) == [declined.localID])
        #expect(r.notCopied.map(\.reason) == [.declined])
        #expect(r.notCopied.map(\.calendar) == [A])
        #expect(r.notCopied.map(\.start) == [declined.start])
        #expect(r.notCopiedCount == 1)
    }

    /// Exclusion keys are per meeting: the same meeting mirrored from two calendars shows in both
    /// sections, and unticking either unticks both.
    @Test func sameMeetingInTwoCalendarsSharesTick() throws {
        // Same external id at different times (one calendar not caught up yet): each is the source of a copy.
        let inA = orig("A", "x", local: "la", start: t0 + 7200)
        let inB = orig("B", "x", local: "lb", start: t0)
        let shared = try key(inA)
        #expect(try key(inB) == shared)

        let r = catalog([inA, inB])
        #expect(try r.section(A).rows.map(\.id) == [shared])
        #expect(try r.section(B).rows.map(\.id) == [shared])
        #expect(r.copiedCount == 2)

        let excluded = toggling(try r.occurrence(shared, in: A), to: false, in: [])
        #expect(excluded == [shared])
        let unticked = meetingsCatalog(result: result([inA, inB]), selected: [A, B], excluded: excluded,
                                       lastLiveChanges: [])
        #expect(unticked.allOccurrences.map(\.localID) == ["la", "lb"])
        #expect(unticked.allOccurrences.map(\.isOn) == [false, false])

        // After the next run both originals are excluded and stay in their sections, unticked.
        let next = catalog([inA, inB], excluded: excluded)
        #expect(next.allOccurrences.map(\.localID) == ["la", "lb"])
        #expect(next.allOccurrences.map(\.isOn) == [false, false])
        #expect(next.notCopied.isEmpty)

        let ticked = toggling(try next.occurrence(shared, in: B), to: true, in: excluded)
        #expect(ticked.isEmpty)
    }

    /// Three calendars, the same meeting in A and B at the same time: A's original is copied into C, B's
    /// gets no copy and is listed as copied from A, the reconciler's winner (lowest calendar id).
    @Test func copiedFromReasonForThirdCalendar() throws {
        let inA = orig("A", "x", local: "la")
        let inB = orig("B", "x", local: "lb")
        for order in [[A, B, C], [C, B, A]] {
            let r = catalog([inB, inA], order)
            #expect(try r.section(A).rows.map(\.id) == [try key(inA)])
            #expect(try r.section(B).rows.isEmpty)
            #expect(r.notCopied.map(\.localID) == ["lb"])
            #expect(r.notCopied.map(\.reason) == [.copiedFrom(A)])
            #expect(r.notCopiedCount == 1)
            #expect(r.copiedCount == 1)
        }
    }

    /// Every copy a run deletes is listed unless a row shows it with the "removed" label, which only
    /// Live has.
    @Test func removalsNotShownAsRowLabelListed() throws {
        let a = orig("A", "a")
        let gone = orig("A", "gone", start: t0 + 3600)
        let events = [a, copy("B", of: a, local: "c-a"), copy("B", of: gone, local: "c-gone")]
        let excluded: Set<String> = [try key(a)]

        // Dry run: no labels, so the excluded meeting's copy is listed next to the copy without an original.
        let dry = catalog(events, excluded: excluded)
        #expect(dry.removals.map(\.target) == [B, B])
        #expect(dry.removals.map(\.start) == [a.start, gone.start])
        #expect(dry.removals.map(\.end) == [a.end, gone.end])
        #expect(dry.removals.map(\.isAllDay) == [false, false])
        #expect(dry.removals.map(\.count) == [1, 1])
        #expect(dry.removals.map(\.isDuplicate) == [false, false])
        #expect(try dry.section(A).rows.map(\.id) == [try key(a)])

        // Live: what the last run that changed something removed, not what this result plans; the excluded
        // meeting's removal is its row's label.
        let live = result(events, excluded: excluded, mode: .live)
        #expect(meetingsCatalog(result: live, selected: [A, B], excluded: excluded, lastLiveChanges: [])
            .removals.isEmpty)
        let followUp = result([a], excluded: excluded, mode: .live)
        #expect(followUp.changes.isEmpty)
        let afterwards = meetingsCatalog(result: followUp, selected: [A, B], excluded: excluded,
                                         lastLiveChanges: live.changes)
        #expect(afterwards.removals.map(\.start) == [gone.start])
        #expect(try afterwards.occurrence(try key(a)).label == .removed)

        // Two copies without an original in the same slot keep distinct ids.
        let gone2 = orig("A", "gone2", start: t0 + 3600)
        let twins = catalog([copy("B", of: gone, local: "c1"), copy("B", of: gone2, local: "c2")])
        #expect(twins.removals.count == 2)
        #expect(Set(twins.removals.map(\.id)).count == 2)
    }

    /// In Live, labels come from the last run that changed something, also after an empty follow-up run.
    @Test func liveLabelsFromLastChanges() async throws {
        let added = engineEvent("cal-a", "added", hours: 2)
        let moved = engineEvent("cal-a", "moved", hours: 4)
        let removed = engineEvent("cal-a", "removed", hours: 6)
        let kept = engineEvent("cal-a", "kept", hours: 8)
        let gone = engineEvent("cal-a", "gone", hours: 10)
        let excluded: Set<String> = [try key(removed)]
        let runs = await twoLiveRuns([
            added, moved, removed, kept,
            engineEvent("cal-b", "c-moved", hours: 3, marker: Marker.make(for: moved)),
            engineEvent("cal-b", "c-removed", hours: 6, marker: Marker.make(for: removed)),
            engineEvent("cal-b", "c-kept", hours: 8, marker: Marker.make(for: kept)),
            engineEvent("cal-b", "c-gone", hours: 10, marker: Marker.make(for: gone)),
        ], excluded: excluded)
        #expect(runs.first.report == ApplyReport(created: 1, replaced: 1, deleted: 2))
        #expect(runs.second.changes.isEmpty)

        let r = meetingsCatalog(result: runs.second, selected: [engineA, engineB], excluded: excluded,
                                lastLiveChanges: runs.first.changes)
        let occurrences = try r.section(engineA).rows.flatMap(\.occurrences)
        #expect(occurrences.map(\.localID) == ["added", "moved", "removed", "kept"])
        #expect(occurrences.map(\.label) == [.added, .moved, .removed, nil])
        #expect(occurrences.map(\.isOn) == [true, true, false, true])
        // The excluded meeting's removal shows as its row's label; the gone one's as a removal.
        #expect(r.removals.map(\.target) == [engineB])
        #expect(r.removals.map(\.start) == [gone.start])
    }

    @Test func dryRunHasNoLabels() throws {
        let a = orig("A", "a")
        let b = orig("A", "b", start: t0 + 3600)
        let excludedNow: Set<String> = [try key(b)]

        let dry = result([a, b])
        let r = meetingsCatalog(result: dry, selected: [A, B], excluded: excludedNow, lastLiveChanges: dry.changes)
        #expect(r.allOccurrences.map(\.isOn) == [true, false])
        #expect(r.allOccurrences.map(\.label) == [nil, nil])

        let live = result([a, b], mode: .live)
        let l = meetingsCatalog(result: live, selected: [A, B], excluded: excludedNow, lastLiveChanges: live.changes)
        #expect(l.allOccurrences.map(\.label) == [.added, .pendingRemoval])
    }

    /// Paused Live: the last run mirrored the meeting and the user has unticked it since. It is still
    /// copied, so it reads as pending removal, not as the last run's "added" nor as "removed".
    @Test func untickedButMirroredIsPendingRemoval() throws {
        let a = orig("A", "a")
        let last = result([a], mode: .live)
        #expect(last.changes.map(\.kind) == [.add])
        let r = meetingsCatalog(result: last, selected: [A, B], excluded: [try key(a)], lastLiveChanges: last.changes)
        let occurrence = try r.occurrence(try key(a))
        #expect(!occurrence.isOn)
        #expect(occurrence.label == .pendingRemoval)
        #expect(r.copiedCount == 0)
    }

    @Test func tickedButNotMirroredIsPendingAddition() throws {
        let a = orig("A", "a")
        let excluded: Set<String> = [try key(a)]
        let last = result([a], excluded: excluded, mode: .live)
        let r = meetingsCatalog(result: last, selected: [A, B], excluded: [], lastLiveChanges: [])
        let occurrence = try r.occurrence(try key(a))
        #expect(occurrence.isOn)
        #expect(occurrence.label == .pendingAddition)
        #expect(r.copiedCount == 1)
    }

    /// Live, an untick only staged: the row shows the staged tick, but labels follow the exclusions in effect
    /// (`appliedExcluded`), so no pending label until Apply; the section's `count` follows the tick and
    /// `appliedCount` the exclusions in effect. Once applied, the same untick is pending removal.
    @Test func stagedUntickHasNoPendingLabel() throws {
        let a = orig("A", "a")
        let last = result([a], mode: .live)
        let excluded: Set<String> = [try key(a)]
        let staged = meetingsCatalog(result: last, selected: [A, B], excluded: excluded, lastLiveChanges: [],
                                     appliedExcluded: [])
        let occurrence = try staged.occurrence(try key(a))
        #expect(!occurrence.isOn)
        #expect(occurrence.label == nil)
        #expect(try staged.section(A).count == 0)
        #expect(try staged.section(A).appliedCount == 1)

        let applied = meetingsCatalog(result: last, selected: [A, B], excluded: excluded, lastLiveChanges: [],
                                      appliedExcluded: excluded)
        #expect(try applied.occurrence(try key(a)).label == .pendingRemoval)
        #expect(try applied.section(A).appliedCount == 0)
        // Without `appliedExcluded`, the exclusions given are the ones in effect.
        let plain = meetingsCatalog(result: last, selected: [A, B], excluded: excluded, lastLiveChanges: [])
        #expect(plain == applied)
    }

    /// Live, a tick only staged of a meeting the last run left out: no pending addition until Apply.
    @Test func stagedTickHasNoPendingLabel() throws {
        let a = orig("A", "a")
        let excluded: Set<String> = [try key(a)]
        let last = result([a], excluded: excluded, mode: .live)
        let staged = meetingsCatalog(result: last, selected: [A, B], excluded: [], lastLiveChanges: [],
                                     appliedExcluded: excluded)
        let occurrence = try staged.occurrence(try key(a))
        #expect(occurrence.isOn)
        #expect(occurrence.label == nil)
        #expect(try staged.section(A).count == 1)
        #expect(try staged.section(A).appliedCount == 0)
    }

    @Test func rowIDsAreKeys() throws {
        let days = series("A", "s", count: 2)
        let single = orig("A", "single", start: t0 + 3600)
        let r = catalog(days + [single])
        let rows = try r.section(A).rows
        #expect(r.sections.map(\.id) == ["A", "B"])
        #expect(rows.map(\.id) == (try [seriesKey(days[0]), key(single)]))
        #expect(rows[0].occurrences.map(\.id) == (try days.map(key)))
        #expect(rows[1].occurrences.map(\.id) == [try key(single)])

        // Excluding a meeting or a new earlier meeting changes neither the ids nor what each id holds.
        let early = orig("A", "early", start: t0 - 7200)
        let after = catalog([early] + days + [single], excluded: [try key(single)])
        let afterRows = try after.section(A).rows
        #expect(afterRows.map(\.id) == (try [key(early), seriesKey(days[0]), key(single)]))
        #expect(Array(afterRows.dropFirst()).map { $0.occurrences.map(\.localID) }
            == rows.map { $0.occurrences.map(\.localID) })
        #expect(Array(afterRows.dropFirst()).map { $0.occurrences.map(\.start) }
            == rows.map { $0.occurrences.map(\.start) })
    }

    /// A declined meeting's copy goes; its original is known but sits in Not copied, so the removal is
    /// listed, in Dry run and after the Live run.
    @Test func declinedOriginalsCopyIsARemoval() throws {
        let declined = orig("A", "d", response: .declined)
        let events = [declined, copy("B", of: declined, local: "c-d")]
        let dry = result(events)
        #expect(dry.changes.map(\.occurrenceKey) == [try key(declined)])

        let r = meetingsCatalog(result: dry, selected: [A, B], excluded: [], lastLiveChanges: [])
        #expect(r.notCopied.map(\.reason) == [.declined])
        #expect(r.removals == [
            MeetingsCatalog.Removal(id: "B|" + (try key(declined)), target: B, start: declined.start,
                                    end: declined.end, isAllDay: false, count: 1, isDuplicate: false),
        ])

        let live = result(events, mode: .live)
        let afterwards = meetingsCatalog(result: result([declined], mode: .live), selected: [A, B], excluded: [],
                                         lastLiveChanges: live.changes)
        #expect(afterwards.removals.map(\.count) == [1])
        #expect(afterwards.removals.map(\.isDuplicate) == [false])
    }

    @Test func duplicatesAreADuplicateRemovalWithCount() throws {
        let a = orig("A", "a")
        let events = [a] + [("c-keep", "e1"), ("c-drop1", "e2"), ("c-drop2", "e3")].map {
            copy("B", of: a, local: $0.0, ext: $0.1)
        }
        for mode in [SyncMode.dryRun, .live] {
            let run = result(events, mode: mode)
            #expect(run.changes.map(\.kind) == [.removeDuplicates])
            let r = meetingsCatalog(result: run, selected: [A, B], excluded: [], lastLiveChanges: run.changes)
            #expect(r.removals.map(\.target) == [B])
            #expect(r.removals.map(\.start) == [a.start])
            #expect(r.removals.map(\.count) == [2])
            #expect(r.removals.map(\.isDuplicate) == [true])
            // The meeting stays copied and its row has no label.
            #expect(try r.occurrence(try key(a)).isOn)
            #expect(try r.occurrence(try key(a)).label == nil)
        }
    }

    @Test func moveWithFoldedDuplicatesKeepsMovedLabel() throws {
        let a = orig("A", "a")
        let earlier = orig("A", "a", start: t0 - 7200)
        let staleCopies = [copy("B", of: earlier, local: "c-keep", ext: "e1"),
                           copy("B", of: earlier, local: "c-drop", ext: "e2")]
        let live = result([a] + staleCopies, mode: .live)
        #expect(live.changes.map(\.kind) == [.move])
        #expect(live.changes.map(\.duplicatesRemoved) == [1])

        // After the run: one copy, at the meeting's time.
        let r = meetingsCatalog(result: result([a, copy("B", of: a, local: "c-keep", ext: "e1")], mode: .live),
                                selected: [A, B], excluded: [], lastLiveChanges: live.changes)
        #expect(try r.occurrence(try key(a)).label == .moved)
        #expect(r.removals.map(\.count) == [1])
        #expect(r.removals.map(\.isDuplicate) == [true])
        #expect(r.removals.map(\.start) == [a.start])
    }

    /// A retitle gets no label either: in Dry run and Live, a result whose changes are only retitles gives the
    /// catalog of the same result without changes. A retitle that also removes a duplicate lists that removal,
    /// still without a label.
    @Test func retitleChangesNoLabel() throws {
        var a = orig("A", "a")
        a.title = "Weekly sync"
        // Every route shows `Busy only`, so a copy that reads another title is retitled to `Busy`.
        var renamed = copy("B", of: a, local: "c-a", ext: "e1")
        renamed.title = "Old name"
        for mode in [SyncMode.dryRun, .live] {
            let run = result([a, renamed], mode: mode)
            #expect(run.changes.map(\.kind) == [.retitle])
            var plain = run
            plain.changes = []
            let retitled = meetingsCatalog(result: run, selected: [A, B], excluded: [],
                                           lastLiveChanges: mode == .live ? run.changes : [])
            #expect(retitled == meetingsCatalog(result: plain, selected: [A, B], excluded: [], lastLiveChanges: []))
            #expect(retitled.removals.isEmpty)
            #expect(try retitled.occurrence(try key(a)).label == nil)
            #expect(try retitled.occurrence(try key(a)).isOn)
        }

        var duplicate = copy("B", of: a, local: "c-dup", ext: "e9")
        duplicate.title = "Other name"
        let run = result([a, renamed, duplicate], mode: .live)
        #expect(run.changes.map(\.kind) == [.retitle])
        let r = meetingsCatalog(result: run, selected: [A, B], excluded: [], lastLiveChanges: run.changes)
        #expect(r.removals.map(\.count) == [1])
        #expect(r.removals.map(\.isDuplicate) == [true])
        #expect(try r.occurrence(try key(a)).label == nil)
    }

    /// Nothing deleted is invisible: the listed removals plus the rows labelled "removed" add up to the
    /// run's deletes, in Dry run (no labels) and after a Live run.
    @Test func removalsAndRemovedLabelsCoverEveryDelete() async throws {
        let excludedOne = engineEvent("cal-a", "excluded", hours: 1)
        let declined = engineEvent("cal-a", "declined", hours: 2, response: .declined)
        let gone = engineEvent("cal-a", "gone", hours: 3)
        let kept = engineEvent("cal-a", "kept", hours: 4)
        let moved = engineEvent("cal-a", "moved", hours: 5)
        let added = engineEvent("cal-a", "added", hours: 6)
        func copies(of o: EventSnapshot, _ locals: [String], hours: Double) -> [EventSnapshot] {
            locals.map { engineEvent("cal-b", $0, hours: hours, marker: Marker.make(for: o)) }
        }
        let events = [excludedOne, declined, kept, moved, added]
            + copies(of: excludedOne, ["c-x"], hours: 1) + copies(of: declined, ["c-d"], hours: 2)
            + copies(of: gone, ["c-g1", "c-g2"], hours: 3) + copies(of: kept, ["c-k1", "c-k2", "c-k3"], hours: 4)
            + copies(of: moved, ["c-m1", "c-m2"], hours: 4.5)
        let excluded: Set<String> = [try key(excludedOne)]

        let window = DateInterval(start: Calendar.current.startOfDay(for: engineNow), duration: 30 * day)
        let dry = result(events, [engineA, engineB], excluded: excluded, in: window)
        #expect(deletes(dry.planned) == 7)
        let dryCatalog = meetingsCatalog(result: dry, selected: [engineA, engineB], excluded: excluded,
                                         lastLiveChanges: [])
        #expect(shownDeletes(dryCatalog) == 7)
        #expect(dryCatalog.allOccurrences.allSatisfy { $0.label == nil })

        let runs = await twoLiveRuns(events, excluded: excluded)
        #expect(runs.first.report?.deleted == 7)
        #expect(deletes(runs.first.planned) == 7)
        let liveCatalog = meetingsCatalog(result: runs.second, selected: [engineA, engineB], excluded: excluded,
                                          lastLiveChanges: runs.first.changes)
        #expect(shownDeletes(liveCatalog) == 7)
        #expect(liveCatalog.allOccurrences.filter { $0.label == .removed }.map(\.localID) == ["excluded"])
        #expect(liveCatalog.removals.map(\.count) == [1, 1, 1, 2, 1])
        #expect(liveCatalog.removals.map(\.isDuplicate) == [false, false, true, true, true])
    }

    // MARK: - Honest ticks and labels (review and critic regressions)

    /// An excluded original that the next run would not copy anyway (declined, free, unanswered, all-day
    /// not busy, same slot) is listed in Not copied with that reason, never as a row that ticking would
    /// show as copied.
    @Test func excludedButNotCopiableIsNotCopied() throws {
        let declined = orig("A", "declined", response: .declined)
        let free = orig("A", "free", start: t0 + 3600, availability: .free)
        let unanswered = orig("A", "pending", start: t0 + 2 * 3600, response: .pending)
        let allDay = orig("A", "allday", start: t0 + 3 * 3600, allDay: true, availability: .free)
        let sameSlot = orig("A", "slot", start: t0 + 5 * 3600)
        let real = orig("B", "real", start: t0 + 5 * 3600)
        let kept = orig("A", "kept", start: t0 + 6 * 3600)
        let events = [declined, free, unanswered, allDay, sameSlot, real, kept]
        let excluded = Set(try [declined, free, unanswered, allDay, sameSlot, kept].map(key))
        let last = result(events, excluded: excluded, mode: .live)
        // As excluded, and after the user ticked everything again.
        for keys in [excluded, []] {
            let c = meetingsCatalog(result: last, selected: [A, B], excluded: keys, lastLiveChanges: [])
            #expect(try c.section(A).rows.map(\.id) == [try key(kept)])
            #expect(try c.section(B).rows.isEmpty)
            #expect(c.notCopied.map(\.localID) == [declined, free, unanswered, allDay, sameSlot, real].map(\.localID))
            #expect(c.notCopied.map(\.reason) == [.declined, .free, .pendingInvitation, .allDayNotBusy,
                                                   .sameSlot(in: B), .sameSlot(in: A)])
            expectAgreesWithNextRun(c, events, [A, B], excluded: keys)
        }
    }

    /// An excluded series with a declined day: including the series again turns on only the days the next
    /// run copies; the declined day waits in Not copied.
    @Test func reincludedSeriesWithDeclinedDayIsHonest() throws {
        var days = series("A", "std", count: 3)
        days[1].myResponse = .declined
        let id = try seriesKey(days[0])
        let last = result(days, excluded: [id], mode: .live)
        let before = meetingsCatalog(result: last, selected: [A, B], excluded: [id], lastLiveChanges: [])
        #expect(try before.row(id).occurrences.map(\.start) == [days[0].start, days[2].start])
        #expect(try before.row(id).tick == .off)
        #expect(before.notCopied.map(\.start) == [days[1].start])
        #expect(before.notCopied.map(\.reason) == [.declined])

        let keys = toggling(try before.row(id), in: [id])
        #expect(keys.isEmpty)
        let after = meetingsCatalog(result: last, selected: [A, B], excluded: keys, lastLiveChanges: [])
        #expect(try after.row(id).tick == .on)
        #expect(after.allOccurrences.map(\.label) == [.pendingAddition, .pendingAddition])
        expectAgreesWithNextRun(after, days, [A, B], excluded: keys)
    }

    /// Three calendars, the same meeting in A and B at the same time, excluded: A's original is the row,
    /// B's is copied from A; ticking A's row copies exactly one meeting.
    @Test func excludedSameMeetingInThreeCalendarsIsHonest() throws {
        let inA = orig("A", "x", local: "la")
        let inB = orig("B", "x", local: "lb")
        let k = try key(inA)
        let last = result([inA, inB], [A, B, C], excluded: [k], mode: .live)
        let c = meetingsCatalog(result: last, selected: [A, B, C], excluded: [k], lastLiveChanges: [])
        #expect(try c.section(A).rows.map(\.id) == [k])
        #expect(try c.section(B).rows.isEmpty)
        #expect(c.notCopied.map(\.localID) == ["lb"])
        #expect(c.notCopied.map(\.reason) == [.copiedFrom(A)])

        let ticked = toggling(try c.occurrence(k), to: true, in: [k])
        let after = meetingsCatalog(result: last, selected: [A, B, C], excluded: ticked, lastLiveChanges: [])
        #expect(after.copiedCount == 1)
        expectAgreesWithNextRun(after, [inA, inB], [A, B, C], excluded: ticked)
    }

    /// The same meeting excluded in A and declined in B: only A's original is a row, and only it says
    /// removed after its copy went.
    @Test func removedLabelOnlyOnTheRemovedCopysOriginal() throws {
        let inA = orig("A", "x", local: "la")
        let inB = orig("B", "x", local: "lb", response: .declined)
        let excluded: Set<String> = [try key(inA)]
        let live = result([inA, inB, copy("B", of: inA, local: "c-a")], excluded: excluded, mode: .live)
        let followUp = result([inA, inB], excluded: excluded, mode: .live)
        #expect(followUp.changes.isEmpty)
        let r = meetingsCatalog(result: followUp, selected: [A, B], excluded: excluded, lastLiveChanges: live.changes)
        #expect(r.allOccurrences.filter { $0.label == .removed }.map(\.localID) == ["la"])
        #expect(r.notCopied.map(\.localID) == ["lb"])
        #expect(r.notCopied.map(\.reason) == [.declined])
        #expect(shownDeletes(r) == deletes(live.planned))
    }

    /// The same meeting in A and B at different times, B's declined: the copy of B's in A goes while A's
    /// copy in B stays. A's row is still copied and has no "removed" label; the removal is listed.
    @Test func removalFromAnotherCalendarLeavesMirroredRowUnlabelled() throws {
        let inA = orig("A", "x", local: "la", start: t0 + 7200)
        let inB = orig("B", "x", local: "lb", response: .declined)
        let live = result([inA, inB, copy("B", of: inA, local: "c-a"), copy("A", of: inB, local: "c-b")],
                          mode: .live)
        #expect(live.changes.map(\.kind) == [.remove])
        #expect(live.changes.map(\.source) == [B])
        let followUp = result([inA, inB, copy("B", of: inA, local: "c-a")], mode: .live)
        let r = meetingsCatalog(result: followUp, selected: [A, B], excluded: [], lastLiveChanges: live.changes)
        let rowA = try r.occurrence(try key(inA), in: A)
        #expect(rowA.isOn)
        #expect(rowA.label == nil)
        #expect(r.removals.map(\.target) == [A])
        #expect(r.removals.map(\.count) == [1])
        #expect(shownDeletes(r) == deletes(live.planned))
    }

    /// Two calendars, the same meeting declined in A and accepted in B at another time: the copy of A's in
    /// B goes, B's row stays copied without a label, and the removal is listed.
    @Test func declinedInOneOfTwoCalendarsListsItsCopysRemoval() throws {
        let inA = orig("A", "x", local: "la", response: .declined)
        let inB = orig("B", "x", local: "lb", start: t0 + 3600)
        let live = result([inA, inB, copy("B", of: inA, local: "c-b"), copy("A", of: inB, local: "c-a")],
                          mode: .live)
        let r = meetingsCatalog(result: live, selected: [A, B], excluded: [], lastLiveChanges: live.changes)
        let rowB = try r.occurrence(try key(inB), in: B)
        #expect(rowB.isOn)
        #expect(rowB.label == nil)
        #expect(r.removals.map(\.target) == [B])
        #expect(shownDeletes(r) == deletes(live.planned))
    }

    /// Two calendars: the only original of a copy in B is B's own (A's is gone). A copy is never of its
    /// own calendar's original, so that removal has no known original and is listed; the copy of B's in
    /// A goes too and B's row says removed.
    @Test func copyWhoseOnlyOriginalIsInItsOwnCalendarIsListed() throws {
        let goneInA = orig("A", "x", local: "la")
        let inB = orig("B", "x", local: "lb", start: t0 + 3600)
        let k = try key(inB)
        let live = result([inB, copy("B", of: goneInA, local: "c-b"), copy("A", of: inB, local: "c-a")],
                          excluded: [k], mode: .live)
        #expect(deletes(live.planned) == 2)
        #expect(live.changes.first { $0.target == B }?.source == nil)
        let r = meetingsCatalog(result: live, selected: [A, B], excluded: [k], lastLiveChanges: live.changes)
        #expect(r.allOccurrences.filter { $0.label == .removed }.map(\.localID) == ["lb"])
        #expect(r.removals.map(\.target) == [B])
        #expect(shownDeletes(r) == 2)
    }

    /// Three calendars: a real event takes the meeting's slot in B, so its copy there goes while the copy
    /// in C stays. The meeting is still copied: no "removed" label, the removal is listed.
    @Test func copyGoneFromOneOfTwoTargetsIsListed() throws {
        let x = orig("A", "x")
        let real = orig("B", "y")
        let live = result([x, copy("B", of: x, local: "c-b"), copy("C", of: x, local: "c-c"), real], [A, B, C],
                          mode: .live)
        let r = meetingsCatalog(result: live, selected: [A, B, C], excluded: [], lastLiveChanges: live.changes)
        let row = try r.occurrence(try key(x))
        #expect(row.isOn)
        #expect(row.label == nil)
        #expect(r.removals.filter { !$0.isDuplicate }.map(\.target) == [B])
    }

    /// Three calendars: the meeting copied from A arrives in B too, so the copy in B goes; A's row stays
    /// copied (into C) without a label, B's original is copied from A.
    @Test func sameMeetingArrivingInSecondCalendarListsTheRemovedCopy() throws {
        let inA = orig("A", "x", local: "la")
        let inB = orig("B", "x", local: "lb")
        let live = result([inA, copy("B", of: inA, local: "c-b"), copy("C", of: inA, local: "c-c"), inB],
                          [A, B, C], mode: .live)
        let r = meetingsCatalog(result: live, selected: [A, B, C], excluded: [], lastLiveChanges: live.changes)
        let row = try r.occurrence(try key(inA))
        #expect(row.isOn)
        #expect(row.label == nil)
        #expect(r.removals.map(\.target) == [B])
        #expect(r.notCopied.map(\.reason) == [.copiedFrom(A)])
    }

    /// The same meeting from A and B (different times, each copied into the other): only the row whose own
    /// copy moved says so.
    @Test func pastLabelsBelongToTheirSourceCalendar() throws {
        let inA = orig("A", "x", local: "la", start: t0 + 7200)
        let inB = orig("B", "x", local: "lb")
        let staleCopyOfA = copy("B", of: inA, local: "c-a", start: t0 + 3 * 3600)
        let events = [inA, inB, staleCopyOfA, copy("A", of: inB, local: "c-b")]
        let live = result(events, mode: .live)
        #expect(live.changes.map(\.kind) == [.move])
        let r = meetingsCatalog(result: live, selected: [A, B], excluded: [], lastLiveChanges: live.changes)
        let k = try key(inA)
        #expect(try r.occurrence(k, in: A).label == .moved)
        #expect(try r.occurrence(k, in: B).label == nil)
    }

    /// Random calendars, copies, declines, real events and exclusions, and on about half the runs random pairs set to
    /// Nothing or Title; after a Live run and on every click.
    @Test func catalogAgreesWithTheRunsOnRandomCalendars() throws {
        var rng = Rng(state: 42)
        // A stream of its own, so the calendars and events drawn are the same with or without pairs.
        var pairRng = Rng(state: 4242)
        var violations: [String: String] = [:]
        func check(_ ok: Bool, _ rule: String, _ example: @autoclosure () -> String) {
            if !ok && violations[rule] == nil { violations[rule] = example() }
        }
        func mirroredIDs(_ r: SyncResult) -> Set<String> {
            Set(r.mirroredItems.map { "\($0.source.id)|\($0.occurrenceKey ?? "")" })
        }
        for iteration in 0..<150 {
            let cals = Array([A, B, C].prefix(2 + rng.next(2)))
            var originals: [EventSnapshot] = []
            for sid in 0..<2 {
                let ext = "series\(sid)"
                let count = 1 + rng.next(4)
                for cal in cals where rng.next(3) == 0 || cal == cals[sid % cals.count] {
                    for d in 0..<count {
                        var e = orig(cal.id, ext, local: "\(cal.id)-\(ext)",
                                     start: t0 + Double(d) * day + Double(sid) * 3600, recurring: true)
                        if rng.next(3) == 0 { e.start += 1800; e.end += 1800 }
                        if rng.next(5) == 0 { e.myResponse = .declined }
                        originals.append(e)
                    }
                }
            }
            for sid in 0..<3 {
                let ext = "single\(sid)"
                for cal in cals where rng.next(3) == 0 || cal == cals[(sid + 1) % cals.count] {
                    var e = orig(cal.id, ext, start: t0 + Double(rng.next(3)) * 3600 + 7 * 3600)
                    if rng.next(5) == 0 { e.myResponse = .declined }
                    originals.append(e)
                }
            }
            var copies: [EventSnapshot] = []
            for (i, o) in originals.enumerated() {
                for target in cals where target != o.calendar && rng.next(2) == 0 {
                    copies.append(copy(target.id, of: o, local: "c\(i)-\(target.id)-\(rng.next(1000))",
                                       start: rng.next(6) == 0 ? o.start + 900 : o.start))
                }
            }
            var events = originals.filter { _ in rng.next(8) != 0 } + copies
            if rng.next(4) == 0 { events.append(orig(cals[rng.next(cals.count)].id, "real")) }
            let keys = Set(originals.flatMap {
                [ExclusionKey.occurrence(for: $0), ExclusionKey.series(for: $0), ExclusionKey.include(for: $0)]
                    .compactMap { $0 }
            }).sorted()
            let excluded = Set(keys.filter { _ in rng.next(6) == 0 })
            var formats: [CopyRoute: CopyTitleFormat] = [:]
            if pairRng.next(2) == 0 {
                for source in cals {
                    for target in cals where target != source {
                        switch pairRng.next(3) {
                        case 0: formats[route(source, target)] = .nothing
                        case 1: formats[route(source, target)] = .title
                        default: break
                        }
                    }
                }
            }
            let s = SyncSettings(selected: cals, excluded: excluded, copyTitleFormats: formats)
            let nothing = formats.filter { $0.value == .nothing }.keys.map { "\($0.source.id)>\($0.target.id)" }
            let at = "iteration \(iteration), \(cals.count) calendars, Nothing on \(nothing.sorted())"

            // Pairs on Nothing: no copy on them, nothing listed for a calendar that copies nowhere, `sameSlot` names
            // a calendar the source copies into, and a section for exactly the calendars that copy somewhere.
            let dry = result(events, cals, formats: formats, excluded: excluded)
            for item in dry.mirroredItems {
                check(s.copies(from: item.source, to: item.target), "mirrored on a Nothing pair", at)
            }
            for skipped in dry.notBusy {
                check(cals.contains { s.copies(from: skipped.calendar, to: $0) }, "listed but copies nowhere", at)
                for case let .sameSlot(target)? in [skipped.reason, skipped.underlyingReason] {
                    check(s.copies(from: skipped.calendar, to: target), "sameSlot names no target", at)
                }
            }

            // Every delete is listed or behind a "removed" label (exactly, with two calendars).
            let dryCatalog = meetingsCatalog(result: dry, selected: cals, excluded: excluded, lastLiveChanges: [],
                                             titleFormats: formats)
            let copying = cals.filter { source in cals.count < 2 || cals.contains { s.copies(from: source, to: $0) } }
            check(dryCatalog.sections.map(\.source) == copying, "a section for each calendar that copies", at)
            check(shownDeletes(dryCatalog) == deletes(dry.planned), "dry run shows every delete", at)
            check(Set(dryCatalog.removals.map(\.id)).count == dryCatalog.removals.count, "removal ids unique", at)
            let live = result(events, cals, formats: formats, excluded: excluded, mode: .live)
            let liveCatalog = meetingsCatalog(result: live, selected: cals, excluded: excluded,
                                              lastLiveChanges: live.changes, titleFormats: formats)
            if cals.count == 2 {
                check(shownDeletes(liveCatalog) == deletes(live.planned), "live shows every delete", at)
            } else {
                check(shownDeletes(liveCatalog) <= deletes(live.planned), "no delete shown twice", at)
            }

            // After the run: the next one plans nothing, ticks are what is mirrored, labels never contradict them.
            let after = apply(live.planned, to: events)
            let followUp = result(after, cals, formats: formats, excluded: excluded, mode: .live)
            check(followUp.planned.isEmpty, "a second run plans nothing", at)
            let steady = meetingsCatalog(result: followUp, selected: cals, excluded: excluded,
                                         lastLiveChanges: live.changes, titleFormats: formats)
            let mirrored = mirroredIDs(followUp)
            for section in steady.sections {
                check(Set(section.rows.map(\.id)).count == section.rows.count, "row ids unique in a section", at)
                let occurrences = section.rows.flatMap(\.occurrences)
                check(Set(occurrences.map(\.id)).count == occurrences.count, "occurrence ids unique", at)
                for o in occurrences {
                    check(o.isOn == mirrored.contains("\(section.id)|\(o.id)"), "steady tick is mirrored", at)
                    check(!(o.label == .removed && o.isOn), "removed label on a ticked row", at)
                    check(!((o.label == .added || o.label == .moved) && !o.isOn), "added or moved on unticked", at)
                }
            }

            // Every click changes only the clicked meeting, and the result is what the next run does.
            let originalsAfter = after.filter { $0.marker == nil }
            func excludedOriginals(_ k: Set<String>) -> [Bool] {
                let s = SyncSettings(selected: cals, excluded: k)
                return originalsAfter.map(s.excludes)
            }
            let base = excludedOriginals(excluded)
            for section in steady.sections {
                for row in section.rows {
                    var clicks = [(toggling(row, in: excluded), row.isSeries ? row.id : row.occurrences[0].id, true)]
                    for o in row.occurrences { clicks.append((toggling(o, to: !o.isOn, in: excluded), o.id, false)) }
                    for (newKeys, allowed, isRowClick) in clicks {
                        let now = excludedOriginals(newKeys)
                        for (i, e) in originalsAfter.enumerated() where base[i] != now[i] {
                            check(ExclusionKey.occurrence(for: e) == allowed || ExclusionKey.series(for: e) == allowed,
                                  "a click changes only its meeting", at)
                        }
                        let clicked = meetingsCatalog(result: followUp, selected: cals, excluded: newKeys,
                                                      lastLiveChanges: live.changes, titleFormats: formats)
                        if isRowClick, let clickedRow = clicked.sections.first(where: { $0.id == section.id })?
                            .rows.first(where: { $0.id == row.id }) {
                            let want: MeetingsCatalog.Tick = row.tick == .on ? .off : .on
                            check(clickedRow.tick == want, "a row click reaches on or off", at)
                        }
                        let next = mirroredIDs(result(after, cals, formats: formats, excluded: newKeys, mode: .live))
                        for s2 in clicked.sections {
                            for o in s2.rows.flatMap(\.occurrences) {
                                check(o.isOn == next.contains("\(s2.id)|\(o.id)"), "tick is what the next run does", at)
                            }
                        }
                        check(clicked.copiedCount == next.count, "copied count is the next run's", at)
                    }
                }
            }
        }
        #expect(violations.isEmpty, "\(violations.sorted { $0.key < $1.key })")
    }

    // MARK: - Toggling

    @Test func togglingOccurrenceOffAndOn() throws {
        let single = orig("A", "single")
        let days = series("A", "s", count: 2, from: t0 + 3600)
        let other: Set<String> = ["o:other"]
        let r = catalog([single] + days, excluded: other)

        let off = toggling(try r.occurrence(try key(single)), to: false, in: other)
        #expect(off == other.union([try key(single)]))
        let unticked = catalog([single] + days, excluded: off)
        #expect(try unticked.occurrence(try key(single)).isOn == false)
        #expect(toggling(try unticked.occurrence(try key(single)), to: true, in: off) == other)

        // A day of a series that is not excluded uses its own occurrence key, never the include key.
        let dayOff = toggling(try r.occurrence(try key(days[1])), to: false, in: other)
        #expect(dayOff == other.union([try key(days[1])]))
        #expect(try catalog([single] + days, excluded: dayOff).row(try seriesKey(days[0])).tick == .mixed)

        // A single meeting's row acts on its one occurrence and never adds a series key.
        let row = try r.row(try key(single))
        #expect(!row.isSeries)
        #expect(toggling(row, in: other) == off)
        #expect(toggling(try unticked.row(try key(single)), in: off) == other)
    }

    @Test func togglingInsideExcludedSeriesUsesInclude() throws {
        let days = series("A", "s", count: 3)
        let id = try seriesKey(days[0])
        let excluded: Set<String> = [id]
        let r = catalog(days, excluded: excluded)
        #expect(r.allOccurrences.map(\.isOn) == [false, false, false])

        let on = toggling(try r.occurrence(try key(days[1])), to: true, in: excluded)
        #expect(on == [id, try includeKey(days[1])])
        let ticked = catalog(days, excluded: on)
        #expect(ticked.allOccurrences.map(\.isOn) == [false, true, false])
        #expect(try ticked.row(id).tick == .mixed)

        #expect(toggling(try ticked.occurrence(try key(days[1])), to: false, in: on) == excluded)

        // A day also excluded by its own key: ticking drops that key and adds the include key.
        let both: Set<String> = [id, try key(days[0])]
        let r2 = catalog(days, excluded: both)
        #expect(toggling(try r2.occurrence(try key(days[0])), to: true, in: both) == [id, try includeKey(days[0])])
    }

    @Test func togglingSeriesOnMixedOff() throws {
        let days = series("A", "s", count: 3)
        let id = try seriesKey(days[0])
        let other: Set<String> = ["o:other"]

        // Ticked: excludes the series and drops its days' own keys (a stale include key here).
        let stale = other.union([try includeKey(days[0])])
        let on = try catalog(days, excluded: stale).row(id)
        #expect(on.tick == .on)
        let offKeys = toggling(on, in: stale)
        #expect(offKeys == other.union([id]))
        #expect(try catalog(days, excluded: offKeys).row(id).tick == .off)

        // Mixed, by a day's own key or by an include inside the excluded series: includes everything.
        for mixedKeys in [other.union([try key(days[1])]), other.union([id, try includeKey(days[0])])] {
            let mixed = try catalog(days, excluded: mixedKeys).row(id)
            #expect(mixed.tick == .mixed)
            let onKeys = toggling(mixed, in: mixedKeys)
            #expect(onKeys == other)
            #expect(try catalog(days, excluded: onKeys).row(id).tick == .on)
        }

        // Unticked, with a day's own key left over: includes everything.
        let offWithLeftover = other.union([id, try key(days[2])])
        let off = try catalog(days, excluded: offWithLeftover).row(id)
        #expect(off.tick == .off)
        #expect(toggling(off, in: offWithLeftover) == other)
    }

    /// Clicking a series row also sweeps the keys of its days in Not copied, so a day declined while it
    /// was kept inside the excluded series does not stay kept once it is accepted again.
    @Test func seriesToggleSweepsKeysOfDaysInNotCopied() throws {
        var days = series("A", "std", count: 4)
        let id = try seriesKey(days[0])
        days[1].myResponse = .declined
        var keys: Set<String> = [id, try includeKey(days[1])]
        let row = try catalog(days, excluded: keys).row(id)
        #expect(Set(row.relatedKeys) == Set(try days.map(key) + days.map(includeKey)))

        keys = toggling(row, in: keys)
        #expect(keys.isEmpty)
        keys = toggling(try catalog(days, excluded: keys).row(id), in: keys)
        #expect(keys == [id])

        days[1].myResponse = .accepted
        let c = catalog(days, excluded: keys)
        #expect(try c.row(id).tick == .off)
        #expect(c.allOccurrences.allSatisfy { !$0.isOn })
    }

    /// The series tick reflects only the occurrences in the window, and unticking the series also covers
    /// occurrences that enter the window later.
    @Test func seriesExclusionCoversLaterOccurrences() throws {
        let days = series("A", "s", count: 20)
        let id = try seriesKey(days[0])
        let week = DateInterval(start: t0 - 3600, duration: 7 * day)
        let month = DateInterval(start: t0 - 3600, duration: 30 * day)

        let first = meetingsCatalog(result: result(days, in: week), selected: [A, B], excluded: [],
                                    lastLiveChanges: [])
        let row = try first.row(id)
        #expect(row.occurrences.count == 7)
        #expect(row.tick == .on)
        let excluded = toggling(row, in: [])
        #expect(excluded == [id])

        let later = meetingsCatalog(result: result(days, excluded: excluded, in: month), selected: [A, B],
                                    excluded: excluded, lastLiveChanges: [])
        #expect(try later.section(A).rows.map(\.id) == [id])
        #expect(try later.row(id).occurrences.count == 20)
        #expect(try later.row(id).tick == .off)
        #expect(later.allOccurrences.allSatisfy { !$0.isOn })
        #expect(later.copiedCount == 0)
        #expect(later.notCopied.isEmpty)
    }

    // MARK: - Hidden titles

    /// Hidden titles follow the exclusion rule on their own set: a hidden occurrence key hides one meeting's
    /// title, a hidden series key every day's but that of a day whose include key is hidden too, and a series'
    /// title tick follows its days. They leave the mirror ticks and counts alone, and agree with the copies the
    /// run writes on a route that shows titles.
    @Test func titleShownFollowsHiddenKeys() throws {
        var single = orig("A", "single")
        single.title = "One to one"
        var days = series("A", "s", count: 3, from: t0 + 3600)
        for i in days.indices { days[i].title = "Stand up" }
        let id = try seriesKey(days[0])
        let events = [single] + days
        let run = result(events)
        func titles(_ hidden: Set<String>) -> MeetingsCatalog {
            meetingsCatalog(result: run, selected: [A, B], excluded: [], lastLiveChanges: [], hiddenTitles: hidden)
        }

        let plain = titles([])
        #expect(plain == meetingsCatalog(result: run, selected: [A, B], excluded: [], lastLiveChanges: []))
        #expect(plain.allOccurrences.allSatisfy { $0.titleShown })
        #expect(try plain.row(id).titleTick == .on)
        #expect(try plain.row(try key(single)).titleTick == .on)

        let oneHidden = titles([try key(single)])
        #expect(try oneHidden.occurrence(try key(single)).titleShown == false)
        #expect(try oneHidden.row(try key(single)).titleTick == .off)
        #expect(try oneHidden.row(id).occurrences.map(\.titleShown) == [true, true, true])
        #expect(try oneHidden.row(id).titleTick == .on)

        let seriesHidden = titles([id])
        #expect(try seriesHidden.row(id).occurrences.map(\.titleShown) == [false, false, false])
        #expect(try seriesHidden.row(id).titleTick == .off)
        #expect(try seriesHidden.occurrence(try key(single)).titleShown)

        let oneDayShown: Set<String> = [id, try includeKey(days[1])]
        let mixed = titles(oneDayShown)
        #expect(try mixed.row(id).occurrences.map(\.titleShown) == [false, true, false])
        #expect(try mixed.row(id).titleTick == .mixed)

        // The mirror ticks, counts and labels stay those of the catalog without hidden titles.
        for c in [oneHidden, seriesHidden, mixed] {
            #expect(c.allOccurrences.map(\.isOn) == plain.allOccurrences.map(\.isOn))
            #expect(c.allOccurrences.map(\.label) == plain.allOccurrences.map(\.label))
            #expect(c.sections.flatMap(\.rows).map(\.tick) == plain.sections.flatMap(\.rows).map(\.tick))
            #expect(c.copiedCount == plain.copiedCount)
        }

        // The run agrees: on a route that shows titles, a copy is titled `Busy` exactly when its title is hidden.
        for hidden in [[], [try key(single)], [id], oneDayShown] as [Set<String>] {
            let settings = SyncSettings(selected: [A, B], copyTitleFormats: [route(A, B): .title],
                                        hiddenTitleKeys: hidden)
            var written: [String: String] = [:]
            for case let .create(spec) in reconcile(events: events, settings: settings, window: window) {
                written[spec.marker] = spec.title
            }
            let occurrences = titles(hidden).allOccurrences
            #expect(occurrences.count == 4)
            for o in occurrences {
                let title = try #require(written[String(o.id.dropFirst("o:".count))])
                #expect((title != CopySpec.busyTitle) == o.titleShown)
            }
        }
    }

    /// A section offers title boxes exactly when a route from its source to one of its targets, the other selected
    /// calendars, shows titles; routes into the source do not count, nor do routes to a calendar that is not
    /// selected.
    @Test func sectionShowsTitlesOnlyWithATitledTarget() throws {
        let events = [orig("A", "a"), orig("B", "b", start: t0 + 3600), orig("C", "c", start: t0 + 7200)]
        let run = result(events, [A, B, C])
        func showsTitles(_ formats: [CopyRoute: CopyTitleFormat]) -> [Bool] {
            meetingsCatalog(result: run, selected: [A, B, C], excluded: [], lastLiveChanges: [],
                            titleFormats: formats).sections.map(\.showsTitles)
        }

        #expect(meetingsCatalog(result: run, selected: [A, B, C], excluded: [], lastLiveChanges: [])
            .sections.map(\.showsTitles) == [false, false, false])
        #expect(showsTitles([:]) == [false, false, false])
        #expect(showsTitles([route(B, A): .busyOnly, route(C, A): .busyOnly, route(A, B): .busyOnly,
                             route(C, B): .busyOnly, route(A, C): .busyOnly, route(B, C): .busyOnly])
            == [false, false, false])
        // Only the routes into C show titles: A's and B's meetings are copied into C, C's only into A and B.
        #expect(showsTitles([route(A, C): .title, route(B, C): .title]) == [true, true, false])
        #expect(showsTitles([route(B, A): .sourceAndTitle, route(C, A): .sourceAndTitle]) == [false, true, true])
        #expect(showsTitles([route(B, A): .title, route(C, A): .title, route(A, B): .sourceAndTitle,
                             route(C, B): .sourceAndTitle, route(A, C): .busyOnly, route(B, C): .busyOnly])
            == [true, true, true])

        let two = meetingsCatalog(result: result(events), selected: [A, B], excluded: [], lastLiveChanges: [],
                                  titleFormats: [route(A, C): .title, route(B, C): .title])
        #expect(two.sections.map(\.showsTitles) == [false, false])
    }

    /// Only A→C shows titles: section A offers title boxes; B, whose meetings go to C as `Busy`, and C do not.
    @Test func sectionShowsTitlesPerRoute() throws {
        let events = [orig("A", "a"), orig("B", "b", start: t0 + 3600), orig("C", "c", start: t0 + 7200)]
        let catalog = meetingsCatalog(result: result(events, [A, B, C]), selected: [A, B, C], excluded: [],
                                      lastLiveChanges: [], titleFormats: [route(A, C): .title])
        #expect(catalog.sections.map(\.source) == [A, B, C])
        #expect(catalog.sections.map(\.showsTitles) == [true, false, false])
    }

    // MARK: - Pairs set to Nothing

    /// A copies into neither B nor C: no section for A, and none of its meetings among the rows or under Not
    /// copied, the declined one and the one the user excluded included. B's and C's sections name as targets the
    /// calendars they copy into, so A only where their pair into it is not Nothing (B→A is). A lone selected calendar
    /// keeps its section.
    @Test func sourceWithoutTargetsHasNoSection() throws {
        let a = orig("A", "a")
        let excludedA = orig("A", "ex", start: t0 + 3600)
        let declinedA = orig("A", "d", start: t0 + 7200, response: .declined)
        let b = orig("B", "b", start: t0 + 10_800)
        let declinedB = orig("B", "db", start: t0 + 14_400, response: .declined)
        let events = [a, excludedA, declinedA, b, declinedB]
        let excluded: Set<String> = [try key(excludedA)]
        let silentA: [CopyRoute: CopyTitleFormat] = [route(A, B): .nothing, route(A, C): .nothing,
                                                     route(B, A): .nothing]
        let run = result(events, [A, B, C], formats: silentA, excluded: excluded)
        #expect(!run.mirroredItems.contains { $0.source == A })
        #expect(!run.notBusy.contains { $0.calendar == A })

        let c = meetingsCatalog(result: run, selected: [A, B, C], excluded: excluded, lastLiveChanges: [],
                                titleFormats: silentA)
        #expect(c.sections.map(\.id) == ["B", "C"])
        #expect(c.sections.map(\.targets) == [[C], [A, B]])
        #expect(c.allOccurrences.map(\.localID) == [b.localID])
        #expect(c.notCopied.map(\.localID) == [declinedB.localID])
        #expect(c.copiedCount == 1)

        // The same while the pairs are only staged: the last run copied A's meetings and listed its declined one.
        let applied = result(events, [A, B, C], excluded: excluded)
        let staged = meetingsCatalog(result: applied, selected: [A, B, C], excluded: excluded, lastLiveChanges: [],
                                     titleFormats: silentA)
        #expect(staged.sections.map(\.id) == ["B", "C"])
        #expect(!staged.allOccurrences.contains { $0.localID.hasPrefix("A-") })
        #expect(staged.notCopied.map(\.localID) == [declinedB.localID])
        #expect(staged.notCopiedCount == 1)

        // One pair left: A's section is back, with that one target.
        let oneLeft = meetingsCatalog(result: applied, selected: [A, B, C], excluded: excluded, lastLiveChanges: [],
                                      titleFormats: [route(A, B): .nothing])
        #expect(oneLeft.sections.map(\.targets) == [[C], [A, C], [A, B]])

        let lone = meetingsCatalog(result: result([a], [A]), selected: [A], excluded: [], lastLiveChanges: [],
                                   titleFormats: [route(A, B): .nothing])
        #expect(lone.sections.map(\.id) == ["A"])
        #expect(lone.sections.map(\.targets) == [[]])
    }

    /// The same meeting at the same time in A and B, and one only in A. A wins C's copy of the shared one, so it is a
    /// row of A and B lists it under Not copied, copied from A. With A→C on Nothing, C's copy is taken from B: the
    /// meeting moves to B's section, and A lists it under Not copied, as B, A's one target, holds it at that time.
    @Test func sharedMeetingMovesToTheOtherSection() throws {
        let shared = orig("A", "m"), sharedInB = orig("B", "m"), solo = orig("A", "solo", start: t0 + 7200)
        let events = [shared, sharedInB, solo]
        let before = meetingsCatalog(result: result(events, [A, B, C]), selected: [A, B, C], excluded: [],
                                     lastLiveChanges: [])
        #expect(before.sections.map(\.count) == [2, 0, 0])
        #expect(before.notCopied.map(\.localID) == [sharedInB.localID])
        #expect(before.notCopied.map(\.reason) == [.copiedFrom(A)])

        let formats: [CopyRoute: CopyTitleFormat] = [route(A, C): .nothing]
        let after = meetingsCatalog(result: result(events, [A, B, C], formats: formats), selected: [A, B, C],
                                    excluded: [], lastLiveChanges: [], titleFormats: formats)
        #expect(after.sections.map(\.count) == [1, 1, 0])
        #expect(after.sections.map(\.appliedCount) == [1, 1, 0])
        #expect(try after.section(A).rows.map(\.id) == [try key(solo)])
        #expect(try after.section(B).rows.map(\.id) == [try key(sharedInB)])
        #expect(after.notCopied.map(\.localID) == [shared.localID])
        #expect(after.notCopied.map(\.reason) == [.sameSlot(in: B)])
        #expect(after.copiedCount == 2)
    }

    /// Every pair on Nothing, with two calendars and with three: no copy is wanted, every copy in the window is
    /// planned as a remove (one beyond it stays), the run after that plans nothing, and the Meetings window has no
    /// section and nothing under Not copied, the removals only.
    @Test func everyPairOnNothingCopiesNothing() {
        let a = orig("A", "a"), b = orig("B", "b", start: t0 + 7200)
        let declined = orig("A", "d", start: t0 + 3600, response: .declined)
        let far = orig("A", "far", start: window.end + day)
        for cals in [[A, B], [A, B, C]] {
            var formats: [CopyRoute: CopyTitleFormat] = [:]
            for source in cals {
                for target in cals where target != source { formats[route(source, target)] = .nothing }
            }
            let inWindow = cals.flatMap { target in
                [a, b].filter { $0.calendar != target }
                    .map { copy(target.id, of: $0, local: "\(target.id)-\($0.localID)") }
            }
            let events = [a, b, declined, far, copy("B", of: far, local: "B-far")] + inWindow
            let run = result(events, cals, formats: formats)
            #expect(run.mirroredItems.isEmpty)
            #expect(run.notBusy.isEmpty)
            #expect(run.planned.count == inWindow.count)
            #expect(run.planned.allSatisfy { if case .delete = $0 { true } else { false } })
            #expect(!run.planned.contains(.delete(localID: "B-far", target: B)))
            #expect(run.changes.map(\.kind) == Array(repeating: .remove, count: inWindow.count))
            #expect(result(apply(run.planned, to: events), cals, formats: formats).planned.isEmpty)

            let shown = meetingsCatalog(result: run, selected: cals, excluded: [], lastLiveChanges: [],
                                        titleFormats: formats)
            #expect(shown.sections.isEmpty)
            #expect(shown.notCopied.isEmpty)
            #expect(shown.copiedCount == 0)
            #expect(shown.removals.count == inWindow.count)
        }
    }

    /// `Nothing` is not a title choice: a section whose only pair other than `Busy only` is Nothing shows no Title
    /// boxes; another pair of the same source that shows titles still does.
    @Test func nothingIsNotATitleChoice() throws {
        let events = [orig("A", "a"), orig("B", "b", start: t0 + 3600), orig("C", "c", start: t0 + 7200)]
        let run = result(events, [A, B, C])
        func showsTitles(_ formats: [CopyRoute: CopyTitleFormat]) -> [Bool] {
            meetingsCatalog(result: run, selected: [A, B, C], excluded: [], lastLiveChanges: [],
                            titleFormats: formats).sections.map(\.showsTitles)
        }
        #expect(showsTitles([route(A, B): .nothing]) == [false, false, false])
        #expect(showsTitles([route(A, B): .nothing, route(B, A): .nothing, route(C, A): .nothing])
            == [false, false, false])
        #expect(showsTitles([route(A, B): .nothing, route(A, C): .title]) == [true, false, false])
    }

    /// The title boxes change the hidden-title set by the same rules as the mirror boxes change the exclusions:
    /// a series row whose titles all show hides the series; a mixed or hidden one shows every title again and
    /// adds no key; a day inside a hidden series is shown through its include key; a single meeting flips its
    /// own key. The row's mirror tick plays no part.
    @Test func togglingTitleUsesTheSameRule() throws {
        let single = orig("A", "single")
        let days = series("A", "s", count: 3, from: t0 + 3600)
        let id = try seriesKey(days[0])
        let other: Set<String> = ["o:other"]
        let run = result([single] + days)
        func titles(_ hidden: Set<String>) -> MeetingsCatalog {
            meetingsCatalog(result: run, selected: [A, B], excluded: [], lastLiveChanges: [], hiddenTitles: hidden)
        }

        // Shown (`.on`): hides the series and drops its days' own keys (a stale include key here).
        let stale = other.union([try includeKey(days[0])])
        let on = try titles(stale).row(id)
        #expect(on.titleTick == .on)
        let hidden = toggling(on, tick: on.titleTick, in: stale)
        #expect(hidden == other.union([id]))
        #expect(try titles(hidden).row(id).titleTick == .off)

        // Mixed, by a day's own key or by an include inside the hidden series: shows every title, adds no key.
        for mixedKeys in [other.union([try key(days[1])]), other.union([id, try includeKey(days[0])])] {
            let mixed = try titles(mixedKeys).row(id)
            #expect(mixed.titleTick == .mixed)
            let shown = toggling(mixed, tick: mixed.titleTick, in: mixedKeys)
            #expect(shown == other)
            #expect(try titles(shown).row(id).titleTick == .on)
        }

        // Hidden, with a day's own key left over: shows every title.
        let leftover = hidden.union([try key(days[2])])
        let off = try titles(leftover).row(id)
        #expect(off.titleTick == .off)
        #expect(toggling(off, tick: off.titleTick, in: leftover) == other)

        // A day inside the hidden series: shown through its include key, hidden again by dropping it.
        let day = try titles(hidden).occurrence(try key(days[1]))
        #expect(!day.titleShown)
        let dayShown = toggling(day, to: true, in: hidden)
        #expect(dayShown == hidden.union([try includeKey(days[1])]))
        #expect(try titles(dayShown).row(id).occurrences.map(\.titleShown) == [false, true, false])
        #expect(toggling(try titles(dayShown).occurrence(try key(days[1])), to: false, in: dayShown) == hidden)

        // A single meeting's row flips its own key and never adds a series key.
        let singleRow = try titles(other).row(try key(single))
        let singleHidden = toggling(singleRow, tick: singleRow.titleTick, in: other)
        #expect(singleHidden == other.union([try key(single)]))
        let back = try titles(singleHidden).row(try key(single))
        #expect(back.titleTick == .off)
        #expect(toggling(back, tick: back.titleTick, in: singleHidden) == other)

        // An excluded series keeps its title tick: hiding its titles goes by that tick, not the mirror one.
        let excluded = try meetingsCatalog(result: result([single] + days, excluded: [id]), selected: [A, B],
                                           excluded: [id], lastLiveChanges: []).row(id)
        #expect(excluded.tick == .off)
        #expect(excluded.titleTick == .on)
        #expect(toggling(excluded, tick: excluded.titleTick, in: []) == [id])
        #expect(toggling(excluded, in: [id]) == toggling(excluded, tick: excluded.tick, in: [id]))
    }

    // MARK: - Series pattern

    @Test func seriesPatterns() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        func at(_ month: Int, _ dayOfMonth: Int, _ hour: Int = 0, _ minute: Int = 0) throws -> Date {
            try #require(cal.date(from: DateComponents(year: 2027, month: month, day: dayOfMonth, hour: hour,
                                                       minute: minute)))
        }
        func time(_ hour: Int, _ minute: Int) -> DateComponents { DateComponents(hour: hour, minute: minute) }

        // Two working weeks, Monday 22 March to Friday 2 April 2027, across the switch to summer time.
        let weekdays = try [22, 23, 24, 25, 26, 29, 30, 31].map { try at(3, $0, 10, 40) }
            + [1, 2].map { try at(4, $0, 10, 40) }
        #expect(seriesPattern(weekdays.reversed(), isAllDay: false, calendar: cal) == .weekdays(time: time(10, 40)))

        let thursdays = try [4, 11, 18, 25].map { try at(3, $0, 13) }
        #expect(seriesPattern(thursdays, isAllDay: false, calendar: cal) == .weekly(weekday: 5, time: time(13, 0)))
        #expect(seriesPattern([thursdays[0]], isAllDay: false, calendar: cal) == .weekly(weekday: 5, time: time(13, 0)))

        // Saturday 20 to Friday 26 March.
        let daily = try (20...26).map { try at(3, $0, 9) }
        #expect(seriesPattern(daily, isAllDay: false, calendar: cal) == .daily(time: time(9, 0)))

        let differentTimes = [try at(3, 22, 10), try at(3, 23, 11)]
        #expect(seriesPattern(differentTimes, isAllDay: false, calendar: cal) == .irregular(first: try at(3, 22, 10)))
        let mondayWednesdayFriday = try [22, 24, 26].map { try at(3, $0, 10) }
        #expect(seriesPattern(mondayWednesdayFriday, isAllDay: false, calendar: cal)
            == .irregular(first: try at(3, 22, 10)))

        let allDay = try [4, 11].map { try at(3, $0) }
        #expect(seriesPattern(allDay, isAllDay: true, calendar: cal) == .weekly(weekday: 5, time: DateComponents()))
        #expect(seriesPattern([], isAllDay: false, calendar: cal) == .irregular(first: .distantPast))

        // Components come from the calendar passed in: in UTC the summer-time switch moves the hour.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        #expect(seriesPattern(thursdays, isAllDay: false, calendar: utc) == .weekly(weekday: 5, time: time(12, 0)))
        #expect(seriesPattern(weekdays, isAllDay: false, calendar: utc) == .irregular(first: weekdays[0]))
    }

    // MARK: - Removal keys

    @Test func removalKeysFilled() throws {
        // The copy of an excluded series occurrence: a remove carrying the original's keys.
        let occurrence = series("A", "s", count: 1)[0]
        let removed = result([occurrence, copy("B", of: occurrence, local: "c1")],
                             excluded: [try seriesKey(occurrence)]).changes
        #expect(removed == [
            PlannedChange(kind: .remove, target: B, start: occurrence.start, end: occurrence.end, isAllDay: false,
                          source: A, sourceLocalID: occurrence.localID, occurrenceKey: try key(occurrence),
                          seriesKey: try seriesKey(occurrence), includeKey: try includeKey(occurrence)),
        ])

        // Duplicates of a copy that stays carry the kept copy's original's keys.
        let a = orig("A", "a", start: t0 + 3600)
        let duplicates = result([a, copy("B", of: a, local: "c-keep", ext: "e1"),
                                 copy("B", of: a, local: "c-drop", ext: "e2")]).changes
        #expect(duplicates == [
            PlannedChange(kind: .removeDuplicates, target: B, start: a.start, end: a.end, isAllDay: false,
                          source: A, sourceLocalID: a.localID, duplicatesRemoved: 1, occurrenceKey: try key(a),
                          includeKey: try includeKey(a)),
        ])

        // Without a visible original there is nothing to take keys from.
        let gone = orig("A", "gone")
        let orphan = result([copy("B", of: gone, local: "c-gone")]).changes
        #expect(orphan == [PlannedChange(kind: .remove, target: B, start: gone.start, end: gone.end, isAllDay: false)])
    }
}

/// A small deterministic generator for the random calendars.
private struct Rng {
    var state: UInt64
    mutating func next(_ n: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(n))
    }
}
