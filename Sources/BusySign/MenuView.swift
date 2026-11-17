import AppKit
import BusySignCore
import SwiftUI

/// The status menu. Menu content becomes an `NSMenu`, so it holds only buttons, dividers and
/// single-line texts.
struct MenuView: View {
    @ObservedObject var model: AppModel
    let openMeetings: @MainActor () -> Void
    let openSettings: @MainActor () -> Void
    /// Ends editing in Settings before a switch to live (`SettingsWindowController.endEditing`).
    let endEditing: @MainActor () -> Void

    var body: some View {
        Text(model.headline)
        ForEach(model.calendarLines, id: \.id) { line in
            Text(line.text)
        }
        ForEach(model.pendingRemovalLines, id: \.id) { line in
            Text(line.text)
        }
        if let problem = model.loginItemMessage {
            Text("⚠ Start at login: \(problem)")
        }
        // A button, as a text in the menu cannot act; so that a closed window does not hide staged changes.
        if model.staged != nil {
            Button("Changes not applied - open Settings") { openSettings() }
        }
        Divider()
        Button("Meetings…") { openMeetings() }
        Button("Sync now") { model.syncNow() }
            .disabled(model.paused)
        Button(model.paused ? "Resume syncing" : "Pause syncing") { model.togglePause() }
        if model.mode == .dryRun {
            // The alert runs after the menu has closed.
            Button("Switch to live") { Task { confirmSwitchToLive(model, endEditing: endEditing) } }
                .disabled(model.switchToLiveHint != nil)
            // Not when the headline already gives it as the reason the last run was skipped.
            if let hint = model.switchToLiveHint, !model.headline.hasSuffix(hint) {
                Text(hint)
            }
        }
        Divider()
        Button("Settings…") { openSettings() }
            .keyboardShortcut(",")
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The menu-bar icon: the door hanger glyph, with a dot whenever something needs a look.
struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    private static let plain = glyph(attention: false)
    private static let attention = glyph(attention: true)

    var body: some View {
        Image(nsImage: model.needsAttention ? Self.attention : Self.plain)
            .accessibilityLabel("BusySign")
    }

    /// An 18 pt template image drawn at whatever scale it is shown. Nonisolated so the drawing handler carries no
    /// main-actor isolation of its own: AppKit decides on which thread it runs.
    nonisolated private static func glyph(attention: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            BrandArt.drawMenuGlyph(in: context, size: rect.width, attention: attention)
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct CalendarLine {
    let id: String
    let text: String
}

/// A calendar waiting for Live and the Busy blocks the switch removes from it.
struct PendingRemoval: Equatable {
    let calendar: CalendarRef
    let count: Int
}

extension AppModel {
    var headline: String {
        StatusText.headline(lastResult, paused: paused, access: access, now: now)
    }

    /// One line per applied selected calendar that Calendar lists, in selection order: "Acme → Initech: 42
    /// meetings", naming the calendars it copies into under the applied pair choices (not those set to Nothing),
    /// counted like the Meetings window (meetings, not Busy blocks) under the applied exclusions
    /// (`Section.appliedCount`): what is in the calendars now, so ticks staged there do not count until Apply.
    /// Without a run that went ahead, without another calendar to copy to, or when something the last run depended
    /// on changed since (`structureChangedSinceRun`; ticks in the Meetings window do not count, the catalog follows
    /// them), the line names the calendars only: the counts belong to that run. A calendar whose every pair to the
    /// other listed ones is set to Nothing reads "Acme: not copied".
    var calendarLines: [CalendarLine] {
        let result = lastResult.flatMap { $0.skippedReason == nil ? $0 : nil }
        let listed = Set(calendars.map(\.ref))
        let counted = result != nil && !structureChangedSinceRun
        let counts = Dictionary(catalog.sections.map { ($0.source, $0.appliedCount) },
                                uniquingKeysWith: { first, _ in first })
        var seen = Set<CalendarRef>()
        let selected = applied.selected.filter { listed.contains($0) && seen.insert($0).inserted }
        return selected.map { source in
            let others = selected.filter { $0 != source }
            let targets = others.filter { applied.copyTitleFormats.copies(from: source, to: $0) }
            var text = shortName(source)
            if !targets.isEmpty {
                text += " → " + targets.map(shortName).joined(separator: ", ")
                if counted, let count = counts[source] { text += ": \(count) \(count == 1 ? "meeting" : "meetings")" }
            } else if !others.isEmpty {
                text += ": not copied"
            }
            return CalendarLine(id: source.id, text: text)
        }
    }

    var needsAttention: Bool {
        if access != .granted || loginItemMessage != nil { return true }
        guard let result = lastResult else { return false }
        if result.skippedReason != nil { return true }
        return result.mode == .live && !(result.report?.failures.isEmpty ?? true)
    }

    /// One line per calendar whose Busy blocks wait for Live, in the order they joined (`StatusText.pendingRemoval`).
    /// In Dry run: "Would remove 12 Busy blocks from Initech in Live" ("the Busy blocks" while the count is not known
    /// yet), or, while the applied selection has fewer than two calendars Calendar lists and Live cannot be switched
    /// on, that they stay until "Remove all Busy copies…". In Live: that they could not be removed yet (retried after
    /// every live run), but not while a removal is queued or running, which may well go through.
    var pendingRemovalLines: [CalendarLine] {
        guard mode == .dryRun || removalsInFlight == 0 else { return [] }
        let listed = Set(calendars.map(\.ref))
        let syncing = Set(applied.selected).intersection(listed).count >= 2
        return pendingRemovals.map { ref in
            CalendarLine(id: "pending|" + ref.id,
                         text: StatusText.pendingRemoval(pendingRemovalCounts?[ref], from: shortName(ref), mode: mode,
                                                         syncing: syncing))
        }
    }

    /// Whether Live is offered and what its confirmation quotes (`liveSwitch`): never while changes wait for
    /// Apply, since the last dry run quotes the applied settings only, nor while a calendar waiting for Live has no
    /// count, since the confirmation names what the switch removes.
    var liveSwitchState: LiveSwitch {
        liveSwitch(lastResult: lastResult, mode: mode, inputsChangedSinceRun: inputsChangedSinceRun,
                   removalsInFlight: removalsInFlight, paused: paused, hasStagedChanges: staged != nil,
                   pendingRemovalsCounted: PendingRemovals.allCounted(pendingRemovals, counts: pendingRemovalCounts))
    }

    /// The planned counts of the last dry run while they still hold; nil otherwise, and Live is not offered.
    var knownDryRunCounts: (add: Int, remove: Int, retitle: Int)? {
        guard case let .allowed(add, remove, retitle) = liveSwitchState else { return nil }
        return (add, remove, retitle)
    }

    /// The Busy blocks the switch to Live removes first, per calendar waiting for Live in the order they joined,
    /// while Live is offered (`knownDryRunCounts`, which needs every count); nil otherwise.
    var knownPendingRemovals: [PendingRemoval]? {
        guard knownDryRunCounts != nil else { return nil }
        var removals: [PendingRemoval] = []
        for ref in pendingRemovals {
            guard let count = pendingRemovalCounts?[ref] else { return nil }
            removals.append(PendingRemoval(calendar: ref, count: count))
        }
        return removals
    }

    /// Why Live cannot be picked yet, shown next to the disabled control; nil in Live and while it is offered.
    var switchToLiveHint: String? {
        guard case let .blocked(hint) = liveSwitchState else { return nil }
        return hint
    }
}

/// Asks before switching to live, stating what the last dry run planned and the Busy blocks waiting for Live that
/// the switch removes first (`knownPendingRemovals`). Used by the menu and the settings window, which offer it only
/// once those counts are known (`liveSwitch`). First it ends editing in Settings (`endEditing`), since clicking Live
/// or a menu item does not take the focus from a field: a Look ahead or short name typed there is staged already, so
/// a new one has kept Live from being offered since its keystroke, and ending editing only puts the field on the
/// value the alert quotes ("900" → "90"). Checked before the alert, since both callers reach it through a task, and
/// again after it: runs, removals and staged edits go on while it is open, so it switches only if the counts it
/// quoted still hold and nothing is staged.
@MainActor
func confirmSwitchToLive(_ model: AppModel, endEditing: @MainActor () -> Void) {
    endEditing()
    guard model.mode == .dryRun, let counts = model.knownDryRunCounts, let pending = model.knownPendingRemovals else {
        // Redraws what follows the mode; Settings also makes its picker anew once this returns (`modePicker`).
        model.objectWillChange.send()
        return
    }
    let confirmed = confirm(
        title: "Switch to live?",
        message: StatusText.liveSwitchMessage(
            add: counts.add, remove: counts.remove, retitle: counts.retitle,
            pendingRemovals: pending.map { (name: model.shortName($0.calendar), count: $0.count) },
            selectedNames: model.liveTargetNames
        ),
        action: "Switch to Live"
    )
    guard confirmed, model.mode == .dryRun, let now = model.knownDryRunCounts, now == counts,
          model.knownPendingRemovals == pending else {
        model.objectWillChange.send()
        return
    }
    model.setMode(.live)
}

/// A modal confirmation. Activates the app first: it has no Dock icon, so the alert would otherwise
/// open behind the frontmost app.
@MainActor
func confirm(title: String, message: String, action: String) -> Bool {
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: action)
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}
