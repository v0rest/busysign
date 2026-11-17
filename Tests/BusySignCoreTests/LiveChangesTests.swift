import Foundation
import Testing
@testable import BusySignCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let window = DateInterval(start: t0 - 86_400, duration: 30 * 86_400)
private let A = CalendarRef(id: "A")
private let B = CalendarRef(id: "B")
private let C = CalendarRef(id: "C")

private func orig(_ cal: CalendarRef, _ ext: String, hours: Double) -> EventSnapshot {
    let start = t0 + hours * 3600
    return EventSnapshot(calendar: cal, localID: "\(cal.id)-\(ext)", externalID: ext, occurrenceDate: start,
                         isRecurringOccurrence: false, start: start, end: start + 3600, isAllDay: false,
                         availability: .busy, myResponse: .accepted, marker: nil)
}

/// Calendar for the live runs below: its events, the selected calendars, and the creates it refuses (by start,
/// in any target or in `refusedTarget` only).
private struct World {
    var events: [EventSnapshot]
    var selected = [A, B]
    var refusedStarts: Set<Date> = []
    var refusedTarget: CalendarRef?
    var clock = t0
    var made = 0

    /// One live run, the way `SyncEngine.runOnce` reports it: the plan, its changes and what was saved.
    mutating func liveRun() -> SyncResult {
        clock += 60
        let settings = SyncSettings(selected: selected)
        let inScope = events.filter { selected.contains($0.calendar) }
        let planned = reconcile(events: inScope, settings: settings, window: window)
        var result = SyncResult(at: clock, mode: .live, planned: planned,
                                changes: plannedChanges(for: planned, events: inScope, settings: settings,
                                                        window: window),
                                notBusy: notBusyOriginals(events: inScope, settings: settings, window: window),
                                mirroredItems: mirroredItems(events: inScope, settings: settings, window: window))
        var report = ApplyReport()
        for action in replacingUpdates(planned) {
            switch action {
            case let .create(spec):
                guard make(spec) else {
                    report.failures.append("refused")
                    continue
                }
                report.created += 1
            case let .replace(localID, spec):
                guard make(spec) else {
                    report.failures.append("refused")
                    continue
                }
                events.removeAll { $0.localID == localID && $0.calendar == spec.target }
                report.replaced += 1
            case let .update(localID, spec):
                if let i = events.firstIndex(where: { $0.localID == localID }) {
                    events[i].start = spec.start
                    events[i].end = spec.end
                }
                report.updated += 1
            case let .delete(localID, target):
                events.removeAll { $0.localID == localID && $0.calendar == target }
                report.deleted += 1
            }
        }
        result.report = report
        return result
    }

    /// Creates the copy `spec` unless the calendar refuses it; true when it was made.
    private mutating func make(_ spec: CopySpec) -> Bool {
        if refusedStarts.contains(spec.start) && (refusedTarget.map { $0 == spec.target } ?? true) { return false }
        made += 1
        events.append(EventSnapshot(calendar: spec.target, localID: "copy-\(made)", externalID: nil,
                                    occurrenceDate: spec.start, isRecurringOccurrence: false,
                                    start: spec.start, end: spec.end, isAllDay: spec.isAllDay,
                                    availability: .busy, myResponse: .none, marker: spec.marker))
        return true
    }

    /// Unticking `calendar`: the app removes the Busy copies in it, and later runs leave it out.
    mutating func untick(_ calendar: CalendarRef) {
        selected.removeAll { $0 == calendar }
        events.removeAll { $0.calendar == calendar && $0.marker != nil }
    }
}

/// What the app does after each run: keep the live changes and build the window from them.
private struct Window {
    var live = LiveChanges()
    var catalog: MeetingsCatalog?

    mutating func land(_ result: SyncResult, selected: [CalendarRef] = [A, B]) {
        live = live.updated(after: result, selected: selected)
        catalog = meetingsCatalog(result: result, selected: selected, excluded: [], lastLiveChanges: live.changes)
    }

    var removedBlocks: Int { catalog?.removals.reduce(0) { $0 + $1.count } ?? 0 }

    func label(_ localID: String) -> MeetingsCatalog.Label? {
        catalog?.sections.flatMap(\.rows).flatMap(\.occurrences).first { $0.localID == localID }?.label
    }
}

/// Critic scenario S2: mirrored m1, m2, m3 and b1; then the organiser cancels m2 and m3 while a new meeting n1
/// arrives whose copy Calendar refuses. Returns the world and the window after that run (run k).
private func failedRunWithTwoRemovals() -> (World, Window, Date) {
    var world = World(events: [orig(A, "m1", hours: 0), orig(A, "m2", hours: 2), orig(A, "m3", hours: 4),
                               orig(B, "b1", hours: 6)])
    var window = Window()
    window.land(world.liveRun())
    window.land(world.liveRun())
    world.events.removeAll { $0.localID == "A-m2" || $0.localID == "A-m3" }
    world.events.append(orig(A, "n1", hours: 8))
    world.refusedStarts = [t0 + 8 * 3600]
    let runK = world.liveRun()
    window.land(runK)
    return (world, window, runK.at)
}

