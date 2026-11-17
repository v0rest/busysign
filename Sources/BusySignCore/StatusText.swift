import Foundation

public enum StatusText {
    public static func headline(_ r: SyncResult?, paused: Bool, access: AccessState, now: Date) -> String {
        if access != .granted { return SyncEngine.accessNeeded }
        if paused { return "Paused" }
        guard let r else { return "Not synced yet" }
        if let reason = r.skippedReason { return "Not synced: \(reason)" }
        let emptied = r.emptiedCalendars.count
        let emptiedSuffix = switch emptied {
        case 0: ""
        case 1: " (1 calendar shows no events)"
        default: " (\(emptied) calendars show no events)"
        }
        if r.mode == .dryRun {
            let counts = r.plannedCounts
            let retitles = r.plannedRetitles
            return "Dry run: would add \(counts.add), remove \(counts.remove)"
                + (retitles > 0 ? ", retitle \(retitles)" : "") + emptiedSuffix
        }
        let failed = r.report?.failures.count ?? 0
        let suffix = (failed == 0 ? "" : " (\(failed) \(failed == 1 ? "change" : "changes") failed)") + emptiedSuffix
        let seconds = now.timeIntervalSince(r.at)
        if seconds < 60 { return "Synced just now" + suffix }
        if seconds < 3600 { return "Synced \(Int(seconds / 60)) min ago" + suffix }
        return "Synced \(Int(seconds / 3600)) h ago" + suffix
    }

    /// The Apply bar's text for `changes` staged changes and the preview of them (`ChangePreview`):
    /// "3 changes · would add 640, remove 0", with ", retitle t" when there are retitles, then ", remove k from
    /// <calendar>" for each calendar Apply clears that holds copies, in `order` (any other after them, by name),
    /// then " · syncing stops". `Working out…` in place of the counts while `workingOut` or before a preview has
    /// landed. When syncing stops there is no run to plan, so the add, remove and retitle counts are left out:
    /// "1 change · would remove 5 from Acme, remove 3 from Initech · syncing stops". A skip reason takes the place
    /// of the counts, and the removals follow it as " · would remove k from <calendar>, …". The empty-read hold's
    /// reason (`ChangePreview.heldReason`) follows the counts instead: "1 change · would add 1, remove 1 · A calendar
    /// returned no events; …". `name` gives a calendar's shown name.
    public static func applyBar(changes: Int, preview: ChangePreview?, workingOut: Bool, order: [CalendarRef],
                                name: (CalendarRef) -> String) -> String {
        let head = "\(changes) \(changes == 1 ? "change" : "changes") · "
        guard let preview, !workingOut else { return head + "Working out…" }
        var seen = Set<CalendarRef>()
        let named = order.filter { seen.insert($0).inserted }
        let others = preview.removals.keys.filter { !seen.contains($0) }
            .sorted { (name($0), $0.id) < (name($1), $1.id) }
        let removals = (named + others).compactMap { ref -> String? in
            guard let count = preview.removals[ref], count > 0 else { return nil }
            return "remove \(count) from \(name(ref))"
        }
        var parts: [String] = []
        if preview.skippedReason == nil && !preview.syncingStops {
            parts.append("would add \(preview.add), remove \(preview.remove)"
                + (preview.retitle > 0 ? ", retitle \(preview.retitle)" : "")
                + removals.map { ", " + $0 }.joined())
            if let held = preview.heldReason { parts.append(held) }
        } else {
            if let reason = preview.skippedReason { parts.append(reason) }
            if !removals.isEmpty { parts.append("would " + removals.joined(separator: ", ")) }
        }
        if preview.syncingStops { parts.append("syncing stops") }
        return head + parts.joined(separator: " · ")
    }

