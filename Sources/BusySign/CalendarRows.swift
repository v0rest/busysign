import BusySignCore
import SwiftUI

/// "Calendars to sync" in Settings: one row per account's main calendar, plus every selected calendar,
/// by name, with a checkbox and a short name renamed in place; the other writable calendars behind a
/// disclosure that starts collapsed; a line per selected calendar that Calendar no longer lists. Read-only,
/// birthday and subscription calendars are not shown unless selected (`calendarList`). Nothing is ticked
/// until the user ticks it. Ticks, "Remove from selection" and names are staged (`AppModel.staged`): the
/// checkboxes show the staged selection, and a calendar unticked before Apply keeps its row, so it can be ticked
/// again; a missing calendar's line goes with its staged removal.
struct CalendarsSection: View {
    @ObservedObject var model: AppModel
    /// The short names being typed, passed on to the rows.
    let names: NameDrafts
    @State private var showsOther = false

    var body: some View {
        let ticked = model.effective.selected.map(\.id)
        let list = model.settingsCalendarList
        Section("Calendars to sync") {
            statusLine
            ForEach(byName(list.main), id: \.ref.id) { calendar in
                CalendarRow(
                    model: model,
                    names: names,
                    calendar: calendar,
                    isSelected: selection(calendar),
                    isLocked: isLocked(calendar)
                )
            }
            ForEach(missingIDs(calendarList(model.calendars, selectedIDs: ticked)), id: \.self) { id in
                missingLine(id)
            }
            if !list.other.isEmpty {
                DisclosureGroup("Other calendars (\(list.other.count))", isExpanded: $showsOther) {
                    ForEach(list.other, id: \.ref.id) { calendar in
                        OtherCalendarRow(calendar: calendar, name: model.shortName(calendar.ref),
                                         ownName: model.ownName(calendar.ref),
                                         isSelected: selection(calendar), isLocked: isLocked(calendar))
                    }
                }
            }
        }
        // A rename field goes with its row (`NameDrafts.keep`); the staged name went back with it (`AppModel.stage`).
        .onChange(of: list.main.map(\.ref)) { _, rows in names.keep(Set(rows)) }
    }

