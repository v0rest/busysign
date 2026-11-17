import Foundation
import os
import Testing
@testable import BusySignCore

/// `SyncEngine.preview` works a change out as a dry run would and changes nothing; `SyncInputs` counts changes.
@Suite struct PreviewTests {
    let a = CalendarRef(id: "cal-a")
    let b = CalendarRef(id: "cal-b")
    let c = CalendarRef(id: "cal-c")
    let now: Date = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)).addingTimeInterval(10 * 3600)
    typealias Run = (result: SyncResult, tracker: ChangeTracker)

    /// An event `hours` after `now`, one hour long; a copy when `marker` is set.
    func ev(_ cal: String, _ id: String, hours: Double = 2, marker: String? = nil,
            title: String? = nil) -> EventSnapshot {
        let start = now.addingTimeInterval(hours * 3600)
        var event = snap(calendar: cal, localID: id, externalID: marker == nil ? "ext-\(id)" : nil,
                         occurrenceDate: start, start: start, end: start.addingTimeInterval(3600), marker: marker)
        event.title = title
        return event
    }
    func marker(_ original: EventSnapshot) -> String { Marker.make(for: original)! }
    func store(_ events: [EventSnapshot] = [], cals: [String] = ["cal-a", "cal-b"]) -> FakeCalendarStore {
        FakeCalendarStore(calendars: cals.map { FakeCalendarStore.calendar($0) }, events: events)
    }
    func engine(_ s: FakeCalendarStore) -> SyncEngine { let n = now; return SyncEngine(store: s, now: { n }) }
    /// Engine with a movable clock; returns a function that sets the clock to `now + offset`.
    func clockedEngine(_ s: FakeCalendarStore) -> (SyncEngine, @Sendable (TimeInterval) -> Void) {
        let base = now
        let clock = OSAllocatedUnfairLock(initialState: base)
        let e = SyncEngine(store: s, now: { clock.withLock { $0 } }, emptyReadHold: 300)
        return (e, { offset in clock.withLock { $0 = base.addingTimeInterval(offset) } })
    }
    func run(_ e: SyncEngine, mode: SyncMode = .live, settings: SyncSettings,
             tracker: ChangeTracker = ChangeTracker()) async -> Run {
        await e.runOnce(settings: settings, mode: mode, tracker: tracker, staleThreshold: 86400)
    }
    /// What `dry` plans, as a preview reports it.
    func counts(of dry: SyncResult) -> (add: Int, remove: Int, retitle: Int) {
        (dry.plannedCounts.add, dry.plannedCounts.remove, dry.plannedRetitles)
    }
    func counts(of preview: ChangePreview) -> (add: Int, remove: Int, retitle: Int) {
        (preview.add, preview.remove, preview.retitle)
    }

    /// cal-a's meetings show their title in cal-b, over a three-day look-ahead.
    var titleSettings: SyncSettings {
        SyncSettings(selected: [a, b], lookAheadDays: 3, copyTitleFormats: [CopyRoute(source: a, target: b): .title])
    }

    // MARK: - Preview

    /// A create, a move, a retitle and a delete: the preview counts what a dry run of the same settings plans, in
    /// the same window, and holds the same retitles a live run left not sticking (`titlesSent`).
    @Test func previewMatchesDryRun() async {
        let moved = ev("cal-a", "1", hours: 4)
        let retitled = ev("cal-a", "2", hours: 6, title: "Weekly sync")
        let added = ev("cal-a", "3", hours: 8)
        let gone = ev("cal-a", "gone", hours: 10)
        // Past the three-day look-ahead: neither the run nor the preview adds it.
        let later = ev("cal-a", "later", hours: 5 * 24)
        let s = store([moved, retitled, added, later,
                       ev("cal-b", "c1", hours: 2, marker: marker(moved)),
                       ev("cal-b", "c2", hours: 6, marker: marker(retitled), title: "Old name"),
                       ev("cal-b", "c4", hours: 10, marker: marker(gone))])
        let e = engine(s)
        let preview = await e.preview(settings: titleSettings, dropping: [])
        let dry = await run(e, mode: .dryRun, settings: titleSettings)
        #expect(dry.result.changes.map(\.kind) == [.move, .retitle, .add, .remove])
        #expect(counts(of: preview) == counts(of: dry.result))
        #expect(counts(of: preview) == (add: 1, remove: 1, retitle: 1))
        #expect(preview == ChangePreview(add: 1, remove: 1, retitle: 1))

        // A server that rewrites titles: once a live run sent the title, the dry run holds the retitle, and so
        // does the preview.
        let original = ev("cal-a", "1", title: "Weekly sync")
        let rewriting = store([original, ev("cal-b", "c1", marker: marker(original), title: "Old name")])
        await rewriting.setRewritesTitles { "[EXT] " + $0 }
        let held = engine(rewriting)
        #expect(await run(held, settings: titleSettings).result.report == ApplyReport(replaced: 1))
        let heldPreview = await held.preview(settings: titleSettings, dropping: [])
        let heldDry = await run(held, mode: .dryRun, settings: titleSettings)
        #expect(heldDry.result.retitlesNotSticking == 1)
        #expect(counts(of: heldPreview) == counts(of: heldDry.result))
        #expect(heldPreview == ChangePreview())
    }

    /// Empty-read guard memory, the change tracker and the calendars stay as they were: the runs after a preview
    /// plan what they plan without it, whatever the preview read.
    @Test func previewChangesNothing() async {
        // A preview that reads a calendar the runs never read does not record its events: once that calendar
        // is emptied, the run that first reads it goes ahead.
        let unread = await withAndWithoutPreview(cals: ["cal-a", "cal-b", "cal-c"]) { s, e, setClock, previewing in
            _ = await run(e, settings: SyncSettings(selected: [a, b]))
            if previewing {
                let preview = await e.preview(settings: SyncSettings(selected: [a, c]), dropping: [b])
                #expect(preview.skippedReason == nil)
                #expect(preview.add == 2)
            }
            await s.removeAllEvents(in: c)
            setClock(10)
            return await run(e, settings: SyncSettings(selected: [a, c]))
        }
        #expect(unread.control.result.skippedReason == nil)
        #expect(unread.control.result.planned.count == 2)

        // An empty read during the preview does not arm the guard: the run five minutes later arms it and skips.
        // The preview plans past the hold (`heldPreviewStillCounts`).
        let empty = await withAndWithoutPreview { s, e, setClock, previewing in
            _ = await run(e, settings: SyncSettings(selected: [a, b]))
            await s.removeAllEvents(in: a)
            if previewing {
                setClock(60)
                let preview = await e.preview(settings: SyncSettings(selected: [a, b]), dropping: [])
                #expect(preview == ChangePreview(add: 1, remove: 1, heldReason: SyncEngine.emptyRead,
                                                 heldCalendars: [a]))
            }
            setClock(360)
            return await run(e, settings: SyncSettings(selected: [a, b]))
        }
        #expect(empty.control.result.skippedReason == SyncEngine.emptyRead)

        // A non-zero read during the preview does not disarm it: once the hold has passed, the run accepts the
        // empty read it armed for.
        let armed = await withAndWithoutPreview { s, e, setClock, previewing in
            _ = await run(e, settings: SyncSettings(selected: [a, b]))
            await s.removeAllEvents(in: a)
            setClock(10)
            #expect(await run(e, settings: SyncSettings(selected: [a, b])).result.skippedReason == SyncEngine.emptyRead)
            if previewing {
                await s.addEvents([ev("cal-a", "1")])
                setClock(20)
                #expect(await e.preview(settings: SyncSettings(selected: [a, b]), dropping: []).skippedReason == nil)
                await s.removeAllEvents(in: a)
            }
            setClock(310)
            return await run(e, settings: SyncSettings(selected: [a, b]))
        }
        #expect(armed.control.result.skippedReason == nil)
        #expect(armed.control.result.emptiedCalendars == [a])
    }

    /// The empty-read hold: the preview plans past it, what the run once the hold has passed does, and says so in
    /// `heldReason` instead of skipping, so Apply has counts; it still never arms the guard.
    @Test func heldPreviewStillCounts() async {
        let two = SyncSettings(selected: [a, b])

        // Armed by a run: the preview counts what a dry run once the hold has passed plans.
        let s = store([ev("cal-a", "1"), ev("cal-b", "2", hours: 5)])
        let (e, setClock) = clockedEngine(s)
        #expect(await run(e, settings: two).result.report == ApplyReport(created: 2))
        await s.removeAllEvents(in: a)
        setClock(10)
        #expect(await run(e, settings: two).result.skippedReason == SyncEngine.emptyRead)
        setClock(20)
        let held = await e.preview(settings: two, dropping: [])
        #expect(held.skippedReason == nil)
        #expect(held.heldReason == SyncEngine.emptyRead)
        #expect(held.heldCalendars == [a])
        setClock(310)
        let released = await run(e, mode: .dryRun, settings: two)
        #expect(released.result.skippedReason == nil)
        #expect(released.result.emptiedCalendars == [a])
        #expect(counts(of: held) == counts(of: released.result))
        // cal-a's meeting is gone from cal-b, cal-b's goes back into cal-a.
        #expect(counts(of: held) == (add: 1, remove: 1, retitle: 0))

        // Not armed yet: the same counts, and the guard is left to the next run, which arms it then: five minutes
        // after the preview it still holds, which it would not had the preview armed it.
        let s2 = store([ev("cal-a", "1"), ev("cal-b", "2", hours: 5)])
        let (e2, setClock2) = clockedEngine(s2)
        #expect(await run(e2, settings: two).result.report == ApplyReport(created: 2))
        await s2.removeAllEvents(in: a)
        setClock2(10)
        let unarmed = await e2.preview(settings: two, dropping: [])
        #expect(unarmed == ChangePreview(add: 1, remove: 1, heldReason: SyncEngine.emptyRead, heldCalendars: [a]))
        setClock2(20)
        #expect(await run(e2, settings: two).result.skippedReason == SyncEngine.emptyRead)
        setClock2(315)
        #expect(await run(e2, mode: .dryRun, settings: two).result.skippedReason == SyncEngine.emptyRead)
        setClock2(320)
        let releasedLater = await run(e2, mode: .dryRun, settings: two)
        #expect(releasedLater.result.skippedReason == nil)
        #expect(counts(of: unarmed) == counts(of: releasedLater.result))
        // The preview wrote nothing.
        #expect(await s2.appliedActions.count == 1)
    }

    /// `heldCalendars` lists the calendars the guard holds now, not one whose hold has passed already; the counts
    /// are those of the run once both are accepted.
    @Test func heldCalendarsAreTheOnesHeldNow() async {
        let three = SyncSettings(selected: [a, b, c])
        let s = store([ev("cal-a", "1"), ev("cal-b", "2", hours: 5), ev("cal-c", "3", hours: 7)],
                      cals: ["cal-a", "cal-b", "cal-c"])
        let (e, setClock) = clockedEngine(s)
        #expect(await run(e, settings: three).result.report == ApplyReport(created: 6))
        await s.removeAllEvents(in: a)
        setClock(10)
        #expect(await run(e, settings: three).result.skippedReason == SyncEngine.emptyRead)
        await s.removeAllEvents(in: c)
        setClock(400)
        let held = await e.preview(settings: three, dropping: [])
        #expect(held.heldReason == SyncEngine.emptyRead)
        #expect(held.heldCalendars == [c])
        // The run now arms cal-c; five minutes on, both empty reads are accepted.
        #expect(await run(e, mode: .dryRun, settings: three).result.skippedReason == SyncEngine.emptyRead)
        setClock(700)
        let released = await run(e, mode: .dryRun, settings: three)
        #expect(released.result.emptiedCalendars == [a, c])
        #expect(counts(of: held) == counts(of: released.result))
        // Not held: no held calendars.
        #expect(await e.preview(settings: three, dropping: []).heldCalendars == [])
    }

    /// The preview's own wait (Ruling 18): a calendar a preview has seen held for the empty-read hold (300 s) counts
    /// as emptied, as a run's does after its own wait: plain counts, the same as while held. Neither preview arms
    /// the runs' guard.
    @Test func heldPreviewClearsAfterTheWait() async {
        let two = SyncSettings(selected: [a, b])
        let s = store([ev("cal-a", "1"), ev("cal-b", "2", hours: 5)])
        let (e, setClock) = clockedEngine(s)
        #expect(await run(e, settings: two).result.report == ApplyReport(created: 2))
        await s.removeAllEvents(in: a)
        setClock(10)
        let first = await e.preview(settings: two, dropping: [])
        #expect(first == ChangePreview(add: 1, remove: 1, heldReason: SyncEngine.emptyRead, heldCalendars: [a]))
        setClock(311)
        let second = await e.preview(settings: two, dropping: [])
        #expect(second == ChangePreview(add: 1, remove: 1))
        #expect(counts(of: second) == counts(of: first))
        // The run arms the guard now and holds; 295 s later it still holds, which it would not had either preview
        // armed it (305 s and 604 s before).
        setClock(320)
        #expect(await run(e, settings: two).result.skippedReason == SyncEngine.emptyRead)
        setClock(615)
        #expect(await run(e, settings: two).result.skippedReason == SyncEngine.emptyRead)
        #expect(await s.appliedActions.count == 1)
    }

    /// A preview that reads the calendar non-empty forgets when it was first seen held: once it is empty again, the
    /// wait starts over.
    @Test func heldPreviewClearsWhenEventsReturn() async {
        let two = SyncSettings(selected: [a, b])
        let s = store([ev("cal-a", "1"), ev("cal-b", "2", hours: 5)])
        let (e, setClock) = clockedEngine(s)
        #expect(await run(e, settings: two).result.report == ApplyReport(created: 2))
        await s.removeAllEvents(in: a)
        setClock(10)
        #expect(await e.preview(settings: two, dropping: []).heldCalendars == [a])
        await s.addEvents([ev("cal-a", "1")])
        setClock(20)
        // Back: plain counts at once, cal-b's meeting goes back into cal-a.
        #expect(await e.preview(settings: two, dropping: []) == ChangePreview(add: 1))
        await s.removeAllEvents(in: a)
        setClock(30)
        #expect(await e.preview(settings: two, dropping: []).heldCalendars == [a])
        // 301 s after the first sighting, but 281 s after the wait started over.
        setClock(311)
        #expect(await e.preview(settings: two, dropping: []).heldCalendars == [a])
        setClock(331)
        #expect(await e.preview(settings: two, dropping: []).heldReason == nil)
    }

    /// Once nothing is staged the app has the engine forget the previews' sightings, so the next staged change waits
    /// out a hold of its own instead of taking an old sighting.
    @Test func forgottenPreviewHoldsStartOver() async {
        let two = SyncSettings(selected: [a, b])
        let s = store([ev("cal-a", "1"), ev("cal-b", "2", hours: 5)])
        let (e, setClock) = clockedEngine(s)
        #expect(await run(e, settings: two).result.report == ApplyReport(created: 2))
        await s.removeAllEvents(in: a)
        setClock(10)
        #expect(await e.preview(settings: two, dropping: []).heldCalendars == [a])
        await e.forgetPreviewHolds()
        setClock(311)
        #expect(await e.preview(settings: two, dropping: []).heldCalendars == [a])
        setClock(612)
        #expect(await e.preview(settings: two, dropping: []).heldReason == nil)
    }

    /// A preview that does not read a calendar forgets its sighting: unticked in the staged change and ticked again,
    /// it waits out a hold of its own instead of taking the old sighting.
    @Test func unreadCalendarSightingIsForgotten() async {
        let three = SyncSettings(selected: [a, b, c])
        let s = store([ev("cal-a", "1"), ev("cal-b", "2", hours: 5), ev("cal-c", "3", hours: 7)],
                      cals: ["cal-a", "cal-b", "cal-c"])
        let (e, setClock) = clockedEngine(s)
        #expect(await run(e, settings: three).result.report == ApplyReport(created: 6))
        await s.removeAllEvents(in: a)
        setClock(10)
        #expect(await e.preview(settings: three, dropping: []).heldCalendars == [a])
        // cal-a unticked in the staged change: this preview does not read it.
        setClock(20)
        #expect(await e.preview(settings: SyncSettings(selected: [b, c]), dropping: [a]).heldReason == nil)
        // Ticked again, 390 s after the first sighting: held, the wait starts over.
        setClock(400)
        #expect(await e.preview(settings: three, dropping: []).heldCalendars == [a])
        setClock(701)
        #expect(await e.preview(settings: three, dropping: []).heldReason == nil)
    }

    /// A skipped preview reads nothing and forgets every sighting: the next one waits out a hold of its own.
    @Test func skippedPreviewRestartsTheWait() async {
        let two = SyncSettings(selected: [a, b])
        let s = store([ev("cal-a", "1"), ev("cal-b", "2", hours: 5)])
        let (e, setClock) = clockedEngine(s)
        #expect(await run(e, settings: two).result.report == ApplyReport(created: 2))
        await s.removeAllEvents(in: a)
        setClock(10)
        #expect(await e.preview(settings: two, dropping: []).heldCalendars == [a])
        await s.setAccess(.denied)
        setClock(20)
        #expect(await e.preview(settings: two, dropping: []).skippedReason == SyncEngine.accessNeeded)
        await s.setAccess(.granted)
        setClock(311)
        #expect(await e.preview(settings: two, dropping: []).heldCalendars == [a])
        setClock(612)
        #expect(await e.preview(settings: two, dropping: []).heldReason == nil)
    }

    /// A staged look-ahead shorter than the applied one: a calendar with no meeting of its own in the shorter window
    /// holds the preview, while the runs of the longer window read its meeting and go ahead. The hold is the shorter
    /// window's false alarm, so the held preview is applicable at once (Ruling 18).
    @Test func shorterLookAheadHoldIsApplicable() async {
        let applied = SyncSettings(selected: [a, b], lookAheadDays: 30)
        let staged = SyncSettings(selected: [a, b], lookAheadDays: 3)
        let s = store([ev("cal-a", "1", hours: 5 * 24), ev("cal-b", "2", hours: 5)])
        let (e, setClock) = clockedEngine(s)
        #expect(await run(e, settings: applied).result.skippedReason == nil)
        setClock(10)
        let held = await e.preview(settings: staged, dropping: [])
        #expect(held.heldCalendars == [a])
        setClock(20)
        #expect(await run(e, settings: applied).result.skippedReason == nil)
        #expect(heldPreviewIsApplicable(stagedLookAheadDays: staged.lookAheadDays,
                                        appliedLookAheadDays: applied.lookAheadDays))
    }

    // MARK: - Ruling 18

    /// A held preview is applicable at once only when the staged look-ahead is shorter than the applied one.
    @Test func heldPreviewIsApplicableOnlyForAShorterLookAhead() {
        #expect(heldPreviewIsApplicable(stagedLookAheadDays: 3, appliedLookAheadDays: 30))
        #expect(heldPreviewIsApplicable(stagedLookAheadDays: 29, appliedLookAheadDays: 30))
        #expect(!heldPreviewIsApplicable(stagedLookAheadDays: 30, appliedLookAheadDays: 30))
        #expect(!heldPreviewIsApplicable(stagedLookAheadDays: 90, appliedLookAheadDays: 30))
    }

    /// A preview that cannot be applied is worked out again every 10 s for the first minute, then every 60 s.
    @Test func retryDelayBacksOff() {
        #expect(ChangePreview.retryDelay(sinceFirstUnusable: 0) == 10)
        #expect(ChangePreview.retryDelay(sinceFirstUnusable: 50) == 10)
        #expect(ChangePreview.retryDelay(sinceFirstUnusable: 59.9) == 10)
        #expect(ChangePreview.retryDelay(sinceFirstUnusable: 60) == 60)
        #expect(ChangePreview.retryDelay(sinceFirstUnusable: 3600) == 60)
    }

    /// Runs `scenario` on a fresh store (cal-a and cal-b each with one meeting, cal-c too when listed) and
    /// engine, once without the preview and once with it, checks that the preview wrote nothing to the calendars,
    /// and that the run `scenario` returns plans the same both times.
    func withAndWithoutPreview(
        cals: [String] = ["cal-a", "cal-b"],
        _ scenario: (FakeCalendarStore, SyncEngine, @Sendable (TimeInterval) -> Void, Bool) async -> Run
    ) async -> (control: Run, previewed: Run) {
        var outcomes: [Run] = []
        var applied: [[[SyncAction]]] = []
        for previewing in [false, true] {
            let events = [ev("cal-a", "1"), ev("cal-b", "2", hours: 5), ev("cal-c", "3", hours: 7)]
                .filter { cals.contains($0.calendar.id) }
            let s = store(events, cals: cals)
            let (e, setClock) = clockedEngine(s)
            outcomes.append(await scenario(s, e, setClock, previewing))
            applied.append(await s.appliedActions)
        }
        #expect(outcomes[1].result == outcomes[0].result)
        #expect(outcomes[1].tracker == outcomes[0].tracker)
        #expect(applied[1] == applied[0])
        return (outcomes[0], outcomes[1])
    }

    /// Unticking cal-c with two calendars left: the preview counts the Busy copies in cal-c from today to +400
    /// days, beyond the look-ahead too, whatever the plan of the rest says; a calendar Calendar no longer lists has
    /// nothing to count.
    @Test func previewCountsRemovalsFromDroppedCalendars() async {
        let s = store([ev("cal-a", "1"), ev("cal-b", "2", hours: 5), ev("cal-c", "3", hours: 7)],
                      cals: ["cal-a", "cal-b", "cal-c"])
        let e = engine(s)
        #expect(await run(e, settings: SyncSettings(selected: [a, b, c])).result.report == ApplyReport(created: 6))
        let gone = ev("cal-a", "gone", hours: 100 * 24)
        // A copy at +100 days counts; one at +450 days is outside the window.
        await s.addEvents([ev("cal-c", "far", hours: 100 * 24, marker: marker(gone)),
                           ev("cal-c", "farther", hours: 450 * 24, marker: marker(ev("cal-a", "x", hours: 450 * 24)))])
        let appliedBefore = await s.appliedActions

        let two = SyncSettings(selected: [a, b])
        let preview = await e.preview(settings: two, dropping: [c, CalendarRef(id: "cal-gone")])
        let dry = await run(e, mode: .dryRun, settings: two)
        #expect(preview.removals == [c: 3])
        #expect(!preview.syncingStops)
        #expect(preview.skippedReason == nil)
        #expect(counts(of: preview) == counts(of: dry.result))
        #expect(counts(of: preview) == (add: 0, remove: 2, retitle: 0))

        // The plan skips (a selected calendar is missing); the copies Apply would remove are counted all the same.
        let skipped = await e.preview(settings: SyncSettings(selected: [a, CalendarRef(id: "cal-gone")]), dropping: [c])
        #expect(skipped == ChangePreview(removals: [c: 3], skippedReason: SyncEngine.missing))
        #expect(await s.appliedActions == appliedBefore)
    }

    /// Unticking cal-b leaves one calendar: syncing stops, nothing is planned, and the copies in cal-b and in the
    /// calendar left are counted.
    @Test func previewOfOneCalendarCountsBothRemovals() async {
        let s = store([ev("cal-a", "1"), ev("cal-b", "2", hours: 5)])
        let e = engine(s)
        #expect(await run(e, settings: SyncSettings(selected: [a, b])).result.report == ApplyReport(created: 2))
        let appliedBefore = await s.appliedActions

        let preview = await e.preview(settings: SyncSettings(selected: [a]), dropping: [b])
        #expect(preview == ChangePreview(removals: [a: 1, b: 1], syncingStops: true))
        // Nothing left ticked.
        let none = await e.preview(settings: SyncSettings(selected: []), dropping: [a, b])
        #expect(none == ChangePreview(removals: [a: 1, b: 1], syncingStops: true))
        // Without access nothing can be counted.
        await s.setAccess(.denied)
        let denied = await e.preview(settings: SyncSettings(selected: [a]), dropping: [b])
        #expect(denied == ChangePreview(syncingStops: true, skippedReason: SyncEngine.accessNeeded))
        #expect(await s.appliedActions == appliedBefore)
    }

    /// cal-a → cal-b staged as Nothing: the preview removes cal-a's two Busy blocks in cal-b, and only them, as a dry
    /// run of the staged settings plans; cal-b's block in cal-a stays. The preview writes nothing, and once the change
    /// is applied the run after the one that removed the blocks plans nothing.
    @Test func previewOfNothingMatchesDryRun() async {
        let one = ev("cal-a", "1"), two = ev("cal-a", "2", hours: 4), fromB = ev("cal-b", "3", hours: 6)
        let s = store([one, two, fromB])
        let e = engine(s)
        let both = SyncSettings(selected: [a, b])
        #expect(await run(e, settings: both).result.report == ApplyReport(created: 3))
        let appliedBefore = await s.appliedActions

        let oneWay = SyncSettings(selected: [a, b], copyTitleFormats: [CopyRoute(source: a, target: b): .nothing])
        let preview = await e.preview(settings: oneWay, dropping: [])
        let dry = await run(e, mode: .dryRun, settings: oneWay)
        #expect(preview == ChangePreview(add: 0, remove: 2, retitle: 0))
        #expect(counts(of: preview) == counts(of: dry.result))
        #expect(dry.result.changes.map(\.kind) == [.remove, .remove])
        #expect(dry.result.changes.map(\.target) == [b, b])
        #expect(dry.result.changes.map(\.sourceLocalID) == [one.localID, two.localID])
        #expect(await s.appliedActions == appliedBefore)
        #expect(await run(e, mode: .dryRun, settings: both).result.planned.isEmpty)

        let live = await run(e, settings: oneWay)
        #expect(live.result.report == ApplyReport(deleted: 2))
        #expect(await run(e, settings: oneWay, tracker: live.tracker).result.planned.isEmpty)
        #expect(await e.preview(settings: oneWay, dropping: []) == ChangePreview())
    }

    /// The app counts the Busy blocks waiting for Live after every dry run (`countCopies`): the copies in each listed
    /// calendar from today to +400 days, as the preview counts the removals; none for a calendar Calendar does not
    /// list; the reason when they cannot be read. It writes nothing and leaves the previews' own wait alone, which a
    /// preview of the applied settings would not (one with fewer than two calendars forgets every sighting).
    @Test func countCopiesCountsWithoutTouchingPreviews() async {
        let two = SyncSettings(selected: [a, b])
        let s = store([ev("cal-a", "1"), ev("cal-b", "2", hours: 5), ev("cal-c", "3", hours: 7)],
                      cals: ["cal-a", "cal-b", "cal-c"])
        let (e, setClock) = clockedEngine(s)
        #expect(await run(e, settings: SyncSettings(selected: [a, b, c])).result.report == ApplyReport(created: 6))
        await s.addEvents([ev("cal-c", "far", hours: 100 * 24, marker: marker(ev("cal-a", "x", hours: 100 * 24))),
                           ev("cal-c", "farther", hours: 450 * 24, marker: marker(ev("cal-a", "y", hours: 450 * 24)))])
        let appliedBefore = await s.appliedActions

        let counted = await e.countCopies(in: [c, b, CalendarRef(id: "cal-gone")])
        #expect(counted.counts == [c: 3, b: 2])
        #expect(counted.failure == nil)
        #expect(await e.preview(settings: two, dropping: [c]).removals == [c: 3])
        #expect(await e.countCopies(in: []).counts == [:])

        // A staged preview's wait goes on across counts.
        await s.removeAllEvents(in: a)
        setClock(10)
        #expect(await e.preview(settings: two, dropping: []).heldCalendars == [a])
        setClock(100)
        #expect(await e.countCopies(in: [c]).counts == [c: 3])
        setClock(311)
        #expect(await e.preview(settings: two, dropping: []).heldReason == nil)

        await s.setAccess(.denied)
        let denied = await e.countCopies(in: [c])
        #expect(denied.counts == [:])
        #expect(denied.failure == SyncEngine.accessNeeded)
        #expect(await s.appliedActions == appliedBefore)
    }

    // MARK: - SyncInputs

    var inputs: SyncInputs {
        SyncInputs(selected: [a, b], lookAheadDays: 30, unansweredAsBusy: false, excluded: ["x1", "x2"],
                   hiddenTitleKeys: ["h1"], copyTitleFormats: [CopyRoute(source: a, target: b): .title],
                   calendarNames: ["cal-a": "Acme"])
    }

    @Test func changeCountZeroForEqualInputs() {
        #expect(inputs.changeCount(from: inputs) == 0)
        // The order of the ticked calendars is not a change, though the values differ.
        var reordered = inputs
        reordered.selected = [b, a]
        #expect(reordered != inputs)
        #expect(reordered.changeCount(from: inputs) == 0)
    }

    @Test func changeCountCountsEachDifference() {
        func count(_ change: (inout SyncInputs) -> Void) -> Int {
            var staged = inputs
            change(&staged)
            // Counted the same in either direction.
            #expect(inputs.changeCount(from: staged) == staged.changeCount(from: inputs))
            return staged.changeCount(from: inputs)
        }
        // Ticks: one per calendar ticked or unticked.
        #expect(count { $0.selected = [a, b, c] } == 1)
        #expect(count { $0.selected = [a] } == 1)
        #expect(count { $0.selected = [c, b] } == 2)
        #expect(count { $0.lookAheadDays = 90 } == 1)
        #expect(count { $0.unansweredAsBusy = true } == 1)
        // Keys: one per key added or removed.
        #expect(count { $0.excluded.insert("x3") } == 1)
        #expect(count { $0.excluded = ["x3"] } == 3)
        #expect(count { $0.hiddenTitleKeys = [] } == 1)
        #expect(count { $0.hiddenTitleKeys = ["h2"] } == 2)
        // Routes and names: one per entry added, removed or changed.
        #expect(count { $0.copyTitleFormats[CopyRoute(source: b, target: a)] = .sourceAndTitle } == 1)
        #expect(count { $0.copyTitleFormats = [:] } == 1)
        #expect(count { $0.copyTitleFormats[CopyRoute(source: a, target: b)] = .busyOnly } == 1)
        #expect(count { $0.calendarNames["cal-b"] = "Initech" } == 1)
        #expect(count { $0.calendarNames = [:] } == 1)
        #expect(count { $0.calendarNames["cal-a"] = "Acme Corp" } == 1)
        // All at once: the sum.
        #expect(count {
            $0.selected = [a, c]
            $0.lookAheadDays = 7
            $0.unansweredAsBusy = true
            $0.excluded = ["x1"]
            $0.hiddenTitleKeys = ["h1", "h2"]
            $0.copyTitleFormats = [:]
            $0.calendarNames["cal-a"] = nil
        } == 2 + 1 + 1 + 1 + 1 + 1 + 1)
    }

    /// The settings a run gets: every input, the caller's source labels, and only the routes between the ticked
    /// calendars, as the app builds them today.
    @Test func settingsCarryTheInputs() {
        var staged = inputs
        staged.copyTitleFormats[CopyRoute(source: a, target: c)] = .title
        let labels = [a: "Acme", b: "Initech"]
        #expect(staged.settings(sourceLabels: labels) == SyncSettings(
            selected: [a, b], lookAheadDays: 30, unansweredAsBusy: false, excluded: ["x1", "x2"],
            copyTitleFormats: [CopyRoute(source: a, target: b): .title], sourceLabels: labels,
            hiddenTitleKeys: ["h1"]))
    }
}
