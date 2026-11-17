import BusySignCore
import SwiftUI

/// The Meetings window: every meeting BusySign copies, or would copy but for the user's choice, by the calendar
/// it comes from, each with a checkbox (a recurring series is one row that opens into its days) and, when a
/// calendar it is copied into shows titles, a Title box for "no title"; then the meetings it does not copy for
/// other reasons, greyed with the reason; then the Busy blocks that go without a meeting row. Rows are
/// identified by the catalog's ids, which are unique within their section only, so every section has its own
/// `ForEach`. Titles come from `AppModel.titles` and, for a day of a series that reads differently from the
/// series, `AppModel.dayTitles`; they are only shown here, and neither they nor the search text are stored, logged
/// or passed on. While changes are staged, the Apply bar is at the bottom.
struct MeetingsView: View {
    @ObservedObject var model: AppModel
    /// Ends editing in Settings before Apply (`ApplyBar.endEditing`).
    let endEditing: @MainActor () -> Void
    /// Revert, with what is typed in Settings (`ApplyBar.revert`).
    let revert: @MainActor () -> Void
    @State private var query = ""
    /// Open series rows. The same series can be in two sections (the same meeting in two calendars), so the
    /// section is part of the key.
    @State private var expanded: Set<OpenRow> = []

    private struct OpenRow: Hashable {
        let section: String
        let row: String
    }