    @ViewBuilder
    private var statusLine: some View {
        if model.access != .granted {
            Text("Calendars appear here once BusySign has calendar access.")
                .foregroundStyle(.secondary)
        } else if let problem = model.calendarsError {
            Label("Calendars could not be listed: \(problem)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else if model.effective.selected.count < 2 {
            Label(SyncEngine.needTwo, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    /// By the name shown, then by id.
    private func byName(_ calendars: [CalendarInfo]) -> [CalendarInfo] {
        calendars.sorted { a, b in
            let order = model.shortName(a.ref).localizedStandardCompare(model.shortName(b.ref))
            return order == .orderedSame ? a.ref.id < b.ref.id : order == .orderedAscending
        }
    }

    // MARK: - Selection

    /// Ticking and unticking are staged and ask nothing: the bar shows the Busy blocks Apply would remove.
    private func selection(_ calendar: CalendarInfo) -> Binding<Bool> {
        Binding(get: { model.isSelected(calendar) }, set: { model.select(calendar, on: $0) })
    }

    /// Without access the list may be stale. A selected calendar that became read-only can be unticked and,
    /// until Apply, ticked again, but never ticked anew, or the engine would skip forever.
    private func isLocked(_ calendar: CalendarInfo) -> Bool {
        model.access != .granted
            || (!calendar.isWritable && !model.isSelected(calendar) && !model.applied.selected.contains(calendar.ref))
    }

    // MARK: - Missing calendars

    /// Staged-selected calendars that Calendar no longer lists; only meaningful after a good listing, since an
    /// empty or failed one would report every selected calendar.
    private func missingIDs(_ list: CalendarList) -> [String] {
        guard model.access == .granted, model.calendarsError == nil, !model.calendars.isEmpty else { return [] }
        return list.missingSelectedIDs
    }

    private func missingLine(_ id: String) -> some View {
        HStack {
            Label("\(model.shortName(CalendarRef(id: id))) is no longer in Calendar.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Spacer()
            Button("Remove from selection") { model.forgetMissingCalendar(id: id) }
        }
    }
}

/// A calendar to sync: checkbox, short name, and the account (and the calendar's own title, when it goes by
/// another name and, for a main calendar, the title says more than "Calendar" or an address) in secondary
/// text, left out when it reads like the name; then, on a ticked calendar whose real events have not changed
/// for a while (`quietCalendars`), a quiet note. The pencil, or a double-click on the name, opens a field with
/// the calendar's own name (without what tells clashing names apart); every keystroke stages the name typed
/// (`NameDrafts`), so the Apply bar comes while typing. Return, the checkmark and focus loss close the field; Escape
/// closes it and puts back what was staged when it opened. An empty name goes back to the default. A name
/// another calendar already goes by is allowed, with a hint under the field; the names are then told apart. A
/// ticked calendar has a line below for each other ticked calendar that Calendar lists, in selection order,
/// "Blocks from <that calendar> show", with what the Busy blocks BusySign adds to it for that calendar's meetings
/// show, or Nothing for no blocks at all; none while there is no such calendar. A staged rename shows on this row
/// only (`AppModel.stagedOwnName`) until Apply; the picker lines show the staged choices.
private struct CalendarRow: View {
    @ObservedObject var model: AppModel
    /// The name being typed is `names.draft(for: calendar.ref)`; nil while not renaming.
    @ObservedObject var names: NameDrafts
    let calendar: CalendarInfo
    let isSelected: Binding<Bool>
    let isLocked: Bool
    @FocusState private var nameFocused: Bool

    var body: some View {
        let staged = model.stagedOwnName(calendar.ref)
        let name = staged ?? model.shortName(calendar.ref)
        let ownName = staged ?? model.ownName(calendar.ref)
        VStack(alignment: .leading, spacing: 2) {
            row(name: name, ownName: ownName)
            if let draft = names.draft(for: calendar.ref),
               let other = model.calendarNamed(draft, otherThan: calendar.ref) {
                Text("Name already used by \(other)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 24)
            }
            if isSelected.wrappedValue {
                ForEach(sources, id: \.self) { source in
                    copiesShow(from: source, name: name)
                        .padding(.leading, 24)
                }
            }
        }
    }

    /// The other ticked calendars (staged ticks included) that Calendar lists, in selection order: where the Busy
    /// blocks BusySign adds to this calendar come from, one "Blocks from … show" line each.
    private var sources: [CalendarRef] {
        let listed = Set(model.calendars.map(\.ref))
        return model.effective.selected.filter { $0 != calendar.ref && listed.contains($0) }
    }

    /// "Blocks from Acme show", by the name shown here: the picker of the route from `source` to this calendar,
    /// on its own line, so the row above keeps its width.
    private func copiesShow(from source: CalendarRef, name: String) -> some View {
        let route = CopyRoute(source: source, target: calendar.ref)
        let label = "Blocks from \(model.shortName(source)) show"
        return Picker(label, selection: Binding(
            get: { model.effective.copyTitleFormats[route] ?? .busyOnly },
            set: { model.setCopyTitleFormat($0, for: route) }
        )) {
            ForEach(CopyTitleFormat.allCases, id: \.self) { format in
                Text(optionLabel(format)).tag(format)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .help(copiesShowHelp(source: source, name: name))
        .accessibilityLabel("\(label) in \(name)")
    }

    private func optionLabel(_ format: CopyTitleFormat) -> String {
        switch format {
        case .nothing: "Nothing"
        case .busyOnly: "Busy only"
        case .title: "Title"
        case .sourceAndTitle: "Source: Title"
        }
    }

    /// Calendar names only, never a meeting's title: `source` by the name shown here, and in the example by its own
    /// name (`ownName`), the label its copies carry; `<title>` is literal. Nothing is the one choice that shows no
    /// title because it adds no block at all.
    private func copiesShowHelp(source: CalendarRef, name: String) -> String {
        "Busy blocks for \(model.shortName(source)) meetings in \(name) show \"Busy\", the meeting's title, or "
            + "\"\(model.ownName(source)): <title>\"; Nothing adds no Busy blocks for them in \(name). "
            + "Meetings marked Private in Outlook or Google are not recognised; hide their titles in Meetings."
    }

    private func row(name: String, ownName: String) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: isSelected) { Text(name) }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isLocked)
            if let draft = names.draft(for: calendar.ref) {
                TextField("Short name", text: Binding(get: { names.draft(for: calendar.ref) ?? draft },
                                                      set: { names.type($0, for: calendar.ref) }),
                          prompt: Text("Short name"))
                    .labelsHidden()
                    .accessibilityLabel("Short name")
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 100, maxWidth: 180)
                    .focused($nameFocused)
                    .onSubmit(endRename)
                    .onExitCommand { names.cancel(calendar.ref) }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { endRename() }
                    }
                    .onAppear { nameFocused = true }
            } else {
                Text(name)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .onTapGesture(count: 2) { names.open(calendar.ref, with: ownName) }
            }
            if let detail = detail(name: name, ownName: ownName) {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(detail)
            }
            // Only on a ticked row: the set changes only with runs that go ahead, and unticking may leave none.
            if isSelected.wrappedValue, model.quietCalendars.contains(calendar.ref) {
                // Never truncated: when the row is narrow, the account before it truncates instead.
                Label(model.quietNote, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
                    .help(model.quietNoteHelp)
            }
            Spacer(minLength: 0)
            // Two buttons, so a click that first ends editing by taking focus never reopens the field.
            if names.draft(for: calendar.ref) == nil {
                Button { names.open(calendar.ref, with: ownName) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Rename")
                    .accessibilityLabel("Rename \(name)")
            } else {
                Button(action: endRename) { Image(systemName: "checkmark") }
                    .buttonStyle(.borderless)
                    .help("Save name")
                    .accessibilityLabel("Save name")
            }
        }
    }

    /// Nil when there is nothing to add to the name. A main calendar's title is left out when it is
    /// "Calendar", the account's title or an address, which say nothing the account does not; so is a part
    /// the shown name already carries after " · ".
    private func detail(name: String, ownName: String) -> String? {
        let title = calendar.title
        let titleSaysMore = calendar.isSuggestedPrimary
            ? title != "Calendar" && title != calendar.accountTitle && !title.contains("@")
            : title != calendar.accountTitle
        let parts = (titleSaysMore && !namesMatch(title, ownName) ? [title] : []) + [calendar.accountTitle]
        let place = notInName(parts, name).joined(separator: " · ")
        let shown = place.isEmpty || namesMatch(place, name) || namesMatch(place, ownName) ? nil : place
        guard !calendar.isWritable else { return shown }
        return shown.map { "\($0) (read-only)" } ?? "read-only"
    }

    /// Closes the field; the name typed is staged already, keystroke by keystroke (`rename`): typing back the name
    /// the field started with stages nothing new, and the applied or shown one, in any case, leaves no rename staged,
    /// so a default name keeps following the account. Nothing without an editing (`NameDrafts.end`).
    private func endRename() {
        names.end(calendar.ref)
    }
}

/// A writable calendar that is not its account's main one: checkbox with its name (the one the user gave it,
/// else its own title), the account in secondary text unless it reads like the name. Once ticked it moves up
/// to the calendars to sync, where it can be renamed.
private struct OtherCalendarRow: View {
    let calendar: CalendarInfo
    /// `shortName`: never a default account name here, since these are not main calendars.
    let name: String
    /// `ownName`: the name before clashing names are told apart.
    let ownName: String
    let isSelected: Binding<Bool>
    let isLocked: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: isSelected) { Text(name).lineLimit(1) }
                .toggleStyle(.checkbox)
                .disabled(isLocked)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(detail)
            }
            Spacer(minLength: 0)
        }
    }

    /// The account, with the calendar's own title in front when the user renamed it; not a part the shown name
    /// already carries after " · ".
    private var detail: String? {
        let parts = (namesMatch(ownName, calendar.title) ? [] : [calendar.title]) + [calendar.accountTitle]
        let place = notInName(parts, name).joined(separator: " · ")
        return place.isEmpty || namesMatch(place, name) || namesMatch(place, ownName) ? nil : place
    }
}

/// The non-empty `parts` of a row's secondary text that `name` does not already carry after " · ", as told
/// apart by `displayNames` ("Initech · iCloud" needs no "iCloud" beside it).
private func notInName(_ parts: [String], _ name: String) -> [String] {
    let carried = name.components(separatedBy: " · ").dropFirst()
    return parts.filter { part in !part.isEmpty && !carried.contains { namesMatch($0, part) } }
}
