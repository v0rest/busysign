import Foundation
import Testing
@testable import BusySignCore

@Suite struct StatusTextTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let a = CalendarRef(id: "a")

    func spec() -> CopySpec { CopySpec(target: a, marker: "m", start: t0, end: t0, isAllDay: false) }
    func result(mode: SyncMode = .live, planned: [SyncAction] = [], reason: String? = nil) -> SyncResult {
        SyncResult(at: t0, mode: mode, planned: planned, skippedReason: reason)
    }
    func head(_ r: SyncResult?, paused: Bool = false, access: AccessState = .granted, after: TimeInterval = 0) -> String {
        StatusText.headline(r, paused: paused, access: access, now: t0.addingTimeInterval(after))
    }

    @Test func syncedMinutesAgo() { #expect(head(result(), after: 150) == "Synced 2 min ago") }
    @Test func syncedJustNow() { #expect(head(result(), after: 59) == "Synced just now") }
    @Test func syncedHours() { #expect(head(result(), after: 3 * 3600 + 1800) == "Synced 3 h ago") }
    @Test func notSyncedYet() { #expect(head(nil) == "Not synced yet") }
    @Test func dryRunSummary() {
        let planned: [SyncAction] = [.create(spec()), .create(spec()), .create(spec()),
                                     .delete(localID: "x", target: a), .update(localID: "y", spec())]
        #expect(head(result(mode: .dryRun, planned: planned)) == "Dry run: would add 3, remove 1")
    }
    @Test func dryRunHeadlineShowsRetitles() {
        let retitle = PlannedChange(kind: .retitle, target: a, start: t0, end: t0 + 3600, isAllDay: false)
        let move = PlannedChange(kind: .move, target: a, start: t0 + 7200, end: t0 + 10_800, isAllDay: false,
                                 previousStart: t0, previousEnd: t0 + 3600, previousIsAllDay: false)
        var r = SyncResult(at: t0, mode: .dryRun, planned: Array(repeating: .update(localID: "y", spec()), count: 2),
                           changes: [retitle, retitle])
        #expect(r.plannedRetitles == 2)
        #expect(head(r) == "Dry run: would add 0, remove 0, retitle 2")
        r.planned.append(.update(localID: "z", spec()))
        r.changes.append(move)
        #expect(head(r) == "Dry run: would add 0, remove 0, retitle 2")
        r.emptiedCalendars = [a]
        #expect(head(r) == "Dry run: would add 0, remove 0, retitle 2 (1 calendar shows no events)")
        #expect(result(mode: .dryRun).plannedRetitles == 0)
    }
    @Test func plannedCountsCountCreatesAndDeletes() {
        let planned: [SyncAction] = [.create(spec()), .create(spec()), .delete(localID: "x", target: a),
                                     .update(localID: "y", spec())]
        let counts = result(mode: .dryRun, planned: planned).plannedCounts
        #expect(counts.add == 2)
        #expect(counts.remove == 1)
        #expect(result().plannedCounts == (add: 0, remove: 0))
    }
    @Test func paused() { #expect(head(result(), paused: true) == "Paused") }
    @Test func accessNeeded() {
        #expect(head(result(), paused: true, access: .denied) == "Calendar access needed")
        #expect(head(nil, access: .notDetermined) == "Calendar access needed")
    }
    @Test func skipped() { #expect(head(result(reason: "Boom")) == "Not synced: Boom") }
    @Test func skippedBeatsDryRun() { #expect(head(result(mode: .dryRun, reason: "Boom")) == "Not synced: Boom") }

    @Test func failuresAppended() {
        let one = SyncResult(at: t0, mode: .live, report: ApplyReport(failures: ["x"]))
        let two = SyncResult(at: t0, mode: .live, report: ApplyReport(failures: ["x", "y"]))
        #expect(head(one, after: 150) == "Synced 2 min ago (1 change failed)")
        #expect(head(two, after: 150) == "Synced 2 min ago (2 changes failed)")
    }

    @Test func emptiedCalendarsAppended() {
        let b = CalendarRef(id: "b")
        let one = SyncResult(at: t0, mode: .live, report: ApplyReport(), emptiedCalendars: [a])
        let two = SyncResult(at: t0, mode: .live, report: ApplyReport(), emptiedCalendars: [a, b])
        #expect(head(one, after: 150) == "Synced 2 min ago (1 calendar shows no events)")
        #expect(head(two, after: 30) == "Synced just now (2 calendars show no events)")
        #expect(head(one, after: 2 * 3600) == "Synced 2 h ago (1 calendar shows no events)")
    }

    @Test func emptiedAfterFailures() {
        let r = SyncResult(at: t0, mode: .live, report: ApplyReport(failures: ["x"]), emptiedCalendars: [a])
        #expect(head(r, after: 150) == "Synced 2 min ago (1 change failed) (1 calendar shows no events)")
    }

    @Test func emptiedInDryRun() {
        let planned: [SyncAction] = [.create(spec()), .delete(localID: "x", target: a)]
        let r = SyncResult(at: t0, mode: .dryRun, planned: planned, emptiedCalendars: [a])
        #expect(head(r) == "Dry run: would add 1, remove 1 (1 calendar shows no events)")
    }

    @Test func skippedRunShowsNoEmptiedSuffix() {
        let r = SyncResult(at: t0, mode: .live, skippedReason: "Boom", emptiedCalendars: [a])
        #expect(head(r) == "Not synced: Boom")
    }

    @Test func quietNoteText() {
        #expect(StatusText.quietNote(thresholdHours: 168) == "No new events for a week")
        #expect(StatusText.quietNote(thresholdHours: 48) == "No new events for 2 days")
        #expect(StatusText.quietNote(thresholdHours: 24) == "No new events for a day")
        #expect(StatusText.quietNote(thresholdHours: 12) == "No new events for 12 h")
        #expect(StatusText.quietNote(thresholdHours: 336) == "No new events for 14 days")
        #expect(StatusText.quietNote(thresholdHours: 36.4) == "No new events for 36 h")
        // Written by hand; never "0 h".
        #expect(StatusText.quietNote(thresholdHours: 0.25) == "No new events for 1 h")
    }

    @Test func quietNoteHelp() {
        let week = "BusySign hasn't seen a new or changed event in this calendar for 7 days. "
            + "If you expected some, check the account in Calendar → Settings → Accounts."
        #expect(StatusText.quietNoteHelp(thresholdHours: 168) == week)
        #expect(StatusText.quietNoteHelp(thresholdHours: 48)
            == week.replacingOccurrences(of: "for 7 days", with: "for 2 days"))
        #expect(StatusText.quietNoteHelp(thresholdHours: 24)
            == week.replacingOccurrences(of: "for 7 days", with: "for a day"))
        #expect(StatusText.quietNoteHelp(thresholdHours: 12)
            == week.replacingOccurrences(of: "for 7 days", with: "for 12 h"))
    }

    // MARK: - Apply bar

    func bar(_ changes: Int, _ preview: ChangePreview?, workingOut: Bool = false,
             order: [CalendarRef] = [CalendarRef(id: "a"), CalendarRef(id: "b"), CalendarRef(id: "c")]) -> String {
        let names = ["a": "Acme", "b": "Initech", "c": "Globex"]
        return StatusText.applyBar(changes: changes, preview: preview, workingOut: workingOut, order: order,
                                   name: { names[$0.id] ?? $0.id })
    }

    @Test func applyBarWorkingOut() {
        #expect(bar(3, nil) == "3 changes · Working out…")
        #expect(bar(3, ChangePreview(add: 640), workingOut: true) == "3 changes · Working out…")
        #expect(bar(1, nil, workingOut: true) == "1 change · Working out…")
    }

    @Test func applyBarCounts() {
        #expect(bar(1, ChangePreview(add: 640)) == "1 change · would add 640, remove 0")
        #expect(bar(3, ChangePreview(add: 1, remove: 2)) == "3 changes · would add 1, remove 2")
        // Retitles only when there are some.
        #expect(bar(2, ChangePreview(add: 0, remove: 0, retitle: 4)) == "2 changes · would add 0, remove 0, retitle 4")
    }

    /// One part per calendar with copies to remove, in selection order; a calendar with none is left out.
    @Test func applyBarRemovalsInSelectionOrder() {
        let b = CalendarRef(id: "b"), c = CalendarRef(id: "c")
        let preview = ChangePreview(add: 0, remove: 2, removals: [c: 3, a: 5, b: 0])
        #expect(bar(1, preview) == "1 change · would add 0, remove 2, remove 5 from Acme, remove 3 from Globex")
    }

    /// A calendar `order` does not name still shows, after the others, by name.
    @Test func applyBarRemovalOutsideOrder() {
        let b = CalendarRef(id: "b"), c = CalendarRef(id: "c")
        let preview = ChangePreview(removals: [c: 1, b: 2, a: 4])
        #expect(bar(1, preview, order: [a])
            == "1 change · would add 0, remove 0, remove 4 from Acme, remove 1 from Globex, remove 2 from Initech")
    }

    /// Syncing stops: no run to plan, so no add, remove or retitle counts, only the removals.
    @Test func applyBarSyncingStops() {
        let b = CalendarRef(id: "b")
        let preview = ChangePreview(removals: [a: 5, b: 3], syncingStops: true)
        #expect(bar(1, preview) == "1 change · would remove 5 from Acme, remove 3 from Initech · syncing stops")
        #expect(bar(2, ChangePreview(removals: [a: 0, b: 0], syncingStops: true)) == "2 changes · syncing stops")
        #expect(bar(1, ChangePreview(syncingStops: true)) == "1 change · syncing stops")
    }

    /// A skip reason takes the place of the counts; the removals and "syncing stops" still show.
    @Test func applyBarSkipReason() {
        let missing = SyncEngine.missing
        #expect(bar(2, ChangePreview(skippedReason: missing)) == "2 changes · \(missing)")
        #expect(bar(2, ChangePreview(removals: [a: 4], skippedReason: missing))
            == "2 changes · \(missing) · would remove 4 from Acme")
        #expect(bar(1, ChangePreview(syncingStops: true, skippedReason: SyncEngine.readFailed))
            == "1 change · \(SyncEngine.readFailed) · syncing stops")
        #expect(bar(1, ChangePreview(removals: [a: 0], skippedReason: missing)) == "1 change · \(missing)")
    }

    /// The empty-read hold: the counts of the run once the hold has passed, then the hold's reason; the removals
    /// stay with the counts. A skip reason still takes the place of the counts.
    @Test func applyBarHeldReason() {
        let held = SyncEngine.emptyRead
        #expect(bar(1, ChangePreview(add: 1, remove: 1, heldReason: held))
            == "1 change · would add 1, remove 1 · \(held)")
        #expect(bar(2, ChangePreview(add: 0, remove: 3, retitle: 2, removals: [a: 4], heldReason: held))
            == "2 changes · would add 0, remove 3, retitle 2, remove 4 from Acme · \(held)")
        #expect(bar(1, ChangePreview(removals: [a: 4], skippedReason: SyncEngine.readFailed, heldReason: held))
            == "1 change · \(SyncEngine.readFailed) · would remove 4 from Acme")
    }

    func pending(_ count: Int?, mode: SyncMode = .dryRun, syncing: Bool = true) -> String {
        StatusText.pendingRemoval(count, from: "Initech", mode: mode, syncing: syncing)
    }

    /// A calendar whose Busy blocks wait for Live, in Dry run's status: the count once a dry run has worked it out.
    @Test func pendingRemovalLine() {
        #expect(pending(12) == "Would remove 12 Busy blocks from Initech in Live")
        #expect(pending(1) == "Would remove 1 Busy block from Initech in Live")
        #expect(pending(0) == "Would remove 0 Busy blocks from Initech in Live")
        #expect(pending(nil) == "Would remove the Busy blocks from Initech in Live")
    }

    /// Fewer than two calendars applied in Dry run: Live cannot be switched on, so the line promises nothing of Live
    /// and names the one button that removes them, whatever the count.
    @Test func pendingRemovalLineWithoutSyncing() {
        let stay = "Busy blocks stay in Initech - \"Remove all Busy copies…\" removes them"
        #expect(pending(12, syncing: false) == stay)
        #expect(pending(nil, syncing: false) == stay)
    }

    /// In Live a calendar still waiting is one whose removal failed (or has not run yet since a relaunch): it is
    /// retried after every live run that goes ahead.
    @Test func pendingRemovalLineInLive() {
        let notYet = "Busy blocks in Initech could not be removed yet"
        #expect(pending(12, mode: .live) == notYet)
        #expect(pending(nil, mode: .live) == notYet)
        #expect(pending(nil, mode: .live, syncing: false) == notYet)
    }

    /// The switch to Live quotes the last dry run, then each calendar whose Busy blocks wait for Live and hold some.
    @Test func liveSwitchMessage() {
        let tail = "From then on BusySign writes Busy blocks to Acme and Initech on every run."
        #expect(StatusText.liveSwitchMessage(add: 3, remove: 1, retitle: 0, pendingRemovals: [],
                                             selectedNames: "Acme and Initech")
            == "The last dry run would add 3 and remove 1 busy blocks. " + tail)
        #expect(StatusText.liveSwitchMessage(add: 0, remove: 0, retitle: 2, pendingRemovals: [],
                                             selectedNames: "Acme and Initech")
            == "The last dry run would add 0 and remove 0 busy blocks. It would also update the title of 2 Busy blocks. "
            + tail)
        #expect(StatusText.liveSwitchMessage(add: 3, remove: 1, retitle: 2,
                                             pendingRemovals: [(name: "Home", count: 12), (name: "Gmail", count: 0),
                                                               (name: "Work", count: 1)],
                                             selectedNames: "Acme and Initech")
            == "The last dry run would add 3 and remove 1 busy blocks. It would also update the title of 2 Busy blocks. "
            + "It would also remove 12 Busy blocks from Home, which you stopped syncing. "
            + "It would also remove 1 Busy block from Work, which you stopped syncing. " + tail)
    }

    /// "Remove all Busy copies…" names the ticked calendars and the ones whose Busy blocks wait for Live.
    @Test func removeAllMessage() {
        let head = "This also pauses syncing. BusySign then deletes every Busy block it added to "
        let tail = ". Your own events are not touched. Resume syncing from the menu to mirror busy time again."
        #expect(StatusText.removeAllMessage(selected: "Acme and Initech", stopped: nil) == head + "Acme and Initech" + tail)
        #expect(StatusText.removeAllMessage(selected: "Acme and Initech", stopped: "Home")
            == head + "Acme and Initech, and to Home, which you stopped syncing" + tail)
        #expect(StatusText.removeAllMessage(selected: nil, stopped: "Acme and Home")
            == head + "Acme and Home, which you stopped syncing" + tail)
        #expect(StatusText.removeAllMessage(selected: nil, stopped: nil) == head + "the selected calendars" + tail)
    }

    /// Thresholds written by hand that no whole number can hold must not crash the settings window.
    @Test func quietNoteSurvivesHugeThresholds() {
        let note = StatusText.quietNote(thresholdHours: 1e30)
        #expect(note.hasPrefix("No new events for "))
        #expect(note.hasSuffix(" days") || note.hasSuffix(" h"))
        #expect(!note.contains("inf") && !note.hasSuffix(" 0 h"))
        #expect(StatusText.quietNoteHelp(thresholdHours: 1e30).hasPrefix("BusySign hasn't seen"))
    }
}