@Test func failedRunShowsItsRemovals() {
    let (_, window, at) = failedRunWithTwoRemovals()
    #expect(window.removedBlocks == 2)
    #expect(window.label("A-n1") == .added)
    #expect(window.live.at == at)
    #expect(window.live.hadFailures)
}

@Test func removalsOfAFailedRunSurviveItsRetries() {
    var (world, window, at) = failedRunWithTwoRemovals()
    // The retry ~10 s later (our own writes changed the store) and the next timer run refuse n1 again.
    for _ in 0..<2 {
        window.land(world.liveRun())
        #expect(window.removedBlocks == 2)
        #expect(window.label("A-n1") == .added)
        // Nothing was saved, so "Last changes" stays at run k.
        #expect(window.live.at == at)
        #expect(window.live.hadFailures)
    }
}

@Test func cleanRetryMergesThenTheNextChangeReplaces() {
    var (world, window, _) = failedRunWithTwoRemovals()
    world.refusedStarts = []
    let retry = world.liveRun()
    window.land(retry)
    // The retry saves n1: its change joins those of the failed run, whose removals stay listed.
    #expect(window.removedBlocks == 2)
    #expect(window.label("A-n1") == .added)
    #expect(window.live.at == retry.at)
    #expect(!window.live.hadFailures)
    // The empty run after our own writes keeps everything.
    window.land(world.liveRun())
    #expect(window.removedBlocks == 2)
    #expect(window.live.at == retry.at)
    // A later run that changes something, without failures, replaces the labels as before.
    world.events.append(orig(B, "b2", hours: 10))
    let next = world.liveRun()
    window.land(next)
    #expect(window.removedBlocks == 0)
    #expect(window.label("B-b2") == .added)
    #expect(window.label("A-n1") == nil)
    #expect(window.live.at == next.at)
}

@Test func cleanRunWithoutChangesChangesNothing() {
    var (world, window, _) = failedRunWithTwoRemovals()
    // The organiser cancels n1 as well: nothing is left to retry, so the next run plans nothing.
    world.events.removeAll { $0.localID == "A-n1" }
    let before = window.live
    let empty = world.liveRun()
    #expect(empty.changes.isEmpty)
    window.land(empty)
    #expect(window.live == before)
    #expect(window.removedBlocks == 2)
    // The next clean run that changes something is the first clean one after the failures: it merges.
    world.events.append(orig(B, "b2", hours: 10))
    let first = world.liveRun()
    window.land(first)
    #expect(window.removedBlocks == 2)
    #expect(window.label("B-b2") == .added)
    #expect(window.live.at == first.at)
    #expect(!window.live.hadFailures)
    // The one after it replaces.
    world.events.append(orig(B, "b3", hours: 12))
    window.land(world.liveRun())
    #expect(window.removedBlocks == 0)
    #expect(window.label("B-b2") == nil)
    #expect(window.label("B-b3") == .added)
}

@Test func runWithoutFailuresReplaces() {
    var world = World(events: [orig(A, "m1", hours: 0), orig(A, "m2", hours: 2), orig(B, "b1", hours: 6)])
    var window = Window()
    window.land(world.liveRun())
    world.events.removeAll { $0.localID == "A-m2" }
    let removal = world.liveRun()
    window.land(removal)
    #expect(window.removedBlocks == 1)
    #expect(window.label("A-m1") == nil)
    #expect(window.live.at == removal.at)
    #expect(!window.live.hadFailures)
}

@Test func aRunWithFailuresNeverCarriesOverTheCleanLabelsBeforeIt() {
    // The reviewer's trace: a clean run j, then a run k whose only change is refused, then the clean retry k+1.
    var world = World(events: [orig(A, "m1", hours: 0), orig(B, "b1", hours: 6)])
    var window = Window()
    let runJ = world.liveRun()
    window.land(runJ)
    #expect(window.label("A-m1") == .added)
    world.events.append(orig(A, "n1", hours: 8))
    world.refusedStarts = [t0 + 8 * 3600]
    window.land(world.liveRun())
    // Run k starts the failure streak with its own changes; it saved nothing, so the time stays at j.
    #expect(window.label("A-m1") == nil)
    #expect(window.label("B-b1") == nil)
    #expect(window.label("A-n1") == .added)
    #expect(window.live.at == runJ.at)
    #expect(window.live.hadFailures)
    world.refusedStarts = []
    let retry = world.liveRun()
    window.land(retry)
    // j's labels do not come back with the merge of the clean retry.
    #expect(window.label("A-m1") == nil)
    #expect(window.label("B-b1") == nil)
    #expect(window.label("A-n1") == .added)
    #expect(window.live.at == retry.at)
    #expect(!window.live.hadFailures)
}

