import AppKit
import BusySignCore
import SwiftUI

/// The settings window, managed in AppKit so it reliably comes to the front for an app without a Dock
/// icon. The window and its view are made once and reused, so what is being typed there (`NumberDrafts`,
/// `NameDrafts`) lives here. Look ahead and short names are staged keystroke by keystroke, so ending editing stages
/// nothing: before Apply and a switch to live, from either window, and when the window closes, it only puts their
/// fields back on the staged values (`endEditing`); Revert ends editing too (`revertStagedChanges`); showing the
/// window again drops what is left. Staged changes outlive the window (`AppModel.staged`).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let openMeetings: @MainActor () -> Void
    private let drafts: NumberDrafts
    private let names: NameDrafts
    private var window: NSWindow?

    init(model: AppModel, openMeetings: @escaping @MainActor () -> Void) {
        self.model = model
        self.openMeetings = openMeetings
        drafts = NumberDrafts(model: model)
        names = NameDrafts(model: model)
        super.init()
    }

    func show() {
        model.reloadCalendars()
        let window = window ?? makeWindow()
        self.window = window
        // Before the window is on screen, so it opens with the values in effect, not a text left from last time.
        // Not when it is already open: a number being typed there stays.
        if !window.isVisible {
            drafts.discardAll()
            names.endAll()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Ends editing in Settings at once, since clicking a button, a menu item or Live does not take the focus from a
    /// field and its own end on losing focus comes later: before Apply and a switch to live, from either window, and
    /// when the window closes. A Look ahead or short name being typed is staged already, so it only goes back to
    /// showing the staged value ("900" → "90") and stages nothing: an Apply that follows applies what its bar
    /// previewed (`AppModel.canApplyStagedChanges`). Check every, which is not staged, commits as on Return
    /// (`NumberDrafts.commitAll`). A field's own end when it loses focus, whenever it comes, finds nothing left.
    func endEditing() {
        window?.makeFirstResponder(nil)
        drafts.commitAll()
        names.endAll()
    }

    /// Revert, from either window: ends editing in Settings, reverts the staged changes, then drops what is still
    /// typed there, a Check every not committed yet included. Ending editing stages nothing, so a field's own end on
    /// losing focus, whenever it comes, leaves nothing staged, and the fields show the applied values.
    func revertStagedChanges() {
        window?.makeFirstResponder(nil)
        model.revertStagedChanges()
        drafts.discardAll()
        names.endAll()
    }

    func windowWillClose(_ notification: Notification) {
        endEditing()
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(
            rootView: SettingsView(model: model, drafts: drafts, names: names, openMeetings: openMeetings,
                                   endEditing: { [weak self] in self?.endEditing() },
                                   revert: { [weak self] in self?.revertStagedChanges() })
        )
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        window.title = "BusySign Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 560))
        window.center()
        window.delegate = self
        return window
    }
}

/// The numbers being typed in Settings, one editing per field (`TypedEdit`): none while the field shows the value
/// in effect. Window state, so the settings window controller owns it and not `AppModel`. Look ahead is staged on
/// every keystroke (`AppModel.setLookAheadDays`), so the Apply bar comes while typing: a whole number clamped to the
/// range, else, while the text is not a number, the applied value (`stagedNumber`); the field keeps the text as
/// typed until Return or focus loss, then shows the staged value, and Escape stages again the value it had when the
/// editing began. A staged Look ahead keeps Live from being offered until Apply or Revert, so a Live offer never
/// quotes a dry run of other numbers than the ones on screen. Check every is not staged and changes when runs happen,
/// so half-typed minutes never reschedule the timer: it commits on Return, when its field loses focus, and when
/// editing ends for Apply, a switch to live or the window closing (`commitAll()`); Escape and Revert drop it.
@MainActor
final class NumberDrafts: ObservableObject {
    enum Field: CaseIterable {
        case lookAheadDays, intervalMinutes
    }

    @Published private var edits: [Field: TypedEdit<Int>] = [:]
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    /// The value in effect: for Look ahead the staged one while something is staged.
    func value(_ field: Field) -> Int {
        switch field {
        case .lookAheadDays: model.effective.lookAheadDays
        case .intervalMinutes: model.intervalMinutes
        }
    }

    func range(_ field: Field) -> ClosedRange<Int> {
        switch field {
        case .lookAheadDays: SettingsStore.lookAheadRange
        case .intervalMinutes: SettingsStore.intervalRange
        }
    }

    /// An arrow click: ends the field's editing, so the field shows the new value, and sets it at once, Look ahead
    /// into the staged changes like a keystroke, Check every applied; the setters change nothing when the value is
    /// the same.
    func apply(_ newValue: Int, to field: Field) {
        if edits[field] != nil { edits[field] = nil }
        set(newValue, field)
    }

    private func set(_ newValue: Int, _ field: Field) {
        switch field {
        case .lookAheadDays: model.setLookAheadDays(newValue)
        case .intervalMinutes: model.setIntervalMinutes(newValue)
        }
    }

    /// What the field shows: the text being typed, else the value in effect.
    func text(_ field: Field) -> String {
        edits[field]?.text ?? String(value(field))
    }

    /// A keystroke. The first one of an editing remembers the value in effect, for Escape. Look ahead stages what
    /// the text says at once (`TypedEdit.staged`); Check every only keeps the text.
    func type(_ text: String, in field: Field) {
        guard text != self.text(field) else { return }
        let edit = TypedEdit.typing(text, into: edits[field], current: value(field))
        edits[field] = edit
        if field == .lookAheadDays {
            model.setLookAheadDays(edit.staged(in: range(field), applied: model.applied.lookAheadDays))
        }
    }

    /// Escape: the field shows the value in effect again, and Look ahead stages again the value it had when the
    /// editing began (`TypedEdit.before`), so a Look ahead change typed only now goes, with the bar if it was the
    /// only change.
    func cancel(_ field: Field) {
        guard let edit = edits[field] else { return }
        edits[field] = nil
        if field == .lookAheadDays { model.setLookAheadDays(edit.before) }
    }

    /// Return, focus loss: ends the editing, so the field shows the value in effect. A Look ahead typed is staged
    /// already ("900" shows as "90"). Check every commits a whole number (clamped to the range, `typedNumber`) that
    /// differs from the value in effect; other text puts the field back. Without an editing it does nothing, so a
    /// field losing focus after `commitAll()` changes nothing.
    func commit(_ field: Field) {
        guard let edit = edits[field] else { return }
        edits[field] = nil
        if field == .intervalMinutes, let typed = typedNumber(edit.text, in: range(field)), typed != value(field) {
            set(typed, field)
        }
    }

    /// The value in effect changed: the field shows it, ending the editing, unless it is what the Look ahead text
    /// being typed stages, so a keystroke's own staging keeps the text as typed ("900" while 90 is staged). Revert,
    /// an arrow and every other change put the field on the new value.
    func follow(_ newValue: Int, in field: Field) {
        guard let edit = edits[field] else { return }
        if field == .lookAheadDays, edit.staged(in: range(field), applied: model.applied.lookAheadDays) == newValue {
            return
        }
        edits[field] = nil
    }

    /// Ends every editing, synchronously, as on Return (`commit`): Apply, a switch to live, the window closing.
    func commitAll() {
        for field in Field.allCases { commit(field) }
    }

    /// Drops every editing without committing a Check every: Revert, the window shown again. A Look ahead typed stays
    /// staged until the Revert itself drops it.
    func discardAll() {
        if !edits.isEmpty { edits = [:] }
    }
}

/// The short names being typed in Settings, one editing by calendar (`CalendarRow`, `TypedEdit`): a calendar's
/// field is open while it has one. Window state like `NumberDrafts`, owned by the settings window controller. The
/// field opens with the name shown and stages nothing until a keystroke; every keystroke stages the text at once
/// through the rename rule (`AppModel.rename`), so the Apply bar comes while typing. Return, the checkmark and focus
/// loss only close the field (`end(_:)`), and so do Apply, a switch to live, Revert and the window closing or showing
/// again (`endAll()`); Escape stages again what was staged for the name when the field opened (`cancel(_:)`). A field
/// lives as long as its row, a `CalendarRow` for each calendar of `AppModel.settingsCalendarList.main`, ticked or
/// not: when the row goes, its field closes (`keep(_:)`, from `CalendarsSection`). The model itself drops a staged
/// rename whose row is gone (`AppModel.stage`, `namesKeepingRenames`), whatever order this and the field's own
/// callbacks come in, and a late keystroke for a calendar without a row stages nothing.
@MainActor
final class NameDrafts: ObservableObject {
    @Published private var edits: [CalendarRef: TypedEdit<String?>] = [:]
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    /// The text in `ref`'s field; nil while its field is closed.
    func draft(for ref: CalendarRef) -> String? {
        edits[ref]?.text
    }

    /// Opens `ref`'s field with `name`: the pencil, a double-click on the name. Stages nothing; remembers the
    /// stored name in effect, staged or applied, for Escape.
    func open(_ ref: CalendarRef, with name: String) {
        edits[ref] = TypedEdit(text: name, before: model.effective.calendarNames[ref.id])
    }

    /// A keystroke in an open field: stages the text (`AppModel.rename`). Only an open field, so a field that goes
    /// away after its editing ended does not open again.
    func type(_ text: String, for ref: CalendarRef) {
        guard let edit = edits[ref], edit.text != text else { return }
        edits[ref] = edit.typing(text)
        model.rename(ref, to: text)
    }

    /// Escape: closes `ref`'s field and stages again the stored name staged when it opened
    /// (`AppModel.restoreName`).
    func cancel(_ ref: CalendarRef) {
        guard let edit = edits[ref] else { return }
        edits[ref] = nil
        model.restoreName(ref, to: edit.before)
    }

    /// Return, the checkmark, focus loss: closes `ref`'s field; what was typed is staged already. Without an editing
    /// it does nothing, so a field losing focus after `endAll()` changes nothing.
    func end(_ ref: CalendarRef) {
        if edits[ref] != nil { edits[ref] = nil }
    }

    /// Closes the fields of calendars whose row is gone, keeping those of `rows`. Stages nothing: their staged names
    /// went back to the applied ones with the row (`AppModel.stage`).
    func keep(_ rows: Set<CalendarRef>) {
        for ref in edits.keys where !rows.contains(ref) { end(ref) }
    }

    /// Closes every field, staging nothing: Apply, a switch to live, Revert, the window closing or shown again.
    func endAll() {
        if !edits.isEmpty { edits = [:] }
    }
}

/// Settings: the calendars to sync, how syncing runs, the last run's status and clean-up, and, while changes are
/// staged, the Apply bar at the bottom. The meetings themselves are listed in the Meetings window, which the
/// status line opens.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    /// Watched by the number rows only; this view does not redraw when a draft changes.
    let drafts: NumberDrafts
    /// Watched by the calendar rows only.
    let names: NameDrafts
    let openMeetings: @MainActor () -> Void
    /// Before Apply and a switch to live, and for Revert in this window's bar: the controller's, which end editing
    /// here (`SettingsWindowController.endEditing`, `revertStagedChanges`).
    let endEditing: @MainActor () -> Void
    let revert: @MainActor () -> Void
    /// Counts the clicks on Live refused while changes are staged; each one flashes the Apply bar (`ApplyBar.flash`).
    @State private var refusedLiveClicks = 0
    /// The mode picker's identity, bumped after every click on Live that did not switch: the control is made anew
    /// from the model's mode, so it never stays on "Live" while the mode is Dry run.
    @State private var modePicker = 0

    var body: some View {
        VStack(spacing: 0) {
            Form {
                CalendarsSection(model: model, names: names)
                syncSection
                statusSection
                cleanUpSection
            }
            .formStyle(.grouped)
            if model.staged != nil {
                Divider()
                ApplyBar(model: model, endEditing: endEditing, revert: revert, flash: refusedLiveClicks)
            }
        }
        .frame(minWidth: 460, minHeight: 360)
    }

    // MARK: - Sync options

    private var syncSection: some View {
        Section("Sync") {
            Picker("Mode", selection: Binding(get: { model.mode }, set: { setMode($0) })) {
                Text("Dry run").tag(SyncMode.dryRun)
                // Clickable while only staged changes hold it back, so the click can point at the Apply bar.
                Text("Live").tag(SyncMode.live)
                    .disabled(model.switchToLiveHint != nil && !model.liveSwitchState.waitsForApply)
            }
            .pickerStyle(.segmented)
            .id(modePicker)
            // With fewer than two calendars, "Calendars to sync" already says what to do, unless changes wait. While
            // they wait, as status text rather than a caption: it is what a click on Live runs into.
            if let hint = model.switchToLiveHint, model.staged != nil || model.effective.selected.count >= 2 {
                Text("Live: \(hint).")
                    .font(model.liveSwitchState.waitsForApply ? nil : .caption)
                    .foregroundStyle(.secondary)
            }
            NumberRow(
                label: "Look ahead",
                fieldName: "Look ahead days",
                field: .lookAheadDays,
                value: drafts.value(.lookAheadDays),
                unit: { $0 == 1 ? "day" : "days" },
                drafts: drafts
            )
            NumberRow(
                label: "Check every",
                fieldName: "Check every minutes",
                field: .intervalMinutes,
                value: drafts.value(.intervalMinutes),
                unit: { _ in "min" },
                drafts: drafts
            )
            Toggle(
                "Treat unanswered invitations as busy",
                isOn: Binding(get: { model.effective.unansweredAsBusy }, set: { model.setUnansweredAsBusy($0) })
            )
            Toggle("Start at login", isOn: Binding(get: { model.startAtLogin }, set: { model.setStartAtLogin($0) }))
            if let problem = model.loginItemMessage {
                Text("Start at login: \(problem)").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// Live only once a dry run's counts are known (`switchToLiveHint`); a click on Live before that puts the
    /// control back, by making it anew from the model's mode (`modePicker`), and, while staged changes are what holds
    /// it back (`LiveSwitch.waitsForApply`), flashes the Apply bar. The same once the confirmation is done, whatever
    /// it decided: the control shows the mode the model has then.
    private func setMode(_ mode: SyncMode) {
        if mode == .live {
            guard model.switchToLiveHint == nil else {
                if model.liveSwitchState.waitsForApply { refusedLiveClicks += 1 }
                modePicker += 1
                return
            }
            Task {
                confirmSwitchToLive(model, endEditing: endEditing)
                modePicker += 1
            }
        } else {
            model.setMode(mode)
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Text(model.headline)
                Spacer()
                Button("Meetings…") { openMeetings() }
            }
            // The Busy blocks waiting for Live, or, in Live, not removed yet.
            ForEach(model.pendingRemovalLines, id: \.id) { line in
                Text(line.text)
            }
            if model.access != .granted {
                HStack {
                    Text(accessText).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Privacy Settings") { openPrivacySettings() }
                }
            }
        }
    }

    private var accessText: String {
        switch model.access {
        case .granted: "Calendar access granted"
        case .notDetermined: "Calendar access not asked yet"
        case .denied: "Calendar access needed: allow BusySign under Privacy & Security → Calendars"
        }
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Clean up

    private var cleanUpSection: some View {
        Section("Clean up") {
            HStack {
                Button("Remove all Busy copies…") { confirmRemoveAll() }
                    .disabled(model.removalsInFlight > 0)
                if model.removalsInFlight > 0 {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                // Staged, so it asks nothing: the Apply bar shows what it does, and Revert brings them back.
                Button("Clear exclusions (\(model.exclusionCount))") { model.clearExclusions() }
                    .disabled(model.exclusionCount == 0)
            }
            if let summary = model.removalSummary {
                Text(summary).textSelection(.enabled)
            }
        }
    }

    /// Names the ticked calendars and the ones waiting for Live: it clears both, at once, in any mode.
    private func confirmRemoveAll() {
        let confirmed = confirm(
            title: "Remove all Busy copies?",
            message: StatusText.removeAllMessage(selected: model.removeAllSelectedNames,
                                                 stopped: model.removeAllPendingNames),
            action: "Pause and Remove"
        )
        if confirmed { model.removeAllBusyCopies() }
    }
}

/// A whole-number setting, typed or stepped: "Look ahead [ 30 ] days ⌃⌄". What is typed is an editing in
/// `NumberDrafts`: Look ahead is staged on every keystroke (clamped to the range, the applied value while the text is
/// not a whole number), so the Apply bar comes while typing, and each keystroke that changes the staged value asks
/// for a new preview, with Apply greyed until it lands; Check every commits on Return or when the field loses focus.
/// The field shows the text as typed until Return or focus loss, then the value in effect; Escape puts the field,
/// and Look ahead's staged value, back to what they were when the editing began. The arrows set the value like a
/// keystroke, and the field follows whatever the value becomes from anything but its own typing (`follow`).
private struct NumberRow: View {
    let label: String
    /// What the field and the arrows are called for VoiceOver, such as "Look ahead days".
    let fieldName: String
    let field: NumberDrafts.Field
    /// The value in effect, read by the view that watches the model, so the row follows it.
    let value: Int
    let unit: (Int) -> String
    @ObservedObject var drafts: NumberDrafts
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            // An empty prompt: the field name would show, cut off, whenever the field is emptied.
            TextField(fieldName, text: Binding(get: { drafts.text(field) }, set: { drafts.type($0, in: field) }),
                      prompt: Text(""))
                .labelsHidden()
                .accessibilityLabel(fieldName)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
                .focused($fieldFocused)
                .onSubmit { drafts.commit(field) }
                .onExitCommand { drafts.cancel(field) }
                .onChange(of: fieldFocused) { _, focused in
                    if !focused { drafts.commit(field) }
                }
            Text(unit(value))
            // Reads the model, not `value`: a held arrow repeats before this row is drawn again.
            Stepper(fieldName, value: Binding(get: { drafts.value(field) }, set: { drafts.apply($0, to: field) }),
                    in: drafts.range(field))
                .labelsHidden()
        }
        .onChange(of: value) { _, newValue in drafts.follow(newValue, in: field) }
    }
}