    /// The status line of a calendar whose Busy blocks wait for Live (`PendingRemovals`). In Dry run: "Would remove 12
    /// Busy blocks from Initech in Live", or "Would remove the Busy blocks from Initech in Live" while `count` is not
    /// known yet; but while the applied selection has fewer than two calendars Calendar lists (`syncing` false), Live
    /// cannot be switched on, so it promises nothing of Live: "Busy blocks stay in Initech - "Remove all Busy copies…"
    /// removes them". In Live, where a waiting calendar's removal failed or has not run yet and is retried after every
    /// live run: "Busy blocks in Initech could not be removed yet".
    public static func pendingRemoval(_ count: Int?, from name: String, mode: SyncMode, syncing: Bool) -> String {
        if mode == .live { return "Busy blocks in \(name) could not be removed yet" }
        guard syncing else { return "Busy blocks stay in \(name) - \"Remove all Busy copies…\" removes them" }
        guard let count else { return "Would remove the Busy blocks from \(name) in Live" }
        return "Would remove \(busyBlocks(count)) from \(name) in Live"
    }

    /// The confirmation of the switch to Live: what the last dry run would add, remove and retitle, then, for each
    /// calendar whose Busy blocks wait for Live and hold some, "It would also remove k Busy blocks from <name>, which
    /// you stopped syncing.", in the order given, then the calendars Live writes Busy blocks to (`selectedNames`: the
    /// ones another ticked calendar copies into, `calendarsGettingBlocks`).
    public static func liveSwitchMessage(add: Int, remove: Int, retitle: Int,
                                         pendingRemovals: [(name: String, count: Int)], selectedNames: String) -> String {
        "The last dry run would add \(add) and remove \(remove) busy blocks. "
            + (retitle > 0 ? "It would also update the title of \(retitle) Busy blocks. " : "")
            + pendingRemovals.filter { $0.count > 0 }.map {
                "It would also remove \(busyBlocks($0.count)) from \($0.name), which you stopped syncing. "
            }.joined()
            + "From then on BusySign writes Busy blocks to \(selectedNames) on every run."
    }

    /// The confirmation of "Remove all Busy copies…": `selected`, the ticked calendars it clears, and `stopped`, the
    /// ones whose Busy blocks wait for Live, by name; nil when there are none. Both nil: "the selected calendars".
    public static func removeAllMessage(selected: String?, stopped: String?) -> String {
        let place = switch (selected, stopped) {
        case let (selected?, stopped?): "\(selected), and to \(stopped), which you stopped syncing"
        case let (nil, stopped?): "\(stopped), which you stopped syncing"
        case let (selected?, nil): selected
        case (nil, nil): "the selected calendars"
        }
        return "This also pauses syncing. BusySign then deletes every Busy block it added to \(place). Your own events "
            + "are not touched. Resume syncing from the menu to mirror busy time again."
    }

    /// "1 Busy block", "12 Busy blocks".
    private static func busyBlocks(_ count: Int) -> String {
        "\(count) Busy \(count == 1 ? "block" : "blocks")"
    }

    /// The note beside a calendar whose real events have not changed for `thresholdHours`:
    /// "No new events for a week".
    public static func quietNote(thresholdHours: Double) -> String {
        "No new events for \(period(thresholdHours, week: "a week"))"
    }

    /// The note's tooltip; the week is spelled out in days here.
    public static func quietNoteHelp(thresholdHours: Double) -> String {
        "BusySign hasn't seen a new or changed event in this calendar for \(period(thresholdHours, week: "7 days")). "
            + "If you expected some, check the account in Calendar → Settings → Accounts."
    }

    /// Whole days when the hours are a multiple of 24 ("a day", "2 days", `week` for 168), else whole hours, at
    /// least one ("12 h"). Hours written by hand may be fractional or too large for an `Int`.
    private static func period(_ hours: Double, week: String) -> String {
        guard hours > 0, hours.truncatingRemainder(dividingBy: 24) == 0 else {
            return "\(whole(max(1, hours.rounded()))) h"
        }
        let days = hours / 24
        if days == 1 { return "a day" }
        if days == 7 { return week }
        return "\(whole(days)) days"
    }

    private static func whole(_ value: Double) -> String {
        Int(exactly: value).map(String.init) ?? String(format: "%.0f", value)
    }
}
