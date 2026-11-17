import Foundation
import Testing
@testable import BusySignCore

private let at = Date(timeIntervalSince1970: 1_800_000_000)
private let spec = CopySpec(target: CalendarRef(id: "B"), marker: "m", start: at, end: at + 3600, isAllDay: false)
/// A dry run that went ahead and plans two adds and one delete.
private let dryRun = SyncResult(at: at, mode: .dryRun,
                                planned: [.create(spec), .create(spec), .delete(localID: "x", target: CalendarRef(id: "A"))])

private func decide(_ result: SyncResult?, mode: SyncMode = .dryRun, changed: Bool = false, removals: Int = 0,
                    paused: Bool = false, staged: Bool = false, counted: Bool = true) -> LiveSwitch {
    liveSwitch(lastResult: result, mode: mode, inputsChangedSinceRun: changed, removalsInFlight: removals,
               paused: paused, hasStagedChanges: staged, pendingRemovalsCounted: counted)
}

@Test func liveIsOfferedWithTheCountsOfADryRunThatStillHolds() {
    #expect(decide(dryRun) == .allowed(add: 2, remove: 1, retitle: 0))
    #expect(decide(dryRun, paused: true) == .allowed(add: 2, remove: 1, retitle: 0))
    #expect(decide(dryRun, mode: .live) == .alreadyLive)
}

@Test func liveWaitsForADryRunWithTheCurrentSettings() {
    let generic = LiveSwitch.blocked(hint: "Run a dry run first")
    #expect(decide(nil) == generic)
    #expect(decide(dryRun, changed: true) == generic)
    #expect(decide(SyncResult(at: at, mode: .live, planned: dryRun.planned)) == generic)
    #expect(decide(nil, paused: true) == .blocked(hint: "Resume syncing and run a dry run first"))
}

@Test func liveWaitsWhileBusyCopiesAreBeingRemoved() {
    // A removal still queued or running changes what the first live run writes, whatever the last dry run said.
    #expect(decide(dryRun, removals: 1) == .blocked(hint: "Run a dry run first"))
    #expect(decide(dryRun, removals: 2, paused: true) == .blocked(hint: "Resume syncing and run a dry run first"))
}

@Test func aSkipThatAnotherDryRunCannotFixIsTheHint() {
    for reason in [SyncEngine.needTwo, SyncEngine.missing, SyncEngine.readOnly, SyncEngine.accessNeeded] {
        let skipped = SyncResult(at: at, mode: .dryRun, skippedReason: reason)
        #expect(decide(skipped) == .blocked(hint: reason))
        #expect(decide(skipped, paused: true) == .blocked(hint: reason))
        // Once something changed, the next dry run may go ahead.
        #expect(decide(skipped, changed: true) == .blocked(hint: "Run a dry run first"))
    }
    // A skip that a later run can get past.
    for reason in [SyncEngine.emptyRead, SyncEngine.readFailed] {
        #expect(decide(SyncResult(at: at, mode: .dryRun, skippedReason: reason)) == .blocked(hint: "Run a dry run first"))
    }
}

/// The confirmation also quotes the retitles the dry run planned; a move is not one.
@Test func allowedCarriesRetitles() {
    let b = CalendarRef(id: "B")
    let retitle = PlannedChange(kind: .retitle, target: b, start: at, end: at + 3600, isAllDay: false)
    let retitling = SyncResult(at: at, mode: .dryRun, planned: Array(repeating: .update(localID: "y", spec), count: 2),
                               changes: [retitle, retitle])
    #expect(decide(retitling) == .allowed(add: 0, remove: 0, retitle: 2))
    #expect(decide(retitling, changed: true) == .blocked(hint: "Run a dry run first"))

    var mixed = retitling
    mixed.planned.append(.update(localID: "z", spec))
    mixed.changes.append(PlannedChange(kind: .move, target: b, start: at + 7200, end: at + 10_800, isAllDay: false,
                                       previousStart: at, previousEnd: at + 3600, previousIsAllDay: false))
    #expect(decide(mixed) == .allowed(add: 0, remove: 0, retitle: 2))
}

/// Changes waiting for Apply: the last dry run quotes the applied settings only, so Live waits for Apply or Revert,
/// whatever else holds it back.
@Test func stagedChangesBlockLive() {
    let hint = LiveSwitch.blocked(hint: "Apply or revert your changes first")
    #expect(decide(dryRun, staged: true) == hint)
    #expect(decide(dryRun, paused: true, staged: true) == hint)
    #expect(decide(nil, staged: true) == hint)
    #expect(decide(SyncResult(at: at, mode: .dryRun, skippedReason: SyncEngine.needTwo), staged: true) == hint)
    #expect(decide(dryRun, mode: .live, staged: true) == .alreadyLive)
}

/// Busy blocks waiting for Live whose counts are not all known: the confirmation could not name them, so Live waits
/// for the dry run that counts them; a skip another dry run cannot fix still gives its own reason.
@Test func uncountedPendingRemovalsBlockLive() {
    #expect(decide(dryRun, counted: false) == .blocked(hint: "Run a dry run first"))
    #expect(decide(dryRun, paused: true, counted: false) == .blocked(hint: "Resume syncing and run a dry run first"))
    #expect(decide(SyncResult(at: at, mode: .dryRun, skippedReason: SyncEngine.needTwo), counted: false)
        == .blocked(hint: SyncEngine.needTwo))
    #expect(decide(dryRun, staged: true, counted: false) == .blocked(hint: "Apply or revert your changes first"))
    #expect(decide(dryRun, mode: .live, counted: false) == .alreadyLive)
    #expect(decide(dryRun, counted: true) == .allowed(add: 2, remove: 1, retitle: 0))
}

/// Only the refusal for staged changes waits for Apply: Settings then keeps Live clickable, flashes the Apply bar on a
/// click and shows the hint as status text; every other hint keeps the control greyed and the hint small.
@Test func onlyStagedChangesWaitForApply() {
    #expect(decide(dryRun, staged: true).waitsForApply)
    #expect(decide(nil, paused: true, staged: true, counted: false).waitsForApply)
    #expect(!decide(dryRun).waitsForApply)
    #expect(!decide(dryRun, mode: .live, staged: true).waitsForApply)
    #expect(!decide(nil).waitsForApply)
    #expect(!decide(dryRun, paused: true, counted: false).waitsForApply)
    #expect(!decide(SyncResult(at: at, mode: .dryRun, skippedReason: SyncEngine.needTwo)).waitsForApply)
}