@Test func aPersistentRefusalNeverBringsBackLabelsFromBeforeIt() {
    var world = World(events: [orig(A, "m1", hours: 0), orig(A, "m2", hours: 2), orig(B, "b1", hours: 6)])
    var window = Window()
    window.land(world.liveRun())
    window.land(world.liveRun())
    // m2 is cancelled in a clean run: its removal is listed until the next change.
    world.events.removeAll { $0.localID == "A-m2" }
    window.land(world.liveRun())
    #expect(window.removedBlocks == 1)
    // n1 arrives and its copy is refused on every run from now on.
    world.events.append(orig(A, "n1", hours: 8))
    world.refusedStarts = [t0 + 8 * 3600]
    window.land(world.liveRun())
    #expect(window.removedBlocks == 0)
    // Three more runs that change something, each still refusing n1: their changes join the streak's set, while
    // the removal of m2 from before the streak never comes back.
    var lastSaved: Date?
    for edit in 0..<3 {
        switch edit {
        case 0: world.events.append(orig(B, "x1", hours: 10))
        case 1: world.events.append(orig(A, "x2", hours: 12))
        default: world.events.removeAll { $0.localID == "A-m1" }
        }
        let run = world.liveRun()
        lastSaved = run.at
        window.land(run)
        #expect(window.label("A-n1") == .added)
        #expect(window.live.hadFailures)
        #expect(window.live.at == run.at)
    }
    #expect(window.label("B-x1") == .added)
    #expect(window.label("A-x2") == .added)
    #expect(window.label("B-b1") == nil)
    // Only m1's removal is listed; m2's was before the streak.
    #expect(window.removedBlocks == 1)
    #expect(window.live.at == lastSaved)
}

@Test func aCalendarUntickedDuringAStreakTakesItsEntriesAlong() {
    // a1 and b1 mirrored between A and B; C is ticked, and the run that adds it refuses c1's copy into B.
    var world = World(events: [orig(A, "a1", hours: 0), orig(B, "b1", hours: 2), orig(C, "c1", hours: 4)])
    var window = Window()
    window.land(world.liveRun())
    window.land(world.liveRun())
    world.selected = [A, B, C]
    world.refusedStarts = [t0 + 4 * 3600]
    world.refusedTarget = B
    window.land(world.liveRun(), selected: [A, B, C])
    #expect(window.live.hadFailures)
    #expect(window.label("A-a1") == .added)
    // C is unticked: its copies go, and the next run removes c1's copy from A.
    world.untick(C)
    window.land(world.liveRun())
    // Nothing of the streak that targets C or comes from it stays: a1's copy into C is gone, so no "added".
    #expect(!window.live.changes.contains { $0.target == C || $0.source == C })
    #expect(window.label("A-a1") == nil)
    #expect(window.label("B-b1") == nil)
    #expect(window.removedBlocks == 1)
}

@Test func labelsOfAnUntickedCalendarGoEvenWithoutAnotherChange() {
    // Critic U1: A and B settled; C is ticked (it has no meetings), the run copies a1 into C and, in one variant,
    // refuses b1's copy into C; then C is unticked and the next run has nothing to do.
    for refused in [true, false] {
        var world = World(events: [orig(A, "a1", hours: 0), orig(B, "b1", hours: 2)])
        var window = Window()
        window.land(world.liveRun())
        window.land(world.liveRun())
        world.selected = [A, B, C]
        if refused {
            world.refusedStarts = [t0 + 2 * 3600]
            world.refusedTarget = C
        }
        window.land(world.liveRun(), selected: [A, B, C])
        #expect(window.label("A-a1") == .added)
        world.untick(C)
        let empty = world.liveRun()
        #expect(empty.changes.isEmpty)
        window.land(empty)
        // The only change a1 had was its copy into C, which is gone with C: no "added" any more.
        #expect(window.label("A-a1") == nil)
        #expect(window.label("B-b1") == nil)
        #expect(window.removedBlocks == 0)
    }
}

private func change(_ kind: PlannedChange.Kind, _ target: CalendarRef, hours: Double, key: String?) -> PlannedChange {
    PlannedChange(kind: kind, target: target, start: t0 + hours * 3600, end: t0 + hours * 3600 + 3600,
                  isAllDay: false, source: key == nil ? nil : A, sourceLocalID: key, occurrenceKey: key)
}