    var body: some View {
        VStack(spacing: 0) {
            if let structureText {
                Label(structureText, systemImage: "info.circle.fill")
                    .foregroundStyle(.blue)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.blue.opacity(0.10))
            }
            if let failureText {
                Label(failureText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.12))
            }
            header
            Divider()
            if result != nil {
                list
            } else {
                emptyState
            }
            if model.staged != nil {
                Divider()
                ApplyBar(model: model, endEditing: endEditing, revert: revert)
            }
        }
        .frame(minWidth: 500, minHeight: 320)
    }

    // MARK: - Header

    /// The last run, if it went ahead; the catalog is empty otherwise.
    private var result: SyncResult? {
        model.lastResult.flatMap { $0.skippedReason == nil ? $0 : nil }
    }

    /// Live words and labels only when the shown result and the mode switch agree: after a switch while paused
    /// no run replaces the result, and the next run is the switch's.
    private var isLive: Bool {
        model.mode == .live && result?.mode == .live
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result == nil ? model.headline : (model.paused ? "Paused · " : "") + summary)
                    .font(.headline)
                if let lastChanges {
                    Text(lastChanges)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search meetings", text: $query, prompt: Text("Search titles"))
                    .labelsHidden()
                    .accessibilityLabel("Search meetings")
                    .textFieldStyle(.roundedBorder)
                    .onExitCommand { query = "" }
            }
            .frame(width: 220)
            .disabled(result == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// "42 meetings copied · 1 not copied"; in Dry run "would be copied". While changes are staged, "Changes not
    /// applied" and no count: the rows show the staged ticks, which nothing has acted on yet.
    private var summary: String {
        guard model.staged == nil else { return "Changes not applied" }
        let copied = model.catalog.copiedCount
        let meetings = copied == 1 ? "meeting" : "meetings"
        let verb = isLive ? "copied" : "would be copied"
        return "\(copied) \(meetings) \(verb) · \(model.catalog.notCopiedCount) not copied"
    }

    /// "Last changes 21:05", with the day when it was not today; Live only.
    private var lastChanges: String? {
        guard isLive, let at = model.liveChanges.at else { return nil }
        let time = Calendar.current.isDateInToday(at)
            ? at.formatted(date: .omitted, time: .shortened)
            : at.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        return "Last changes \(time)"
    }

    /// Something the shown run depended on changed since it started (`structureChangedSinceRun`): the
    /// calendars, look-ahead days, unanswered invitations, a pair set to Nothing or back, or Busy copies removed; the
    /// list is that run's until the next one. Ticks in this window do not count: the rows follow them at once.
    private var structureText: String? {
        guard result != nil, model.structureChangedSinceRun else { return nil }
        let text = "Settings changed — the list updates after the next sync"
        return model.paused ? text + ". Syncing is paused." : text
    }

    /// Labels come from the last live runs that changed something, also when some changes could not be saved
    /// (`LiveChanges`); those may carry a wrong label.
    private var failureText: String? {
        guard isLive, let failed = result?.report?.failures.count, failed > 0 else {
            return nil
        }
        return failed == 1
            ? "1 change could not be saved in the last run; its label may be wrong"
            : "\(failed) changes could not be saved in the last run; their labels may be wrong"
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No meetings to show")
                .font(.title3)
            Text("Meetings show up here after the next sync.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - List

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matches(_ title: String) -> Bool {
        trimmedQuery.isEmpty || title.localizedCaseInsensitiveContains(trimmedQuery)
    }

    private func title(_ localID: String) -> String {
        let title = model.titles[localID] ?? ""
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(no title)" : title
    }

    /// The occurrences of a series share a local id, so the first one's title is the series'.
    private func title(_ row: MeetingsCatalog.Row) -> String {
        title(row.occurrences.first?.localID ?? "")
    }

    /// A day's own title when the copies read it differently from its series' title (`normalizedCopyTitle`): a day
    /// the organizer renamed, whose copies take that title. Nil for a single meeting, while the day's title has not
    /// been read (`AppModel.dayTitles`), or when it reads the same.
    private func ownTitle(_ occurrence: MeetingsCatalog.Occurrence, of row: MeetingsCatalog.Row,
                          in section: MeetingsCatalog.Section) -> String? {
        let day = OccurrenceRef(calendar: section.source, localID: occurrence.localID, start: occurrence.start)
        guard row.isSeries, let own = model.dayTitles[day],
              normalizedCopyTitle(own) != normalizedCopyTitle(title(row)) else { return nil }
        return own
    }

    /// Whether the search shows `row`: its title matches, or for a series one of its days' own titles does.
    private func rowMatches(_ row: MeetingsCatalog.Row, in section: MeetingsCatalog.Section) -> Bool {
        matches(title(row)) || row.occurrences.contains { ownTitle($0, of: row, in: section).map(matches) ?? false }
    }

    private var list: some View {
        let catalog = model.catalog
        let notCopied = catalog.notCopied.filter { matches(title($0.localID)) }
        let noMatch = !trimmedQuery.isEmpty && notCopied.isEmpty
            && catalog.sections.allSatisfy { section in !section.rows.contains { rowMatches($0, in: section) } }
        return List {
            if noMatch {
                Text("No meetings match the search.")
                    .foregroundStyle(.secondary)
            }
            ForEach(catalog.sections) { section in
                sourceSection(section)
            }
            if !notCopied.isEmpty {
                Section {
                    ForEach(notCopied) { item in
                        NotCopiedRowView(
                            title: title(item.localID),
                            detail: timeRangeText(start: item.start, end: item.end, isAllDay: item.isAllDay)
                                + " · in \(model.shortName(item.calendar))",
                            reason: reasonText(item.reason, name: model.shortName)
                        )
                    }
                } header: {
                    Text("Not copied (\(catalog.notCopiedCount))")
                }
            }
            // Title-free, so a search hides them.
            if trimmedQuery.isEmpty && !catalog.removals.isEmpty {
                removalsSection(catalog.removals)
            }
        }
        .listStyle(.inset)
    }

    /// "Acme → Initech  (42)": the meetings from one selected calendar. Hidden while a search matches none.
    @ViewBuilder
    private func sourceSection(_ section: MeetingsCatalog.Section) -> some View {
        let rows = section.rows.filter { rowMatches($0, in: section) }
        if trimmedQuery.isEmpty || !rows.isEmpty {
            Section {
                if rows.isEmpty {
                    Text("No meetings to copy")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    rowViews(row, in: section)
                }
            } header: {
                Text(sectionTitle(section))
            }
        }
    }

    /// "Acme → Initech  (42)"; without the count while changes are staged, as the header (`summary`).
    private func sectionTitle(_ section: MeetingsCatalog.Section) -> String {
        let source = model.shortName(section.source)
        let targets = section.targets.map(model.shortName).joined(separator: ", ")
        let title = targets.isEmpty ? source : "\(source) → \(targets)"
        return model.staged == nil ? title + "  (\(section.count))" : title
    }

    /// A series row and, when open, its days; or a single meeting's row. One click is one `toggle` or
    /// `toggleTitle` call. Title boxes only in a section whose targets include one that shows titles.
    @ViewBuilder
    private func rowViews(_ row: MeetingsCatalog.Row, in section: MeetingsCatalog.Section) -> some View {
        if row.isSeries {
            let key = OpenRow(section: section.id, row: row.id)
            let isOpen = expanded.contains(key)
            SeriesRowView(
                title: title(row),
                pattern: seriesText(row),
                tick: row.tick,
                labels: isLive ? seriesLabels(row, paused: model.paused) : [],
                isExpanded: isOpen,
                titleTick: section.showsTitles ? row.titleTick : nil,
                onToggle: { model.toggle(row) },
                onExpand: {
                    // From the state at the click, not at the last render: two quick clicks open and close.
                    if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
                },
                onToggleTitle: { model.toggleTitle(row) }
            )
            if isOpen {
                ForEach(row.occurrences) { occurrence in
                    DayRowView(
                        title: title(row),
                        ownTitle: ownTitle(occurrence, of: row, in: section),
                        time: timeRangeText(start: occurrence.start, end: occurrence.end,
                                            isAllDay: occurrence.isAllDay),
                        isOn: occurrence.isOn,
                        label: shown(occurrence.label),
                        titleShown: section.showsTitles ? occurrence.titleShown : nil,
                        onToggle: { model.toggle(occurrence, to: !occurrence.isOn) },
                        onToggleTitle: { model.toggleTitle(occurrence, to: !occurrence.titleShown) }
                    )
                }
            }
        } else if let occurrence = row.occurrences.first {
            SingleRowView(
                title: title(occurrence.localID),
                time: timeRangeText(start: occurrence.start, end: occurrence.end, isAllDay: occurrence.isAllDay),
                isOn: occurrence.isOn,
                label: shown(occurrence.label),
                titleShown: section.showsTitles ? occurrence.titleShown : nil,
                onToggle: { model.toggle(occurrence, to: !occurrence.isOn) },
                onToggleTitle: { model.toggleTitle(occurrence, to: !occurrence.titleShown) }
            )
        }
    }

    private func shown(_ label: MeetingsCatalog.Label?) -> ShownLabel? {
        guard isLive else { return nil }
        return label.map { ShownLabel(label: $0, text: labelText($0, paused: model.paused)) }
    }

    /// Busy blocks without a meeting row: what Dry run would delete, or what the last live changes deleted.
    private func removalsSection(_ removals: [MeetingsCatalog.Removal]) -> some View {
        let blocks = removals.reduce(0) { $0 + $1.count }
        return Section {
            ForEach(removals) { removal in
                Text(removalText(removal))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } header: {
            Text(isLive ? "Busy blocks removed (\(blocks))" : "Busy blocks to remove (\(blocks))")
        }
    }

    /// "Initech · Tue, 18 Nov, 10:00 – 11:00"; "2 duplicate Busy blocks · Initech · …".
    private func removalText(_ removal: MeetingsCatalog.Removal) -> String {
        let place = "\(model.shortName(removal.target)) · "
            + timeRangeText(start: removal.start, end: removal.end, isAllDay: removal.isAllDay)
        guard removal.isDuplicate else { return place }
        return "\(removal.count) duplicate Busy \(removal.count == 1 ? "block" : "blocks") · \(place)"
    }
}
