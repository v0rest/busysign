import Foundation

/// Whether the menu and Settings offer the switch from Dry run to Live, and what its confirmation quotes.
public enum LiveSwitch: Sendable, Equatable {
    /// The mode is Live already.
    case alreadyLive
    /// The last dry run's planned counts, which still hold: adds, removals and retitles.
    case allowed(add: Int, remove: Int, retitle: Int)
    /// Not yet; the hint says why, next to the disabled control.
    case blocked(hint: String)

    public static let runDryRunFirst = "Run a dry run first"
    public static let resumeAndRunDryRunFirst = "Resume syncing and run a dry run first"
    public static let applyOrRevertFirst = "Apply or revert your changes first"

    /// Whether Live waits for staged changes to be applied or reverted (`applyOrRevertFirst`), the one refusal the
    /// user can end at once from the Apply bar: Settings keeps Live clickable then, flashes the bar on a click and
    /// shows the hint as status text rather than a caption.
    public var waitsForApply: Bool {
        self == .blocked(hint: Self.applyOrRevertFirst)
    }
}

/// Skip reasons that another dry run cannot get past: the user has to act first.
private let needsTheUser: Set<String> = [SyncEngine.needTwo, SyncEngine.missing, SyncEngine.readOnly,
                                         SyncEngine.accessNeeded]

/// Live is offered in Dry run only once a dry run that went ahead (so with at least two calendars) has
/// finished, nothing it depended on changed since (`inputsChangedSinceRun`), and no removal of Busy copies is
/// queued or running (`removalsInFlight`), since that changes what the first live run writes, and no setting
/// change waits for Apply (`hasStagedChanges`), since the last dry run quotes the applied settings only, and the
/// Busy blocks waiting for Live are counted (`pendingRemovalsCounted`, `PendingRemovals`), since the confirmation
/// names them and the switch removes them. So nothing is written before a dry run showed what. While changes wait,
/// the hint is "Apply or revert your changes first". Otherwise, while it is not offered, the hint is the reason the
/// last run was skipped when another dry run cannot fix it (fewer than two calendars, a missing or read-only
/// calendar, no access) and nothing changed since; else "Run a dry run first", or "Resume syncing and run a dry run
/// first" while paused.
public func liveSwitch(lastResult: SyncResult?, mode: SyncMode, inputsChangedSinceRun: Bool, removalsInFlight: Int,
                       paused: Bool, hasStagedChanges: Bool = false, pendingRemovalsCounted: Bool = true) -> LiveSwitch {
    guard mode == .dryRun else { return .alreadyLive }
    if hasStagedChanges { return .blocked(hint: LiveSwitch.applyOrRevertFirst) }
    if let result = lastResult, !inputsChangedSinceRun, removalsInFlight == 0 {
        if result.mode == .dryRun, result.skippedReason == nil, pendingRemovalsCounted {
            let counts = result.plannedCounts
            return .allowed(add: counts.add, remove: counts.remove, retitle: result.plannedRetitles)
        }
        if let reason = result.skippedReason, needsTheUser.contains(reason) { return .blocked(hint: reason) }
    }
    return .blocked(hint: paused ? LiveSwitch.resumeAndRunDryRunFirst : LiveSwitch.runDryRunFirst)
}