private func liveResult(_ changes: [PlannedChange], at: Date, saved: Int, failures: Int) -> SyncResult {
    SyncResult(at: at, mode: .live, report: ApplyReport(created: saved, failures: Array(repeating: "x", count: failures)),
               changes: changes)
}

@Test func mergeKeysByTargetAndOccurrenceKeyOrSlot() {
    let stored = LiveChanges(
        changes: [change(.add, B, hours: 1, key: "o:1"), change(.remove, B, hours: 2, key: nil),
                  change(.remove, B, hours: 2, key: nil), change(.add, A, hours: 1, key: "o:1")],
        at: t0, hadFailures: true)
    let newer = [change(.remove, B, hours: 1, key: "o:1"), change(.remove, B, hours: 3, key: nil)]
    let merged = stored.updated(after: liveResult(newer, at: t0 + 60, saved: 1, failures: 0), selected: [A, B])
    // The newer change of (B, o:1) replaces the older one; (A, o:1) and the slot removals of B stay.
    #expect(merged.changes == [change(.add, A, hours: 1, key: "o:1"), change(.remove, B, hours: 1, key: "o:1"),
                               change(.remove, B, hours: 2, key: nil), change(.remove, B, hours: 2, key: nil),
                               change(.remove, B, hours: 3, key: nil)])
    #expect(merged.at == t0 + 60)
    #expect(!merged.hadFailures)
    // A keyless removal of the same slot replaces both older ones.
    let again = stored.updated(after: liveResult([change(.remove, B, hours: 2, key: nil)], at: t0 + 60, saved: 1,
                                                 failures: 1), selected: [A, B])
    #expect(again.changes.filter { $0.start == t0 + 2 * 3600 }.count == 1)
    #expect(again.hadFailures)
}

@Test func onlyLiveRunsWithChangesCount() {
    let stored = LiveChanges(changes: [change(.add, B, hours: 1, key: "o:1")], at: t0, hadFailures: true)
    let other = [change(.add, B, hours: 3, key: "o:3")]
    #expect(stored.updated(after: SyncResult(at: t0 + 60, mode: .dryRun, changes: other), selected: [A, B]) == stored)
    #expect(stored.updated(after: SyncResult(at: t0 + 60, mode: .live, skippedReason: "x"), selected: [A, B]) == stored)
    // A clean live run with nothing to change changes nothing, in a failure streak too.
    let empty = liveResult([], at: t0 + 60, saved: 0, failures: 0)
    #expect(stored.updated(after: empty, selected: [A, B]) == stored)
    let clean = LiveChanges(changes: stored.changes, at: t0)
    #expect(clean.updated(after: empty, selected: [A, B]) == clean)
}

/// Retitles are not listed: a run with only retitles leaves the stored changes and `at` as they are, in a failure
/// streak too; a run with more lists the rest; a retitle that also removes duplicates stays.
@Test func pureRetitleIsNotListed() {
    let stored = LiveChanges(changes: [change(.add, B, hours: 1, key: "o:1")], at: t0)
    let retitles = [change(.retitle, B, hours: 2, key: "o:2"), change(.retitle, A, hours: 3, key: "o:3")]
    #expect(stored.updated(after: liveResult(retitles, at: t0 + 60, saved: 2, failures: 0), selected: [A, B]) == stored)
    let streak = LiveChanges(changes: stored.changes, at: t0, hadFailures: true)
    #expect(streak.updated(after: liveResult(retitles, at: t0 + 60, saved: 1, failures: 1), selected: [A, B]) == streak)

    let added = change(.add, B, hours: 4, key: "o:4")
    let mixed = stored.updated(after: liveResult(retitles + [added], at: t0 + 60, saved: 3, failures: 0),
                               selected: [A, B])
    #expect(mixed == LiveChanges(changes: [added], at: t0 + 60))

    var withDuplicates = change(.retitle, B, hours: 2, key: "o:2")
    withDuplicates.duplicatesRemoved = 1
    let deduplicated = stored.updated(after: liveResult([withDuplicates], at: t0 + 60, saved: 2, failures: 0),
                                      selected: [A, B])
    #expect(deduplicated == LiveChanges(changes: [withDuplicates], at: t0 + 60))
}

/// A move goes to the store as a replacement, so a run whose only write is one replacement saved something:
/// `at` moves to that run.
@Test func replaceOnlyRunCountsAsSaved() {
    let stored = LiveChanges(changes: [change(.add, B, hours: 1, key: "o:1")], at: t0)
    let moved = change(.move, B, hours: 2, key: "o:2")
    let result = SyncResult(at: t0 + 60, mode: .live, report: ApplyReport(replaced: 1), changes: [moved])
    #expect(stored.updated(after: result, selected: [A, B]) == LiveChanges(changes: [moved], at: t0 + 60))
}
