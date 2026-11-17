import AppKit
import BusySignCore
import SwiftUI

// MARK: - Checkbox

/// A macOS checkbox that can also show the mixed state ("–"). One click calls `action` exactly once and
/// changes nothing by itself: the box keeps showing `tick` until the model hands it a new one. Used instead
/// of `Toggle(sources:isOn:)`, which writes through every source binding on one click. `title` is shown after
/// the box (none by default); `.disabled` greys it out and ignores clicks.
struct MeetingCheckbox: NSViewRepresentable {
    let tick: MeetingsCatalog.Tick
    let accessibilityLabel: String
    var title = ""
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator,
                              action: #selector(Coordinator.clicked(_:)))
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.allowsMixedState = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        let state: NSControl.StateValue = switch tick {
        case .on: .on
        case .off: .off
        case .mixed: .mixed
        }
        context.coordinator.state = state
        context.coordinator.action = action
        button.state = state
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel(accessibilityLabel)
    }

    @MainActor
    final class Coordinator: NSObject {
        var state: NSControl.StateValue = .off
        var action: (@MainActor () -> Void)?

        @objc func clicked(_ sender: NSButton) {
            // AppKit has already stepped the box on (off can even step to mixed). Show the model's state
            // again, also for a click that changes nothing; a change re-renders with the new one.
            sender.state = state
            action?()
        }
    }
}

// MARK: - Rows

/// Width of the disclosure chevron; single rows keep the same space so all checkboxes line up.
private let chevronWidth: CGFloat = 12
/// Width given to every checkbox, so days line up under their series' title.
private let checkboxWidth: CGFloat = 18

/// The Title box at the end of a row, shown when some calendar the row's meetings are copied into shows titles:
/// ticked while the copies may show the meeting's title, unticked for "no title" (`Busy` in every calendar),
/// mixed for a series with both. Disabled, keeping its state, while the row's meetings are not copied at all.
private struct TitleCheckbox: View {
    let tick: MeetingsCatalog.Tick
    let isEnabled: Bool
    let accessibilityLabel: String
    let action: @MainActor () -> Void

    var body: some View {
        MeetingCheckbox(tick: tick, accessibilityLabel: accessibilityLabel, title: "Title", action: action)
            .fixedSize()
            .disabled(!isEnabled)
            .help("Unticked, copies show Busy instead of this title")
    }
}

/// A recurring series, collapsed: chevron, tri-state checkbox, "title · weekdays 10:40 · 21×", the labels its
/// days carry, and its tri-state Title box unless `titleTick` is nil.
struct SeriesRowView: View {
    let title: String
    let pattern: String
    let tick: MeetingsCatalog.Tick
    let labels: [ShownLabel]
    let isExpanded: Bool
    /// The Title box's state; nil when no target of the section shows titles.
    let titleTick: MeetingsCatalog.Tick?
    let onToggle: @MainActor () -> Void
    let onExpand: @MainActor () -> Void
    let onToggleTitle: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onExpand) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: chevronWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(isExpanded ? "Hide days" : "Show days")
            .accessibilityLabel(isExpanded ? "Hide days of \(title)" : "Show days of \(title)")
            MeetingCheckbox(tick: tick, accessibilityLabel: "\(title), series", action: onToggle)
                .fixedSize()
                .frame(width: checkboxWidth)
            HStack(spacing: 6) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("· \(pattern)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onExpand)
            LabelChips(labels: labels)
            if let titleTick {
                TitleCheckbox(tick: titleTick, isEnabled: tick != .off, accessibilityLabel: "\(title), show title",
                              action: onToggleTitle)
            }
        }
    }
}

/// One day of a series, indented under it: checkbox, date and time, the day's own title when it differs from the
/// series', label, and its Title box unless `titleShown` is nil. `title` is the series' title; the checkboxes'
/// accessibility labels use the day's own title when there is one.
struct DayRowView: View {
    let title: String
    /// The day's own title when it reads differently from the series' (a day the organizer renamed); else nil.
    let ownTitle: String?
    let time: String
    let isOn: Bool
    let label: ShownLabel?
    /// The Title box's state; nil when no target of the section shows titles.
    let titleShown: Bool?
    let onToggle: @MainActor () -> Void
    let onToggleTitle: @MainActor () -> Void

    var body: some View {
        let name = ownTitle ?? title
        HStack(spacing: 6) {
            MeetingCheckbox(tick: isOn ? .on : .off, accessibilityLabel: "\(name), \(time)", action: onToggle)
                .fixedSize()
                .frame(width: checkboxWidth)
            Text(time)
                .lineLimit(1)
                .layoutPriority(1)
            if let ownTitle {
                Text("· \(ownTitle)")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            LabelChips(labels: label.map { [$0] } ?? [])
            if let titleShown {
                TitleCheckbox(tick: titleShown ? .on : .off, isEnabled: isOn,
                              accessibilityLabel: "\(name), \(time), show title", action: onToggleTitle)
            }
        }
        .padding(.leading, chevronWidth + 6 + checkboxWidth + 6)
    }
}

/// A single meeting: checkbox, "title · date and time", label, and its Title box unless `titleShown` is nil.
struct SingleRowView: View {
    let title: String
    let time: String
    let isOn: Bool
    let label: ShownLabel?
    /// The Title box's state; nil when no target of the section shows titles.
    let titleShown: Bool?
    let onToggle: @MainActor () -> Void
    let onToggleTitle: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: chevronWidth, height: 1)
            MeetingCheckbox(tick: isOn ? .on : .off, accessibilityLabel: title, action: onToggle)
                .fixedSize()
                .frame(width: checkboxWidth)
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("· \(time)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            LabelChips(labels: label.map { [$0] } ?? [])
            if let titleShown {
                TitleCheckbox(tick: titleShown ? .on : .off, isEnabled: isOn,
                              accessibilityLabel: "\(title), show title", action: onToggleTitle)
            }
        }
    }
}

