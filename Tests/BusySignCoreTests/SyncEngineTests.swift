import Foundation
import os
import Testing
@testable import BusySignCore

@Suite struct SyncEngineTests {
    let a = CalendarRef(id: "cal-a")
    let b = CalendarRef(id: "cal-b")
    let c = CalendarRef(id: "cal-c")
    let now: Date = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)).addingTimeInterval(10 * 3600)
    var settings: SyncSettings { SyncSettings(selected: [a, b]) }

    func ev(_ cal: String, _ id: String, ext: String? = nil, hours: Double = 2, marker: String? = nil) -> EventSnapshot {
        let start = now.addingTimeInterval(hours * 3600)
        return snap(calendar: cal, localID: id, externalID: marker == nil ? (ext ?? "ext-\(id)") : nil,
                    occurrenceDate: start, start: start, end: start.addingTimeInterval(3600), marker: marker)
    }
    func store(_ events: [EventSnapshot] = [], access: AccessState = .granted,
               writable: Bool = true, cals: [String] = ["cal-a", "cal-b"]) -> FakeCalendarStore {
        FakeCalendarStore(calendars: cals.map { FakeCalendarStore.calendar($0, writable: writable) },
                          events: events, access: access)
    }
    func engine(_ s: FakeCalendarStore) -> SyncEngine { let n = now; return SyncEngine(store: s, now: { n }) }
    /// Engine with a movable clock; returns a function that sets the clock to `now + offset`.
    func clockedEngine(_ s: FakeCalendarStore, hold: TimeInterval = 300) -> (SyncEngine, @Sendable (TimeInterval) -> Void) {
        let base = now
        let clock = OSAllocatedUnfairLock(initialState: base)
        let e = SyncEngine(store: s, now: { clock.withLock { $0 } }, emptyReadHold: hold)
        return (e, { offset in clock.withLock { $0 = base.addingTimeInterval(offset) } })
    }
    /// The window the engine reads at `now` with the default look-ahead.
    var engineWindow: DateInterval {
        let start = Calendar.current.startOfDay(for: now)
        return DateInterval(start: start, end: Calendar.current.date(byAdding: .day, value: 30, to: start)!)
    }
    var someTracker: ChangeTracker {
        var t = ChangeTracker()
        t.observe([ev("cal-a", "t1")], in: a, at: now.addingTimeInterval(-100), window: engineWindow)
        return t
    }
    func run(_ e: SyncEngine, mode: SyncMode = .live, settings: SyncSettings? = nil,
             tracker: ChangeTracker = ChangeTracker(), threshold: TimeInterval = 86400)
        async -> (result: SyncResult, tracker: ChangeTracker) {
        await e.runOnce(settings: settings ?? self.settings, mode: mode, tracker: tracker, staleThreshold: threshold)
    }
    func expectSkipped(_ r: (result: SyncResult, tracker: ChangeTracker), _ reason: String?,
                       _ s: FakeCalendarStore, tracker: ChangeTracker? = nil) async {
        #expect(r.result.skippedReason != nil)
        if let reason { #expect(r.result.skippedReason == reason) }
        #expect(r.result.planned.isEmpty)
        #expect(r.result.report == nil)
        #expect(r.result.mirrored.isEmpty)
        #expect(r.result.changes.isEmpty)
        #expect(r.result.notBusy.isEmpty)
        #expect(r.result.mirroredItems.isEmpty)
        #expect(r.result.plannedRetitles == 0)
        #expect(r.result.retitlesNotSticking == 0)
        #expect(r.tracker == (tracker ?? ChangeTracker()))
        #expect(await s.appliedActions.isEmpty)
    }

    @Test func dryRunDoesNotApply() async {
        let s = store([ev("cal-a", "1")])
        let r = await run(engine(s), mode: .dryRun)
        #expect(!r.result.planned.isEmpty)
        #expect(r.result.report == nil)
        #expect(r.result.skippedReason == nil)
        #expect(await s.appliedActions.isEmpty)
    }

    func declined(_ cal: String, _ id: String, hours: Double) -> EventSnapshot {
        let start = now.addingTimeInterval(hours * 3600)
        return snap(calendar: cal, localID: id, externalID: "ext-\(id)", occurrenceDate: start, start: start,
                    end: start.addingTimeInterval(3600), myResponse: .declined)
    }

    @Test func dryRunListsChangesAndNotBusy() async {
        let original = ev("cal-a", "1")
        let notBusy = declined("cal-b", "d", hours: 4)
        let s = store([original, notBusy])
        let r = await run(engine(s), mode: .dryRun)
        #expect(r.result.changes == [
            PlannedChange(kind: .add, target: b, start: original.start, end: original.end, isAllDay: false,
                          source: a, sourceLocalID: "1", occurrenceKey: ExclusionKey.occurrence(for: original),
                          includeKey: ExclusionKey.include(for: original)),
        ])
        #expect(r.result.notBusy == [
            SkippedOriginal(calendar: b, localID: "d", start: notBusy.start, end: notBusy.end, isAllDay: false,
                            reason: .declined, occurrenceKey: ExclusionKey.occurrence(for: notBusy),
                            includeKey: ExclusionKey.include(for: notBusy)),
        ])
        #expect(await s.appliedActions.isEmpty)
    }

    @Test func liveRunListsTheChangesItApplied() async {
        let original = ev("cal-a", "1")
        let gone = ev("cal-a", "gone", hours: 6)
        let staleCopy = ev("cal-b", "c1", hours: 6, marker: Marker.make(for: gone)!)
        let s = store([original, staleCopy, declined("cal-a", "d", hours: 8)])
        let r = await run(engine(s))
        #expect(r.result.report == ApplyReport(created: 1, deleted: 1))
        #expect(r.result.changes == [
            PlannedChange(kind: .add, target: b, start: original.start, end: original.end, isAllDay: false,
                          source: a, sourceLocalID: "1", occurrenceKey: ExclusionKey.occurrence(for: original),
                          includeKey: ExclusionKey.include(for: original)),
            PlannedChange(kind: .remove, target: b, start: staleCopy.start, end: staleCopy.end, isAllDay: false),
        ])
        #expect(r.result.notBusy.map(\.localID) == ["d"])
    }

    /// Exclusions reach the run: the copy of an excluded original goes and the original is listed.
    @Test func exclusionsReachTheRun() async throws {
        let original = ev("cal-a", "1")
        let copyOfIt = ev("cal-b", "c1", marker: Marker.make(for: original)!)
        let s = store([original, copyOfIt])
        let key = try #require(ExclusionKey.occurrence(for: original))
        let r = await run(engine(s), mode: .dryRun, settings: SyncSettings(selected: [a, b], excluded: [key]))
        #expect(r.result.planned == [.delete(localID: "c1", target: b)])
        #expect(r.result.changes.map(\.kind) == [.remove])
        #expect(r.result.notBusy.map(\.reason) == [.excludedByUser])
        #expect(r.result.mirroredItems.isEmpty)
        #expect(await s.appliedActions.isEmpty)
    }

    /// Already mirrored: nothing to change, yet the meeting is listed in both modes.
    @Test func mirroredItemsListedInDryRunAndLive() async {
        let original = ev("cal-a", "1")
        let copyOfIt = ev("cal-b", "c1", marker: Marker.make(for: original)!)
        let expected = [
            MirroredItem(target: b, start: original.start, end: original.end, isAllDay: false, source: a,
                         sourceLocalID: "1", occurrenceKey: ExclusionKey.occurrence(for: original),
                         includeKey: ExclusionKey.include(for: original)),
        ]
        for mode in [SyncMode.dryRun, .live] {
            let r = await run(engine(store([original, copyOfIt])), mode: mode)
            #expect(r.result.skippedReason == nil)
            #expect(r.result.planned.isEmpty)
            #expect(r.result.changes.isEmpty)
            #expect(r.result.mirroredItems == expected)
        }
    }

    @Test func failedSaveClearsChangesAndNotBusy() async {
        let s = store([ev("cal-a", "1"), declined("cal-b", "d", hours: 4)])
        await s.setApplyError(CalendarStoreError.commitFailed)
        let r = await run(engine(s))
        #expect(r.result.skippedReason == SyncEngine.saveFailed)
        #expect(!r.result.planned.isEmpty)
        #expect(r.result.changes.isEmpty)
        #expect(r.result.notBusy.isEmpty)
        #expect(r.result.mirroredItems.isEmpty)
    }

    @Test func emptyReadSkipHasNoChangesOrNotBusy() async {
        let s = store([ev("cal-a", "1"), declined("cal-b", "d", hours: 4)])
        let (e, setClock) = clockedEngine(s, hold: 300)
        let first = await run(e, mode: .dryRun)
        #expect(!first.result.changes.isEmpty)
        #expect(!first.result.notBusy.isEmpty)
        await s.removeAllEvents(in: a)
        setClock(60)
        let held = await run(e, mode: .dryRun, tracker: first.tracker)
        #expect(held.result.skippedReason == SyncEngine.emptyRead)
        #expect(held.result.changes.isEmpty)
        #expect(held.result.notBusy.isEmpty)
    }

    @Test func liveAppliesReconcileOutput() async {
        let events = [ev("cal-a", "1"), ev("cal-b", "2", hours: 5)]
        let s = store(events)
        let r = await run(engine(s))
        let w = DateInterval(start: Calendar.current.startOfDay(for: now),
                             end: Calendar.current.date(byAdding: .day, value: 30, to: Calendar.current.startOfDay(for: now))!)
        let expected = reconcile(events: events, settings: settings, window: w)
        #expect(!expected.isEmpty)
        #expect(r.result.planned == expected)
        #expect(await s.appliedActions == [expected])
        #expect(r.result.report?.created == 2)
    }

    @Test func missingCalendarSkipsRun() async {
        let s = store([ev("cal-a", "1")])
        await s.omit(b)
        let t = someTracker
        await expectSkipped(await run(engine(s), tracker: t), "A selected calendar is missing", s, tracker: t)
    }

    @Test func storeErrorSkipsRun() async {
        let s = store([ev("cal-a", "1")])
        await s.setEventsError(CalendarStoreError.incompleteEvent(calendarID: "cal-a"))
        let t = someTracker
        await expectSkipped(await run(engine(s), tracker: t), "A calendar returned an incomplete event", s, tracker: t)
        let s2 = store([ev("cal-a", "1")])
        await s2.setCalendarsError(NSError(domain: "x", code: 1))
        await expectSkipped(await run(engine(s2), tracker: t), "Could not read calendars", s2, tracker: t)
    }

    @Test func accessRevokedMidRunShowsAccessNeeded() async {
        let s = store([ev("cal-a", "1")])
        await s.setCalendarsError(CalendarStoreError.accessNotGranted)
        await expectSkipped(await run(engine(s)), "Calendar access needed", s)
        let s2 = store([ev("cal-a", "1")])
        await s2.setEventsError(CalendarStoreError.accessNotGranted)
        await expectSkipped(await run(engine(s2)), "Calendar access needed", s2)
    }

    @Test func accessDeniedSkipsRun() async {
        let s = store([ev("cal-a", "1")], access: .denied)
        let t = someTracker
        await expectSkipped(await run(engine(s), tracker: t), "Calendar access needed", s, tracker: t)
    }

    @Test func notDeterminedSkipsRun() async {
        let s = store([ev("cal-a", "1")], access: .notDetermined)
        let t = someTracker
        await expectSkipped(await run(engine(s), tracker: t), "Calendar access needed", s, tracker: t)
        #expect(await s.requestAccessCount == 0)
    }

    @Test func lessThanTwoSelectedSkipsRun() async {
        let s = store([ev("cal-a", "1")])
        let t = someTracker
        await expectSkipped(await run(engine(s), settings: SyncSettings(selected: [a]), tracker: t), "Tick at least two calendars", s, tracker: t)
    }

    @Test func nonWritableSelectedCalendarSkipsRun() async {
        let s = store([ev("cal-a", "1")], writable: false)
        let t = someTracker
        await expectSkipped(await run(engine(s), tracker: t), "A selected calendar is read-only", s, tracker: t)
    }

    @Test func staleCalendarsReported() async {
        let events = [ev("cal-a", "1"), ev("cal-b", "2")]
        var tracker = ChangeTracker()
        tracker.observe(events, in: a, at: now.addingTimeInterval(-25 * 3600), window: engineWindow)
        tracker.observe(events, in: b, at: now.addingTimeInterval(-1 * 3600), window: engineWindow)
        let r = await run(engine(store(events)), mode: .dryRun, tracker: tracker, threshold: 24 * 3600)
        #expect(r.result.stale == [a])
        #expect(r.tracker.lastChange(for: b) == now.addingTimeInterval(-3600))
    }

    @Test func applyFailureReported() async {
        let s = store([ev("cal-a", "1")])
        await s.setApplyError(CalendarStoreError.commitFailed)
        let r = await run(engine(s))
        #expect(r.result.report == nil)
        #expect(r.result.skippedReason == "Saving to Calendar failed")
        #expect(!r.result.planned.isEmpty)
        #expect(r.result.mirrored.isEmpty)
        #expect(r.tracker.lastChange(for: a) == now)
    }

    @Test func unselectedCalendarNeverFetchedOrWritten() async {
        let s = store([ev("cal-a", "1"), ev("cal-c", "3", hours: 4)], cals: ["cal-a", "cal-b", "cal-c"])
        let r = await run(engine(s))
        let calls = await s.eventCalls.map(\.calendars)
        #expect(calls == [[a, b]])
        for action in r.result.planned {
            switch action {
            case let .create(spec), let .update(_, spec), let .replace(_, spec): #expect(spec.target != c)
            case let .delete(_, target): #expect(target != c)
            }
        }
        #expect(r.result.planned.count == 1)
        #expect(r.tracker.lastChange(for: c) == nil)
    }

    @Test func windowIsStartOfTodayPlusLookAhead() async {
        let s = store([ev("cal-a", "1")])
        _ = await run(engine(s))
        let calls = await s.eventCalls
        #expect(calls.count == 1)
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        let comps = cal.dateComponents([.year, .month, .day], from: now)
        let start = cal.date(from: comps)!
        let end = cal.date(from: DateComponents(year: comps.year, month: comps.month, day: comps.day! + 30))!
        #expect(calls[0].window == DateInterval(start: start, end: end))
    }

    @Test func concurrentRunsDoNotInterleave() async {
        let s = store([ev("cal-a", "1")])
        let e = engine(s)
        async let r1 = run(e)
        async let r2 = run(e)
        _ = await (r1, r2)
        #expect(await s.maxInFlightEvents == 1)
        let created = await s.appliedActions.flatMap { $0 }.compactMap { action -> CalendarRef? in
            if case let .create(spec) = action { return spec.target } else { return nil }
        }
        #expect(created == [b])
        #expect(await s.storedEvents.filter { $0.marker != nil }.count == 1)
    }

    @Test func mirroredCountsPerTarget() async {
        let marker = Marker.make(for: ev("cal-a", "1"))!
        let other = Marker.make(for: ev("cal-a", "9"))!
        let events = [ev("cal-a", "1"), ev("cal-b", "c1", marker: marker), ev("cal-b", "c2", hours: 6, marker: other),
                      ev("cal-b", "5", hours: 8)]
        let r = await run(engine(store(events)), mode: .dryRun)
        // b: 2 copies, 1 stale delete; a: 1 create (for b's real event)
        #expect(r.result.mirrored[b] == 1)
        #expect(r.result.mirrored[a] == 1)
    }

    @Test func emptyReadAfterNonEmptySkipsOnce() async {
        let s = store([ev("cal-a", "1"), ev("cal-b", "2", hours: 5)])
        let (e, setClock) = clockedEngine(s, hold: 300)
        let first = await run(e)
        #expect(first.result.skippedReason == nil)
        #expect(first.result.emptiedCalendars.isEmpty)
        await s.removeAllEvents(in: a)
        setClock(60)
        let second = await run(e, tracker: first.tracker)
        #expect(second.result.skippedReason == SyncEngine.emptyRead)
        #expect(second.result.planned.isEmpty)
        #expect(second.result.mirrored.isEmpty)
        #expect(second.tracker == first.tracker)
        #expect(await s.appliedActions.count == 1)
        setClock(70)
        let again = await run(e, tracker: second.tracker)
        #expect(again.result.skippedReason != nil)
        #expect(await s.appliedActions.count == 1)
        setClock(60 + 300)
        let third = await run(e, tracker: again.tracker)
        #expect(third.result.skippedReason == nil)
        #expect(third.result.planned.contains { if case .delete = $0 { true } else { false } })
        #expect(third.result.emptiedCalendars == [a])
        // An emptied calendar does not look freshly alive.
        #expect(third.tracker.lastChange(for: a) == now)
        #expect(third.tracker.lastChange(for: b) == now)
        setClock(60 + 300 + 300)
        let fourth = await run(e, tracker: third.tracker)
        #expect(fourth.result.skippedReason == nil)
        #expect(fourth.result.emptiedCalendars.isEmpty)
        #expect(fourth.tracker.lastChange(for: a) == now)
    }

    @Test func emptiedCalendarsReportedInSelectionOrder() async {
        let s = store([ev("cal-a", "1"), ev("cal-b", "2", hours: 5), ev("cal-c", "3", hours: 7)],
                      cals: ["cal-a", "cal-b", "cal-c"])
        let three = SyncSettings(selected: [c, a, b])
        let (e, setClock) = clockedEngine(s, hold: 300)
        #expect(await run(e, settings: three).result.skippedReason == nil)
        await s.removeAllEvents(in: a)
        await s.removeAllEvents(in: c)
        setClock(10)
        let held = await run(e, settings: three)
        #expect(held.result.skippedReason == SyncEngine.emptyRead)
        #expect(held.result.emptiedCalendars.isEmpty)
        setClock(10 + 300)
        let accepted = await run(e, settings: three)
        #expect(accepted.result.skippedReason == nil)
        #expect(accepted.result.emptiedCalendars == [c, a])
    }

    @Test func guardRearmsAfterNonZeroRead() async {
        let s = store([ev("cal-a", "1"), ev("cal-b", "2", hours: 5)])
        let (e, setClock) = clockedEngine(s, hold: 300)
        _ = await run(e)
        await s.removeAllEvents(in: a)
        setClock(10)
        #expect(await run(e).result.skippedReason != nil)
        await s.addEvents([ev("cal-a", "1")])
        setClock(20)
        #expect(await run(e).result.skippedReason == nil)
        await s.removeAllEvents(in: a)
        setClock(400)
        #expect(await run(e).result.skippedReason == SyncEngine.emptyRead)
    }

    @Test func nonZeroReadClearsGuardEvenWhenRunSkipped() async {
        let s = store([ev("cal-a", "1"), ev("cal-b", "2", hours: 5)])
        let (e, setClock) = clockedEngine(s, hold: 300)
        _ = await run(e)
        await s.removeAllEvents(in: a)
        setClock(10)
        #expect(await run(e).result.skippedReason == SyncEngine.emptyRead)
        await s.addEvents([ev("cal-a", "1")])
        await s.removeAllEvents(in: b)
        setClock(20)
        #expect(await run(e).result.skippedReason == SyncEngine.emptyRead)
        await s.removeAllEvents(in: a)
        setClock(400)
        let r = await run(e)
        #expect(r.result.skippedReason == SyncEngine.emptyRead)
        #expect(r.result.planned.isEmpty)
    }

    @Test func applyAccessRevokedShowsAccessNeeded() async {
        let s = store([ev("cal-a", "1")])
        await s.setApplyError(CalendarStoreError.accessNotGranted)
        let r = await run(engine(s))
        #expect(r.result.skippedReason == SyncEngine.accessNeeded)
        #expect(r.result.report == nil)
        #expect(r.result.mirrored.isEmpty)
    }

    /// A marked event with attendees (a copy someone added attendees to, its original gone) is neither a
    /// source nor a copy: it is not mirrored, not deleted and not counted.
    @Test func markedEventWithAttendeesIsNeitherMirroredNorDeleted() async {
        let gone = ev("cal-a", "gone")
        var invited = ev("cal-b", "c1", hours: 6, marker: Marker.make(for: gone)!)
        invited.externalID = "server-uid-of-the-copy"
        let original = ev("cal-a", "1")
        let s = store([original])
        await s.addEvents([invited], withAttendees: true)
        let r = await run(engine(s))
        let spec = CopySpec(target: b, marker: Marker.make(for: original)!, start: original.start, end: original.end,
                            isAllDay: false)
        #expect(r.result.planned == [.create(spec)])
        #expect(r.result.mirrored == [a: 0, b: 1])
        #expect(await s.storedEvents.contains(invited))
    }

    @Test func firstRunEmptyIsNotGuarded() async {
        let s = store([ev("cal-b", "2")])
        let r = await run(engine(s))
        #expect(r.result.skippedReason == nil)
        #expect(!r.result.planned.isEmpty)
        #expect(r.result.emptiedCalendars.isEmpty)
    }

    @Test func removeAllCopiesDeletesOnlyMarked() async {
        let marker = Marker.make(for: ev("cal-a", "1"))!
        let s = store([ev("cal-a", "1"), ev("cal-b", "c1", marker: marker), ev("cal-b", "5", hours: 8),
                       ev("cal-a", "c2", hours: 30, marker: marker)])
        let report = await engine(s).removeAllCopies(in: [a, b])
        #expect(report.deleted == 2)
        #expect(report.failures.isEmpty)
        let left = await s.storedEvents
        #expect(left.map(\.localID).sorted() == ["1", "5"])
    }

    // MARK: - Updates executed as replacements

    /// The copy of `original` in cal-b, as reconcile wants it, titled `title`.
    func copySpec(of original: EventSnapshot, title: String = CopySpec.busyTitle) -> CopySpec {
        CopySpec(target: b, marker: Marker.make(for: original)!, start: original.start, end: original.end,
                 isAllDay: original.isAllDay, title: title)
    }

    /// A moved original: the plan says update, the store gets a replacement (a new copy at the new times, the
    /// old one gone), never an update.
    @Test func updatesAreAppliedAsReplacements() async {
        let original = ev("cal-a", "1", hours: 4)
        let s = store([original, ev("cal-b", "c1", hours: 2, marker: Marker.make(for: original)!)])
        let spec = copySpec(of: original)
        let r = await run(engine(s))
        #expect(r.result.planned == [.update(localID: "c1", spec)])
        #expect(await s.appliedActions.last == [.replace(localID: "c1", spec)])
        #expect(r.result.report == ApplyReport(replaced: 1))
        #expect(r.result.report?.replaced == 1 && r.result.report?.updated == 0)
        let inB = await s.storedEvents.filter { $0.calendar == b }
        #expect(inB.count == 1)
        #expect(inB.first?.localID != "c1")
        #expect(inB.first?.marker == spec.marker)
        #expect(inB.first?.start == original.start && inB.first?.end == original.end)
    }

    /// What a run says it plans is the same in Dry run and Live: replacing is only how the store executes it.
    @Test func replacementKeepsPlanSemantics() async {
        let moved = ev("cal-a", "1", hours: 4)
        let retitled = titled(ev("cal-a", "2", hours: 6), "Weekly sync")
        let added = ev("cal-a", "3", hours: 8)
        let gone = ev("cal-a", "gone", hours: 10)
        let s = store([moved, retitled, added,
                       ev("cal-b", "c1", hours: 2, marker: Marker.make(for: moved)!),
                       titled(ev("cal-b", "c2", hours: 6, marker: Marker.make(for: retitled)!), "Old name"),
                       ev("cal-b", "c4", hours: 10, marker: Marker.make(for: gone)!)])
        let e = engine(s)
        let dry = await run(e, mode: .dryRun, settings: titleSettings)
        let live = await run(e, settings: titleSettings)
        #expect(dry.result.changes.map(\.kind) == [.move, .retitle, .add, .remove])
        #expect(live.result.changes == dry.result.changes)
        #expect(live.result.planned == dry.result.planned)
        #expect(live.result.plannedRetitles == dry.result.plannedRetitles)
        #expect(live.result.plannedRetitles == 1)
        #expect(live.result.plannedCounts == dry.result.plannedCounts)
        #expect(live.result.plannedCounts == (add: 1, remove: 1))
        #expect(live.result.mirrored == dry.result.mirrored)
        #expect(live.result.report == ApplyReport(created: 1, replaced: 2, deleted: 1))
    }

    /// A replacement whose create fails keeps the old copy, so no Busy block is lost; the next run tries again.
    @Test func replaceKeepsOldCopyWhenCreateFails() async {
        let original = ev("cal-a", "1", hours: 4)
        let old = ev("cal-b", "c1", hours: 2, marker: Marker.make(for: original)!)
        let s = store([original, old])
        await s.setFailsCreates(true)
        let e = engine(s)
        let first = await run(e)
        #expect(first.result.report == ApplyReport(failures: ["replace c1: create failed"]))
        #expect(first.result.report?.replaced == 0)
        #expect(await s.storedEvents.filter { $0.calendar == b } == [old])

        await s.setFailsCreates(false)
        let second = await run(e)
        #expect(second.result.planned == [.update(localID: "c1", copySpec(of: original))])
        #expect(second.result.report == ApplyReport(replaced: 1))
        let inB = await s.storedEvents.filter { $0.calendar == b }
        #expect(inB.count == 1)
        #expect(inB.first?.localID != "c1")
        #expect(inB.first?.start == original.start)
    }

    /// A replacement whose old copy cannot be removed leaves the new copy next to it. The next run keeps the new
    /// copy, which is already right, and only tries to delete the old one again: no create and no replacement,
    /// so a removal that keeps failing does not create and delete a copy every run.
    @Test func failingRemoveDoesNotChurn() async throws {
        let original = ev("cal-a", "1", hours: 4)
        let old = ev("cal-b", "c1", hours: 2, marker: Marker.make(for: original)!)
        let s = store([original, old])
        await s.setFailsRemoves(["c1"])
        let e = engine(s)
        let spec = copySpec(of: original)

        let first = await run(e)
        #expect(first.result.planned == [.update(localID: "c1", spec)])
        #expect(await s.appliedActions.last == [.replace(localID: "c1", spec)])
        #expect(first.result.report == ApplyReport(created: 1, failures: ["replace c1: remove failed"]))
        let afterFirst = await s.storedEvents.filter { $0.calendar == b }
        #expect(afterFirst.count == 2)
        #expect(afterFirst.first == old)
        let fresh = try #require(afterFirst.last)
        #expect(fresh.localID != "c1")
        #expect(fresh.marker == spec.marker && fresh.start == spec.start && fresh.end == spec.end)

        for _ in 0..<2 {
            let again = await run(e)
            #expect(again.result.planned == [.delete(localID: "c1", target: b)])
            #expect(again.result.changes.map(\.kind) == [.removeDuplicates])
            #expect(await s.appliedActions.last == [.delete(localID: "c1", target: b)])
            #expect(again.result.report == ApplyReport(failures: ["delete c1: remove failed"]))
            #expect(await s.storedEvents.filter { $0.calendar == b } == afterFirst)
        }

        // Once the removal works, the old copy goes and the new one is all that is left.
        await s.setFailsRemoves([])
        let last = await run(e)
        #expect(last.result.planned == [.delete(localID: "c1", target: b)])
        #expect(last.result.report == ApplyReport(deleted: 1))
        #expect(await s.storedEvents.filter { $0.calendar == b } == [fresh])
    }

    /// The old copy vanished between the plan and the write (another Mac removed it): the new copy is still
    /// created, and the replacement counts as done.
    @Test func replaceOfVanishedCopyStillCreates() async throws {
        let original = ev("cal-a", "1", hours: 4)
        let s = store([original, ev("cal-b", "c1", hours: 2, marker: Marker.make(for: original)!)])
        let dry = await run(engine(s), mode: .dryRun)
        #expect(dry.result.planned == [.update(localID: "c1", copySpec(of: original))])
        await s.removeAllEvents(in: b)
        let report = try await s.apply(replacingUpdates(dry.result.planned))
        #expect(report == ApplyReport(replaced: 1))
        let inB = await s.storedEvents.filter { $0.calendar == b }
        #expect(inB.count == 1)
        #expect(inB.first?.start == original.start && inB.first?.marker == Marker.make(for: original))
    }

    /// The old id names something that is not our copy of this original (another marker, attendees, an ordinary
    /// event): the replacement fails before anything is written, so no new copy appears and the store is as it
    /// was.
    @Test func replaceRefusedForNonCopyCreatesNothing() async throws {
        let original = ev("cal-a", "1", hours: 4)
        let other = ev("cal-a", "2", hours: 6)
        let mismatched = ev("cal-b", "c1", hours: 2, marker: Marker.make(for: other)!)
        let invited = ev("cal-b", "c2", hours: 2, marker: Marker.make(for: original)!)
        let plain = ev("cal-b", "5", hours: 8)
        let s = store([original, other, mismatched, plain])
        await s.addEvents([invited], withAttendees: true)
        let before = await s.storedEvents
        let spec = copySpec(of: original)
        let report = try await s.apply([.replace(localID: "c1", spec), .replace(localID: "c2", spec),
                                        .replace(localID: "5", spec)])
        #expect(report == ApplyReport(failures: ["replace c1: marker mismatch", "replace c2: event has attendees",
                                                 "replace 5: not a marked copy"]))
        #expect(await s.storedEvents == before)
    }

    /// The move of a copy the store refuses to write: its replacement fails before anything is written, so B
    /// holds no extra copy and the next run plans the move again.
    @Test func refusedMoveWritesNothingAndIsPlannedAgain() async {
        let original = ev("cal-a", "1")
        let other = ev("cal-a", "2", hours: 4)
        // A recurring event carrying a marker reads as a copy, but the store refuses to write it.
        var refused = ev("cal-b", "c2", hours: 6, marker: Marker.make(for: other)!)
        refused.isRecurringOccurrence = true
        let s = store([original, other, ev("cal-b", "c1", marker: Marker.make(for: original)!), refused])
        let e = engine(s)
        let move = SyncAction.update(localID: "c2", copySpec(of: other))

        let first = await run(e)
        #expect(first.result.planned == [move])
        #expect(first.result.changes.map(\.kind) == [.move])
        #expect(await s.appliedActions.last == [.replace(localID: "c2", copySpec(of: other))])
        #expect(first.result.report == ApplyReport(failures: ["replace c2: event is recurring"]))
        #expect(await s.storedEvents.filter { $0.calendar == b }.count == 2)

        let second = await run(e)
        #expect(second.result.planned == [move])
    }

    // MARK: - Titles

    /// cal-a's meetings show their title in cal-b; cal-b's show `Busy only` in cal-a.
    var titleSettings: SyncSettings {
        SyncSettings(selected: [a, b], copyTitleFormats: [CopyRoute(source: a, target: b): .title])
    }

    /// `e` reading `title`.
    func titled(_ e: EventSnapshot, _ title: String) -> EventSnapshot {
        var e = e
        e.title = title
        return e
    }

    /// A copy that reads another title than its route shows: the plan says retitle, the store gets a
    /// replacement, and B holds one copy with the meeting's title; the next run plans nothing.
    @Test func retitleIsAppliedAsReplacement() async {
        let original = titled(ev("cal-a", "1"), "Weekly sync")
        let s = store([original, titled(ev("cal-b", "c1", marker: Marker.make(for: original)!), "Old name")])
        let spec = copySpec(of: original, title: "Weekly sync")
        let e = engine(s)

        let r = await run(e, settings: titleSettings)
        #expect(r.result.planned == [.update(localID: "c1", spec)])
        #expect(r.result.changes.map(\.kind) == [.retitle])
        #expect(r.result.plannedRetitles == 1)
        #expect(r.result.plannedCounts == (add: 0, remove: 0))
        #expect(r.result.retitlesNotSticking == 0)
        #expect(await s.appliedActions.last == [.replace(localID: "c1", spec)])
        #expect(r.result.report == ApplyReport(replaced: 1))
        let inB = await s.storedEvents.filter { $0.calendar == b }
        #expect(inB.count == 1)
        #expect(inB.first?.localID != "c1")
        #expect(inB.first?.title == "Weekly sync")
        #expect(inB.first?.marker == spec.marker)

        let second = await run(e, settings: titleSettings)
        #expect(second.result.planned.isEmpty)
        #expect(second.result.retitlesNotSticking == 0)
    }

    /// A server that rewrites titles: the copy is replaced once, then held while its title is the one already
    /// sent, counted as not sticking in Live and in Dry run. A rename of the meeting is a new title, so the copy
    /// is replaced again, once.
    @Test func rewrittenTitleIsNotReplacedAgain() async throws {
        let original = titled(ev("cal-a", "1"), "Weekly sync")
        let s = store([original, titled(ev("cal-b", "c1", marker: Marker.make(for: original)!), "Old name")])
        await s.setRewritesTitles { "[EXT] " + $0 }
        let e = engine(s)

        let first = await run(e, settings: titleSettings)
        #expect(first.result.planned == [.update(localID: "c1", copySpec(of: original, title: "Weekly sync"))])
        #expect(first.result.report == ApplyReport(replaced: 1))
        let rewritten = await s.storedEvents.filter { $0.calendar == b }
        #expect(rewritten.map(\.title) == ["[EXT] Weekly sync"])
        let copy = try #require(rewritten.first)

        let second = await run(e, settings: titleSettings)
        #expect(second.result.planned == [])
        #expect(second.result.changes.isEmpty)
        #expect(second.result.plannedRetitles == 0)
        #expect(second.result.retitlesNotSticking == 1)
        #expect(second.result.mirrored == [a: 0, b: 1])
        let dry = await run(e, mode: .dryRun, settings: titleSettings)
        #expect(dry.result.planned == [])
        #expect(dry.result.retitlesNotSticking == 1)
        #expect(await s.storedEvents.filter { $0.calendar == b } == rewritten)

        var renamed = original
        renamed.title = "Weekly review"
        await s.removeAllEvents(in: a)
        await s.addEvents([renamed])
        let third = await run(e, settings: titleSettings)
        #expect(third.result.planned == [.update(localID: copy.localID, copySpec(of: renamed, title: "Weekly review"))])
        #expect(third.result.changes.map(\.kind) == [.retitle])
        #expect(third.result.retitlesNotSticking == 0)
        #expect(third.result.report == ApplyReport(replaced: 1))
        #expect(await s.storedEvents.filter { $0.calendar == b }.map(\.title) == ["[EXT] Weekly review"])

        let fourth = await run(e, settings: titleSettings)
        #expect(fourth.result.planned == [])
        #expect(fourth.result.retitlesNotSticking == 1)
        #expect(await s.appliedActions.flatMap { $0 }.count == 2)
    }

    /// Every create sends the title too: a new copy whose title the server rewrites is held on the next run.
    @Test func rewrittenTitleOfANewCopyIsHeld() async {
        let original = titled(ev("cal-a", "1"), "Weekly sync")
        let s = store([original])
        await s.setRewritesTitles { "[EXT] " + $0 }
        let e = engine(s)

        let first = await run(e, settings: titleSettings)
        #expect(first.result.planned == [.create(copySpec(of: original, title: "Weekly sync"))])
        #expect(first.result.report == ApplyReport(created: 1))

        let second = await run(e, settings: titleSettings)
        #expect(second.result.planned == [])
        #expect(second.result.retitlesNotSticking == 1)
        #expect(await s.storedEvents.filter { $0.calendar == b }.map(\.title) == ["[EXT] Weekly sync"])
    }

    /// A retitle whose replacement fails (its create fails, so the old copy stays as it is): the failed write
    /// churned nothing, so the copy is not held. It is sent again every run while the failure lasts, and once the
    /// store works again the copy ends with the wanted title.
    @Test func failedRetitleIsRetried() async {
        let original = titled(ev("cal-a", "1"), "Weekly sync")
        let old = titled(ev("cal-b", "c1", marker: Marker.make(for: original)!), "Old name")
        let s = store([original, old])
        await s.setFailsCreates(true)
        let e = engine(s)
        let retitle = SyncAction.update(localID: "c1", copySpec(of: original, title: "Weekly sync"))

        let first = await run(e, settings: titleSettings)
        #expect(first.result.planned == [retitle])
        #expect(first.result.report == ApplyReport(failures: ["replace c1: create failed"]))
        #expect(await s.storedEvents == [original, old])

        let second = await run(e, settings: titleSettings)
        #expect(second.result.planned == [retitle])
        #expect(second.result.retitlesNotSticking == 0)
        #expect(await run(e, mode: .dryRun, settings: titleSettings).result.retitlesNotSticking == 0)

        await s.setFailsCreates(false)
        let third = await run(e, settings: titleSettings)
        #expect(third.result.planned == [retitle])
        #expect(third.result.retitlesNotSticking == 0)
        #expect(third.result.report == ApplyReport(replaced: 1))
        #expect(await s.storedEvents.filter { $0.calendar == b }.map(\.title) == ["Weekly sync"])
    }

    /// A copy shows the meeting's title, then the title is to be hidden (cal-a → cal-b back to `Busy only`, or the
    /// meeting hidden): the first replacement fails, and the next run replaces the copy, which then reads `Busy`. A
    /// failure never leaves a hidden title showing.
    @Test func hiddenTitleFailureIsRetried() async throws {
        let original = titled(ev("cal-a", "1"), "Weekly sync")
        let key = try #require(ExclusionKey.occurrence(for: original))
        var hidden = titleSettings
        hidden.hiddenTitleKeys = [key]
        for hiding in [settings, hidden] {
            let s = store([original, titled(ev("cal-b", "c1", marker: Marker.make(for: original)!), "Old name")])
            let e = engine(s)
            // The title goes out first, so the slot has a recorded write.
            #expect(await run(e, settings: titleSettings).result.report == ApplyReport(replaced: 1))
            let shown = try #require(await s.storedEvents.first { $0.calendar == b })
            #expect(shown.title == "Weekly sync")
            let toBusy = SyncAction.update(localID: shown.localID, copySpec(of: original))

            await s.setFailsCreates(true)
            let failed = await run(e, settings: hiding)
            #expect(failed.result.planned == [toBusy])
            #expect(failed.result.changes.map(\.kind) == [.retitle])
            #expect(failed.result.report == ApplyReport(failures: ["replace \(shown.localID): create failed"]))

            await s.setFailsCreates(false)
            let retried = await run(e, settings: hiding)
            #expect(retried.result.planned == [toBusy])
            #expect(retried.result.retitlesNotSticking == 0)
            #expect(retried.result.report == ApplyReport(replaced: 1))
            #expect(await s.storedEvents.filter { $0.calendar == b }.map(\.title) == ["Busy"])
            #expect(await run(e, settings: hiding).result.planned == [])
        }
    }

    /// A replacement whose old copy cannot be removed: the new copy has the wanted title and stays, the old one is
    /// only deleted again. The old copy still reads its old title, but it is the copy that was replaced, so the
    /// slot is not counted as not sticking.
    @Test func replacedCopyWhoseRemovalFailedIsNotCounted() async {
        let original = titled(ev("cal-a", "1"), "Weekly sync")
        let s = store([original, titled(ev("cal-b", "c1", marker: Marker.make(for: original)!), "Old name")])
        await s.setFailsRemoves(["c1"])
        let e = engine(s)

        let first = await run(e, settings: titleSettings)
        #expect(first.result.report == ApplyReport(created: 1, failures: ["replace c1: remove failed"]))
        #expect(await s.storedEvents.filter { $0.calendar == b }.map(\.title) == ["Old name", "Weekly sync"])

        let second = await run(e, settings: titleSettings)
        #expect(second.result.planned == [.delete(localID: "c1", target: b)])
        #expect(second.result.changes.map(\.kind) == [.removeDuplicates])
        #expect(second.result.retitlesNotSticking == 0)
    }

    /// The two cases of the failed-removal tests below, on a server that rewrites titles: the copy in B reads `old`
    /// and is to read `wanted.title`, either the meeting's own title (cal-b shows `Title`) or `Busy` (cal-b shows
    /// `Busy only`, so the meeting's title is to be hidden).
    func failedRemovalCases(_ original: EventSnapshot) -> [(settings: SyncSettings, old: String, wanted: CopySpec)] {
        [(titleSettings, "Old name", copySpec(of: original, title: "Secret")),
         (settings, "Secret", copySpec(of: original))]
    }

    /// The run after a failed removal was settled and B holds only `inB`, one copy reading the rewritten wanted
    /// title: a rewritten meeting title is held, a rewritten `Busy` never is (`heldRetitles`), so that copy is
    /// replaced again, and the meeting's title shows in neither case.
    func expectHeldUnlessBusy(_ e: SyncEngine, _ s: FakeCalendarStore, settings: SyncSettings, wanted: CopySpec,
                              inB: [EventSnapshot]) async throws {
        let next = await run(e, settings: settings)
        if wanted.title == CopySpec.busyTitle {
            let copy = try #require(inB.first)
            #expect(next.result.planned == [.update(localID: copy.localID, wanted)])
            #expect(next.result.changes.map(\.kind) == [.retitle])
            #expect(next.result.retitlesNotSticking == 0)
            #expect(next.result.report == ApplyReport(replaced: 1))
            #expect(await s.storedEvents.filter { $0.calendar == b }.map(\.title) == ["[EXT] Busy"])
        } else {
            #expect(next.result.planned == [])
            #expect(next.result.retitlesNotSticking == 1)
            #expect(await s.storedEvents.filter { $0.calendar == b } == inB)
        }
    }

    /// A copy's title is to change, to the meeting's title or to `Busy` (`failedRemovalCases`), and the removal of
    /// the replaced copy fails once. While that copy is still there nothing is held: the next run keeps it,
    /// retitles it and deletes the successor, so the replaced copy's title does not stick. Once no earlier copy is
    /// left, B holds one copy reading the rewritten wanted title, held unless it is `Busy`.
    @Test func failedRemovalOfTheReplacedCopyDoesNotHoldItsTitle() async throws {
        let original = titled(ev("cal-a", "1"), "Secret")
        for (wanting, old, wanted) in failedRemovalCases(original) {
            let s = store([original, titled(ev("cal-b", "c1", marker: Marker.make(for: original)!), old)])
            await s.setRewritesTitles { "[EXT] " + $0 }
            await s.setFailsRemoves(["c1"])
            let e = engine(s)

            let first = await run(e, settings: wanting)
            #expect(first.result.planned == [.update(localID: "c1", wanted)])
            #expect(first.result.report == ApplyReport(created: 1, failures: ["replace c1: remove failed"]))
            #expect(await s.storedEvents.filter { $0.calendar == b }.map(\.title) == [old, "[EXT] " + wanted.title])
            let successor = try #require(await s.storedEvents.first { $0.calendar == b && $0.localID != "c1" })
            #expect(await run(e, mode: .dryRun, settings: wanting).result.retitlesNotSticking == 0)

            await s.setFailsRemoves([])
            let second = await run(e, settings: wanting)
            #expect(second.result.retitlesNotSticking == 0)
            #expect(second.result.planned == [.delete(localID: successor.localID, target: b),
                                              .update(localID: "c1", wanted)])
            #expect(second.result.report == ApplyReport(replaced: 1, deleted: 1))
            let inB = await s.storedEvents.filter { $0.calendar == b }
            #expect(inB.map(\.title) == ["[EXT] " + wanted.title])

            try await expectHeldUnlessBusy(e, s, settings: wanting, wanted: wanted, inB: inB)
        }
    }

    /// The same with two copies of the meeting in B, both reading the old title, and the delete of the duplicate
    /// failing once: the next run is not held while that duplicate is there, keep-one keeps it and retitles it,
    /// and B ends with one copy reading the rewritten wanted title, none with the old one.
    @Test func failedDeleteOfADuplicateDoesNotHoldItsTitle() async throws {
        let original = titled(ev("cal-a", "1"), "Secret")
        let marker = Marker.make(for: original)!
        for (wanting, old, wanted) in failedRemovalCases(original) {
            let s = store([original, titled(ev("cal-b", "c1", marker: marker), old),
                           titled(ev("cal-b", "d1", marker: marker), old)])
            await s.setRewritesTitles { "[EXT] " + $0 }
            await s.setFailsRemoves(["d1"])
            let e = engine(s)

            let first = await run(e, settings: wanting)
            #expect(first.result.planned == [.delete(localID: "d1", target: b), .update(localID: "c1", wanted)])
            #expect(first.result.report == ApplyReport(replaced: 1, failures: ["delete d1: remove failed"]))
            #expect(await s.storedEvents.filter { $0.calendar == b }.map(\.title) == [old, "[EXT] " + wanted.title])
            let successor = try #require(await s.storedEvents.first { $0.calendar == b && $0.localID != "d1" })
            #expect(await run(e, mode: .dryRun, settings: wanting).result.retitlesNotSticking == 0)

            await s.setFailsRemoves([])
            let second = await run(e, settings: wanting)
            #expect(second.result.retitlesNotSticking == 0)
            #expect(second.result.planned == [.delete(localID: successor.localID, target: b),
                                              .update(localID: "d1", wanted)])
            #expect(second.result.report == ApplyReport(replaced: 1, deleted: 1))
            let inB = await s.storedEvents.filter { $0.calendar == b }
            #expect(inB.map(\.title) == ["[EXT] " + wanted.title])

            try await expectHeldUnlessBusy(e, s, settings: wanting, wanted: wanted, inB: inB)
        }
    }

    /// A copy someone else titled in a slot whose wanted title is `Busy` (a second Mac with other settings, a copy
    /// the server restored under a new id, a delegate's edit), after this engine wrote that slot and none of the
    /// copies it saw then is left: the slot is never held, so the next live run replaces the copy with a `Busy`
    /// one. Both ways of wanting `Busy`: cal-a → cal-b shows `Busy only`, or it shows `Title` and the meeting is
    /// hidden.
    @Test func busySlotIsNeverHeld() async throws {
        let original = titled(ev("cal-a", "1"), "Secret")
        var hidden = titleSettings
        hidden.hiddenTitleKeys = [try #require(ExclusionKey.occurrence(for: original))]
        for wantingBusy in [settings, hidden] {
            let s = store([original])
            let mac1 = engine(s)
            let mac2 = engine(s)
            let toBusy = copySpec(of: original)

            let first = await run(mac1, settings: wantingBusy)
            #expect(first.result.planned == [.create(toBusy)])
            #expect(first.result.report == ApplyReport(created: 1))
            let busyCopy = try #require(await s.storedEvents.first { $0.calendar == b })

            // The other engine shows the meeting's title in cal-b.
            let other = await run(mac2, settings: titleSettings)
            #expect(other.result.planned == [.update(localID: busyCopy.localID,
                                                     copySpec(of: original, title: "Secret"))])
            #expect(other.result.report == ApplyReport(replaced: 1))
            let titledCopy = try #require(await s.storedEvents.first { $0.calendar == b })
            #expect(titledCopy.title == "Secret")

            let next = await run(mac1, settings: wantingBusy)
            #expect(next.result.planned == [.update(localID: titledCopy.localID, toBusy)])
            #expect(next.result.changes.map(\.kind) == [.retitle])
            #expect(next.result.retitlesNotSticking == 0)
            #expect(next.result.report == ApplyReport(replaced: 1))
            #expect(await s.storedEvents.filter { $0.calendar == b }.map(\.title) == ["Busy"])
            #expect(await run(mac1, settings: wantingBusy).result.planned == [])
        }
    }

    /// A save that fails writes nothing, so no title counts as sent: the next run sends the retitle again.
    @Test func retitleRetriedAfterFailedSave() async {
        let original = titled(ev("cal-a", "1"), "Weekly sync")
        let s = store([original, titled(ev("cal-b", "c1", marker: Marker.make(for: original)!), "Old name")])
        await s.setApplyError(CalendarStoreError.commitFailed)
        let e = engine(s)

        let first = await run(e, settings: titleSettings)
        #expect(first.result.skippedReason == SyncEngine.saveFailed)
        #expect(first.result.plannedRetitles == 0)
        #expect(first.result.retitlesNotSticking == 0)

        await s.setApplyError(nil)
        let second = await run(e, settings: titleSettings)
        #expect(second.result.planned == [.update(localID: "c1", copySpec(of: original, title: "Weekly sync"))])
        #expect(second.result.plannedRetitles == 1)
        #expect(second.result.retitlesNotSticking == 0)
        #expect(second.result.report == ApplyReport(replaced: 1))
    }

    @Test func removeAllCopiesNeedsAccess() async {
        let s = store([], access: .denied)
        let report = await engine(s).removeAllCopies(in: [a])
        #expect(report == ApplyReport(failures: ["Calendar access needed"]))
        #expect(await s.appliedActions.isEmpty)
    }

    @Test func removeAllCopiesFetchErrorGivesFailure() async {
        let s = store([])
        await s.setEventsError(NSError(domain: "x", code: 1))
        let report = await engine(s).removeAllCopies(in: [a])
        #expect(report == ApplyReport(failures: ["Could not read calendars"]))
    }

    /// After the upgrade every route is `Busy only`: originals now carry their titles, a copy made before
    /// reads `Busy`, the first live run only adds the missing copy and the second plans nothing.
    @Test func upgradeRunPlansNothing() async {
        var fromA = ev("cal-a", "1")
        fromA.title = "Weekly sync"
        var fromB = ev("cal-b", "2", hours: 4)
        fromB.title = "Planning"
        var earlierCopy = ev("cal-b", "c1", marker: Marker.make(for: fromA)!)
        earlierCopy.title = "Busy"
        let s = store([fromA, fromB, earlierCopy])
        let e = engine(s)

        let first = await run(e)
        #expect(first.result.planned == [
            .create(CopySpec(target: a, marker: Marker.make(for: fromB)!, start: fromB.start, end: fromB.end,
                             isAllDay: false)),
        ])
        #expect(first.result.report == ApplyReport(created: 1))

        let second = await run(e)
        #expect(second.result.planned == [])
        #expect(second.result.changes.isEmpty)
        #expect(await s.storedEvents.filter { $0.marker != nil }.map(\.title) == ["Busy", "Busy"])
    }

    // MARK: - Pairs set to Nothing

    /// Titles on, the same meeting in cal-a and cal-b at the same time and one only in cal-a, through live runs. With
    /// cal-a → cal-c set to Nothing, one run retitles the shared meeting's block in cal-c in place, now taken from
    /// cal-b, and removes the other one; the next run plans nothing and holds no title. Set back, the block returns,
    /// the shared one is retitled again, and the next run plans nothing again.
    @Test func nothingPairSettlesWithTitles() async {
        let shared = titled(ev("cal-a", "1", ext: "m"), "Weekly sync")
        let sharedInB = titled(ev("cal-b", "2", ext: "m"), "Weekly sync")
        let solo = titled(ev("cal-a", "3", hours: 5), "Planning")
        let s = store([shared, sharedInB, solo], cals: ["cal-a", "cal-b", "cal-c"])
        let e = engine(s)
        func pairs(fromA format: CopyTitleFormat) -> SyncSettings {
            SyncSettings(selected: [a, b, c], copyTitleFormats: [CopyRoute(source: a, target: c): format,
                                                                 CopyRoute(source: b, target: c): .sourceAndTitle],
                         sourceLabels: [b: "Initech"])
        }

        #expect(await run(e, settings: pairs(fromA: .title)).result.report == ApplyReport(created: 3))
        #expect(await run(e, settings: pairs(fromA: .title)).result.planned.isEmpty)

        let oneWay = await run(e, settings: pairs(fromA: .nothing))
        #expect(oneWay.result.changes.map(\.kind) == [.retitle, .remove])
        #expect(oneWay.result.changes.map(\.source) == [b, a])
        #expect(oneWay.result.report == ApplyReport(replaced: 1, deleted: 1))
        let settled = await run(e, settings: pairs(fromA: .nothing))
        #expect(settled.result.planned.isEmpty)
        #expect(settled.result.retitlesNotSticking == 0)
        #expect(await s.storedEvents.filter { $0.calendar == c }.map(\.title) == ["Initech: Weekly sync"])

        let back = await run(e, settings: pairs(fromA: .title))
        #expect(back.result.report == ApplyReport(created: 1, replaced: 1))
        #expect(await run(e, settings: pairs(fromA: .title)).result.planned.isEmpty)
        #expect(await s.storedEvents.filter { $0.calendar == c }.compactMap(\.title).sorted()
            == ["Planning", "Weekly sync"])
        #expect(await s.storedEvents.filter { $0.marker == nil }.count == 3)
    }

    /// A Busy block on a pair set to Nothing whose removal fails: each run tries that removal again and nothing else,
    /// no new copy and no title held; once it goes, the next run plans nothing.
    @Test func failedRemovalOnANothingPairIsRetriedAlone() async throws {
        let s = store([titled(ev("cal-a", "1"), "Weekly sync"), titled(ev("cal-b", "2", hours: 5), "Planning")])
        let e = engine(s)
        #expect(await run(e, settings: titleSettings).result.report == ApplyReport(created: 2))
        let stored = await s.storedEvents
        let copyInB = try #require(stored.first { $0.calendar == b && $0.marker != nil }).localID
        await s.setFailsRemoves([copyInB])

        let oneWay = SyncSettings(selected: [a, b], copyTitleFormats: [CopyRoute(source: a, target: b): .nothing])
        for _ in 0..<2 {
            let again = await run(e, settings: oneWay)
            #expect(again.result.planned == [.delete(localID: copyInB, target: b)])
            #expect(again.result.report == ApplyReport(failures: ["delete \(copyInB): remove failed"]))
            #expect(again.result.retitlesNotSticking == 0)
        }
        await s.setFailsRemoves([])
        #expect(await run(e, settings: oneWay).result.report == ApplyReport(deleted: 1))
        #expect(await run(e, settings: oneWay).result.planned.isEmpty)
        #expect(await s.storedEvents.filter { $0.marker != nil }.map(\.calendar) == [a])
    }

    @Test func removeAllCopiesLeavesUnlistedCalendars() async {
        let marker = Marker.make(for: ev("cal-a", "1"))!
        let s = store([ev("cal-a", "1"), ev("cal-b", "c1", marker: marker), ev("cal-c", "c3", hours: 4, marker: marker)],
                      cals: ["cal-a", "cal-b", "cal-c"])
        let report = await engine(s).removeAllCopies(in: [a, b])
        #expect(report.deleted == 1)
        #expect(await s.storedEvents.map(\.localID).sorted() == ["1", "c3"])
    }

    @Test func removeAllCopiesEmptyListDoesNothing() async {
        let s = store([ev("cal-a", "1")])
        let report = await engine(s).removeAllCopies(in: [])
        #expect(report == ApplyReport())
        #expect(await s.appliedActions.isEmpty)
    }

    @Test func removeAllCopiesApplyFailureGivesFixedFailure() async {
        let marker = Marker.make(for: ev("cal-a", "1"))!
        let s = store([ev("cal-b", "c1", marker: marker)])
        await s.setApplyError(CalendarStoreError.commitFailed)
        let report = await engine(s).removeAllCopies(in: [b])
        #expect(report == ApplyReport(failures: ["Saving to Calendar failed"]))
    }
}
