import Foundation
@testable import BusySignCore

/// In-memory `CalendarStore` for tests. Enforces the same contract as the EventKit store: access must
/// be granted, missing calendars throw on read, reads go through `CopyReading`, and `apply` refuses (as a
/// failure, without mutating) whatever `copyWriteRefusal` refuses or a missing or read-only target; for a
/// replacement that check runs on the old copy before its create. Removals that fail (`setFailsRemoves`) are
/// recorded as failures and leave the event.
actor FakeCalendarStore: CalendarStore {
    private(set) var access: AccessState
    private(set) var calendarInfos: [CalendarInfo]
    /// Events as stored. The `marker` field of a stored event stands for its notes; a read returns it
    /// as decided by `CopyReading`.
    private(set) var storedEvents: [EventSnapshot]
    /// Local ids of stored events that have attendees.
    private(set) var withAttendees: Set<String> = []
    /// Every `apply` call's actions, in call order, recorded before any check.
    private(set) var appliedActions: [[SyncAction]] = []
    private(set) var requestAccessCount = 0
    /// Every `events(in:window:)` call, in call order.
    private(set) var eventCalls: [(calendars: [CalendarRef], window: DateInterval)] = []
    private(set) var inFlightEvents = 0
    private(set) var maxInFlightEvents = 0

    private let grantsAccessOnRequest: Bool
    private var omitted: Set<CalendarRef> = []
    private var calendarsError: (any Error)?
    private var eventsError: (any Error)?
    private var applyError: (any Error)?
    private var failsCreates = false
    private var failsRemoves: Set<String> = []
    private var rewritesTitles: (@Sendable (String) -> String)?
    private var nextLocalID = 1

    init(
        calendars: [CalendarInfo] = [],
        events: [EventSnapshot] = [],
        access: AccessState = .granted,
        grantsAccessOnRequest: Bool = true
    ) {
        self.calendarInfos = calendars
        self.storedEvents = events
        self.access = access
        self.grantsAccessOnRequest = grantsAccessOnRequest
    }

    static func calendar(_ id: String, writable: Bool = true, account: String = "Account",
                         primary: Bool = false) -> CalendarInfo {
        CalendarInfo(ref: CalendarRef(id: id), title: id, accountTitle: account, accountKind: "CalDAV",
                     isWritable: writable, isSuggestedPrimary: primary)
    }

    // MARK: - Test controls

    func setAccess(_ state: AccessState) { access = state }
    func setCalendarsError(_ error: (any Error)?) { calendarsError = error }
    func setEventsError(_ error: (any Error)?) { eventsError = error }
    /// Thrown by `apply` after recording the actions and before changing anything (a failed commit).
    func setApplyError(_ error: (any Error)?) { applyError = error }
    /// Hides a calendar: absent from `calendars()`, "not found" for `events` and `apply`.
    func omit(_ calendar: CalendarRef) { omitted.insert(calendar) }
    func removeAllEvents(in calendar: CalendarRef) { storedEvents.removeAll { $0.calendar == calendar } }
    /// Makes every create fail with a recorded failure, plain ones and the create of a replacement.
    func setFailsCreates(_ fails: Bool) { failsCreates = fails }
    /// Makes every removal of these stored events fail with a recorded failure and leave the event, plain
    /// deletes and the delete half of a replacement alike; the new copy of such a replacement stays and counts
    /// as created, as in the EventKit store. An id that is already gone still counts as removed.
    func setFailsRemoves(_ localIDs: Set<String>) { failsRemoves = localIDs }
    /// Makes every new copy, plain creates and the create of a replacement alike, store `rewrite(spec.title)`
    /// instead of `spec.title` (a server that rewrites titles); nil stores the spec's title again.
    func setRewritesTitles(_ rewrite: (@Sendable (String) -> String)?) { rewritesTitles = rewrite }
    func addEvents(_ events: [EventSnapshot], withAttendees attendees: Bool = false) {
        storedEvents += events
        if attendees { withAttendees.formUnion(events.map(\.localID)) }
    }

    // MARK: - CalendarStore

    func accessState() async -> AccessState { access }

    func requestAccess() async -> Bool {
        requestAccessCount += 1
        if access == .notDetermined { access = grantsAccessOnRequest ? .granted : .denied }
        return access == .granted
    }

    func calendars() async throws -> [CalendarInfo] {
        guard access == .granted else { throw CalendarStoreError.accessNotGranted }
        if let calendarsError { throw calendarsError }
        return visibleCalendars
    }

    func events(in calendars: [CalendarRef], window: DateInterval) async throws -> [EventSnapshot] {
        eventCalls.append((calendars, window))
        inFlightEvents += 1
        maxInFlightEvents = max(maxInFlightEvents, inFlightEvents)
        defer { inFlightEvents -= 1 }
        for _ in 0..<20 { await Task.yield() }
        guard access == .granted else { throw CalendarStoreError.accessNotGranted }
        if let eventsError { throw eventsError }
        let present = Set(visibleCalendars.map(\.ref))
        if let missing = calendars.first(where: { !present.contains($0) }) {
            throw CalendarStoreError.calendarNotFound(id: missing.id)
        }
        let wanted = Set(calendars)
        return storedEvents.compactMap { stored in
            guard wanted.contains(stored.calendar), stored.start < window.end, stored.end > window.start else {
                return nil
            }
            var event = stored
            switch CopyReading(hasAttendees: withAttendees.contains(stored.localID), notes: stored.marker) {
            case let .copy(marker): event.marker = marker
            case .drop: return nil
            case .original: event.marker = nil
            }
            return event
        }
    }

    func apply(_ actions: [SyncAction]) async throws -> ApplyReport {
        appliedActions.append(actions)
        guard access == .granted else { throw CalendarStoreError.accessNotGranted }
        if let applyError { throw applyError }

        var report = ApplyReport()
        for action in actions {
            switch action {
            case let .create(spec):
                if let problem = createProblem(spec) {
                    report.failures.append("create in \(spec.target.id): \(problem)")
                } else {
                    insert(spec)
                    report.created += 1
                }
            case let .replace(localID, spec):
                // As in the EventKit store: the old copy is checked as an update checked it, before anything is
                // written; then the new copy, and the old one goes only once that worked.
                let refusal = copyRefusal(localID, target: spec.target, marker: spec.marker)
                if let problem = targetProblem(spec.target)
                    ?? refusal.flatMap({ $0 == .eventNotFound ? nil : $0.rawValue }) ?? createProblem(spec) {
                    report.failures.append("replace \(localID): \(problem)")
                } else {
                    insert(spec)
                    if removalFails(localID) {
                        // The new copy stays; the next run's keep-one rule removes the extra copy.
                        report.created += 1
                        report.failures.append("replace \(localID): remove failed")
                    } else {
                        // An old copy that is already gone counts as deleted.
                        storedEvents.removeAll { $0.localID == localID && $0.calendar == spec.target }
                        report.replaced += 1
                    }
                }
            case let .update(localID, spec):
                if let problem = targetProblem(spec.target)
                    ?? copyRefusal(localID, target: spec.target, marker: spec.marker)?.rawValue {
                    report.failures.append("update \(localID): \(problem)")
                } else if Marker.parse(notes: spec.marker) != spec.marker {
                    report.failures.append("update \(localID): invalid marker")
                } else if let index = storedEvents.firstIndex(where: { $0.localID == localID }) {
                    storedEvents[index].start = spec.start
                    storedEvents[index].end = spec.end
                    storedEvents[index].isAllDay = spec.isAllDay
                    // The spec's marker becomes the notes, as in the EventKit store.
                    storedEvents[index].marker = spec.marker
                    report.updated += 1
                }
            case let .delete(localID, target):
                if let problem = targetProblem(target) {
                    report.failures.append("delete \(localID): \(problem)")
                } else if let refusal = copyRefusal(localID, target: target, marker: nil), refusal != .eventNotFound {
                    report.failures.append("delete \(localID): \(refusal.rawValue)")
                } else if removalFails(localID) {
                    report.failures.append("delete \(localID): remove failed")
                } else {
                    // An event that is already gone counts as deleted, as in the EventKit store.
                    storedEvents.removeAll { $0.localID == localID }
                    report.deleted += 1
                }
            }
        }
        return report
    }

    // MARK: - Checks

    private var visibleCalendars: [CalendarInfo] {
        calendarInfos.filter { !omitted.contains($0.ref) }
    }

    /// Why a copy `spec` may not be created, in the EventKit store's order: target, marker, then the save.
    private func createProblem(_ spec: CopySpec) -> String? {
        if let problem = targetProblem(spec.target) { return problem }
        if Marker.parse(notes: spec.marker) != spec.marker { return "invalid marker" }
        return failsCreates ? "create failed" : nil
    }

    /// Whether removing the stored event `localID` fails (`setFailsRemoves`); never for one that is already gone.
    private func removalFails(_ localID: String) -> Bool {
        failsRemoves.contains(localID) && storedEvents.contains { $0.localID == localID }
    }

    /// Stores a new copy `spec` under a fresh local id, titled `spec.title`, or as `setRewritesTitles` rewrites it.
    private func insert(_ spec: CopySpec) {
        storedEvents.append(EventSnapshot(
            calendar: spec.target, localID: "fake-\(nextLocalID)", externalID: nil,
            occurrenceDate: spec.start, isRecurringOccurrence: false, start: spec.start,
            end: spec.end, isAllDay: spec.isAllDay, availability: .busy, myResponse: .none,
            marker: spec.marker, title: rewritesTitles.map { $0(spec.title) } ?? spec.title))
        nextLocalID += 1
    }

    private func targetProblem(_ target: CalendarRef) -> String? {
        guard let info = visibleCalendars.first(where: { $0.ref == target }) else { return "calendar not found" }
        return info.isWritable ? nil : "calendar is read-only"
    }

    /// Why the event `localID` may not be changed as a copy in `target`; `marker` nil accepts any valid marker.
    private func copyRefusal(_ localID: String, target: CalendarRef, marker: String?) -> CopyWriteRefusal? {
        let facts = storedEvents.first { $0.localID == localID }.map {
            ExistingEvent(hasAttendees: withAttendees.contains($0.localID), notes: $0.marker,
                          isRecurring: $0.isRecurringOccurrence, calendarID: $0.calendar.id)
        }
        return copyWriteRefusal(facts, targetID: target.id, expectedMarker: marker)
    }
}