/// A meeting BusySign does not copy, greyed, without a checkbox: "title · date and time · in Acme" and the
/// reason.
struct NotCopiedRowView: View {
    let title: String
    let detail: String
    let reason: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("· \(detail)")
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            Text(reason)
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Labels

/// A label as the window shows it.
struct ShownLabel {
    let label: MeetingsCatalog.Label
    let text: String
}

/// Small coloured capsules at the end of a row.
private struct LabelChips: View {
    let labels: [ShownLabel]

    var body: some View {
        ForEach(labels, id: \.text) { shown in
            Text(shown.text)
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(color(shown.label))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(color(shown.label).opacity(0.15), in: Capsule())
        }
    }

    private func color(_ label: MeetingsCatalog.Label) -> Color {
        switch label {
        case .added: .green
        case .moved: .blue
        case .removed: .gray
        case .pendingAddition, .pendingRemoval: .orange
        }
    }
}

/// "added", "moved", "removed"; a change still waiting reads "adding…" / "removing…", or "added when syncing
/// resumes" / "removed when syncing resumes" while syncing is paused.
func labelText(_ label: MeetingsCatalog.Label, paused: Bool) -> String {
    switch label {
    case .added: "added"
    case .moved: "moved"
    case .removed: "removed"
    case .pendingRemoval: paused ? "removed when syncing resumes" : "removing…"
    case .pendingAddition: paused ? "added when syncing resumes" : "adding…"
    }
}

/// The labels of a series' days for its collapsed row: one per kind, with the number of days when not every
/// day carries it ("3 added").
func seriesLabels(_ row: MeetingsCatalog.Row, paused: Bool) -> [ShownLabel] {
    let kinds: [MeetingsCatalog.Label] = [.added, .moved, .removed, .pendingAddition, .pendingRemoval]
    return kinds.compactMap { kind in
        let n = row.occurrences.filter { $0.label == kind }.count
        guard n > 0 else { return nil }
        let text = labelText(kind, paused: paused)
        return ShownLabel(label: kind, text: n == row.occurrences.count ? text : "\(n) \(text)")
    }
}

// MARK: - Texts

/// Why an original is not copied, in plain words. `.copiedFrom` names where the same meeting is, which stays
/// true whether or not that row is ticked.
func reasonText(_ reason: SkippedOriginal.Reason, name: (CalendarRef) -> String) -> String {
    switch reason {
    case .excludedByUser: "excluded by you"
    case .declined: "declined"
    case .free: "marked free"
    case .pendingInvitation: "invitation not answered"
    case .allDayNotBusy: "all-day, not busy"
    case .notSyncedYet: "not synced by Calendar yet"
    case let .sameSlot(calendar): "same time in \(name(calendar))"
    case let .copiedFrom(calendar): "same meeting is in \(name(calendar))"
    }
}

/// "weekdays 10:40 · 21×", "Thu 13:00 · 4×", "daily 09:00 · 7×", "from Mon, 16 Nov · 3×"; an all-day series
/// has no time. Times and weekdays in the user's locale and time zone.
func seriesText(_ row: MeetingsCatalog.Row) -> String {
    let starts = row.occurrences.map(\.start)
    let isAllDay = row.occurrences.allSatisfy(\.isAllDay)
    // Every pattern but `irregular` has all starts at the same time of day, so the first one's will do.
    let time = isAllDay ? nil : starts.min()?.formatted(.dateTime.hour().minute())
    func at(_ text: String) -> String {
        time.map { "\(text) \($0)" } ?? text
    }
    let pattern = switch seriesPattern(starts, isAllDay: isAllDay, calendar: .current) {
    case .weekdays: at("weekdays")
    case let .weekly(weekday, _): at(weekdayName(weekday))
    case .daily: at("daily")
    case let .irregular(first): "from \(first.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
    }
    return "\(pattern) · \(row.occurrences.count)×"
}

/// "Thu" for 5 (`Calendar` numbering, 1 is Sunday), in the user's locale.
private func weekdayName(_ weekday: Int) -> String {
    let symbols = Calendar.current.shortWeekdaySymbols
    return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "weekly"
}

/// "Tue, 18 Nov, 10:00 – 11:00", or "Tue, 18 Nov, all day", in the user's locale and time zone.
func timeRangeText(start: Date, end: Date, isAllDay: Bool) -> String {
    let day = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
    if isAllDay {
        // An all-day event ends at the last second of its last day, or at the midnight after it.
        let lastDay = end > start ? end.addingTimeInterval(-1) : start
        if Calendar.current.isDate(start, inSameDayAs: lastDay) {
            return "\(start.formatted(day)), all day"
        }
        let days = (start..<lastDay).formatted(.interval.weekday(.abbreviated).day().month(.abbreviated))
        return "\(days), all day"
    }
    guard end > start else { return start.formatted(day.hour().minute()) }
    return (start..<end).formatted(.interval.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
}
