import BusySignCore
import EventKit
import Foundation
import os

private let logger = Logger(subsystem: "io.github.v0rest.busysign", category: "store")

/// One occurrence of an event as a run read it: its calendar, local id and start (`EventSnapshot`). The days of a
/// recurring series share a local id, so the start tells them apart.
struct OccurrenceRef: Hashable, Sendable {
    let calendar: CalendarRef
    let localID: String
    let start: Date
}

/// `CalendarStore` over EventKit. The `EKEventStore` lives inside the actor and no EventKit object
/// leaves it. Logs and failure texts carry counts and identifiers only, never event content. Titles are
/// read into `EventSnapshot.title` for the core, which picks each copy's title, and by `titles(for:)` and
/// `occurrenceTitles(for:)` for the Meetings window; they stay in memory.
actor EventKitStore: CalendarStore {
    private let store = EKEventStore()

    /// A per-action refusal; its reason goes into `ApplyReport.failures`.
    private struct Refusal: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        init(_ refusal: CopyWriteRefusal) { reason = refusal.rawValue }
    }

    // MARK: - Access

    func accessState() async -> AccessState {
        mapAccess(EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess() async -> Bool {
        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            store.requestFullAccessToEvents { @Sendable granted, error in
                if let error {
                    let ns = error as NSError
                    logger.error("access request error \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
                }
                continuation.resume(returning: granted)
            }
        }
        // Reload so sources and calendars appear in this store after a fresh grant; nothing is pending
        // here because `apply` never suspends between staging and committing.
        if granted { store.reset() }
        logger.info("calendar access \(granted ? "granted" : "not granted", privacy: .public)")
        return granted
    }

    private func requireAccess() throws {
        guard mapAccess(EKEventStore.authorizationStatus(for: .event)) == .granted else {
            throw CalendarStoreError.accessNotGranted
        }
    }

    // MARK: - Reading

    func calendars() async throws -> [CalendarInfo] {
        try requireAccess()
        let all = store.calendars(for: .event)
        let raw = all.map { calendar in
            CalendarInfo(
                ref: CalendarRef(id: calendar.calendarIdentifier),
                title: calendar.title,
                accountTitle: calendar.source?.title ?? "",
                accountKind: accountKind(of: calendar.source),
                isWritable: calendar.allowsContentModifications,
                isSuggestedPrimary: false,
                kind: mapKind(calendar.type),
                accountID: calendar.source?.sourceIdentifier ?? "",
                isDelegateAccount: calendar.source?.isDelegate ?? false
            )
        }
        let primaries = mainCalendarIDs(raw, defaultCalendarID: store.defaultCalendarForNewEvents?.calendarIdentifier)
        let infos = raw.map { info -> CalendarInfo in
            var info = info
            info.isSuggestedPrimary = primaries.contains(info.ref.id)
            return info
        }.sorted { ($0.accountTitle, $0.title, $0.ref.id) < ($1.accountTitle, $1.title, $1.ref.id) }
        logger.info("listed \(infos.count, privacy: .public) calendars, \(primaries.count, privacy: .public) suggested")
        return infos
    }

    func events(in calendars: [CalendarRef], window: DateInterval) async throws -> [EventSnapshot] {
        try requireAccess()
        // A nil or empty calendar list would mean "all calendars" to EventKit.
        guard !calendars.isEmpty else { return [] }
        let byID = Dictionary(store.calendars(for: .event).map { ($0.calendarIdentifier, $0) },
                              uniquingKeysWith: { first, _ in first })
        let ekCalendars = try calendars.map { ref in
            guard let calendar = byID[ref.id] else { throw CalendarStoreError.calendarNotFound(id: ref.id) }
            return calendar
        }
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: ekCalendars)
        var result: [EventSnapshot] = []
        var dropped = 0
        var droppedMarked = 0
        for event in store.events(matching: predicate) {
            switch snapshot(of: event) {
            case let .event(snapshot): result.append(snapshot)
            case .dropped: dropped += 1
            case .droppedMarkedWithAttendees: droppedMarked += 1
            case .incomplete:
                let calendarID = event.calendar?.calendarIdentifier ?? "unknown"
                logger.error("incomplete event in calendar \(calendarID, privacy: .public); read rejected")
                throw CalendarStoreError.incompleteEvent(calendarID: calendarID)
            }
        }
        logger.info("""
            read \(result.count, privacy: .public) events from \(ekCalendars.count, privacy: .public) calendars, \
            dropped \(dropped, privacy: .public) cancelled and \(droppedMarked, privacy: .public) marked with attendees
            """)
        return result
    }

    // MARK: - Titles for display

    /// The title of each event, by local id, for the Meetings window on this Mac only; "(no title)" when
    /// the event has none or is gone. The occurrences of a recurring event share a local id and show the
    /// series title; a day's own title comes from `occurrenceTitles(for:)`. Callers never log, store or write
    /// these titles anywhere.
    func titles(for localIDs: [String]) -> [String: String] {
        guard mapAccess(EKEventStore.authorizationStatus(for: .event)) == .granted else { return [:] }
        var result: [String: String] = [:]
        for id in Set(localIDs) {
            result[id] = Self.shownTitle(store.calendarItem(withIdentifier: id)?.title)
        }
        return result
    }

    /// The own title of each of `occurrences`, for the days of a series in the Meetings window on this Mac only:
    /// a day the organizer renamed reads differently from its series, and its copies take that title.
    /// "(no title)" when it has none; one that is gone or moved since its run is left out. One quiet read per
    /// calendar over the span of its occurrences, each event taken the way a run takes it (`snapshot(of:)`), so
    /// local id and start compare equal to the run's. Callers never log, store or write these titles anywhere.
    func occurrenceTitles(for occurrences: [OccurrenceRef]) -> [OccurrenceRef: String] {
        guard mapAccess(EKEventStore.authorizationStatus(for: .event)) == .granted else { return [:] }
        let wanted = Set(occurrences)
        var result: [OccurrenceRef: String] = [:]
        for (ref, days) in Dictionary(grouping: wanted, by: \.calendar) {
            guard let calendar = store.calendar(withIdentifier: ref.id), let first = days.map(\.start).min(),
                  let last = days.map(\.start).max() else { continue }
            // A day on each side, so an occurrence starting at either end is inside the range whatever its length.
            let predicate = store.predicateForEvents(withStart: first.addingTimeInterval(-86_400),
                                                     end: last.addingTimeInterval(86_400), calendars: [calendar])
            for event in store.events(matching: predicate) {
                guard case let .event(read) = snapshot(of: event) else { continue }
                let day = OccurrenceRef(calendar: read.calendar, localID: read.localID, start: read.start)
                guard wanted.contains(day), result[day] == nil else { continue }
                result[day] = Self.shownTitle(read.title)
            }
        }
        return result
    }

    /// `title` as the Meetings window shows it: "(no title)" when it is missing or blank.
    private static func shownTitle(_ title: String?) -> String {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "(no title)" }
        return title
    }

    // MARK: - Writing

    func apply(_ actions: [SyncAction]) async throws -> ApplyReport {
        try requireAccess()
        var report = ApplyReport()
        var alreadyGone = 0
        // No suspension point from here to the commit, so nothing else can interleave with the batch.
        for action in actions {
            do {
                switch action {
                case let .create(spec):
                    try create(spec)
                    report.created += 1
                case let .update(localID, spec):
                    try update(localID, spec)
                    report.updated += 1
                case let .replace(localID, spec):
                    // The old copy is checked first, as an update checked it: one that is not our copy of this
                    // original fails the whole replacement and nothing is written; nil means already gone, which
                    // counts as deleted. Then the new copy, and the old one goes only once that worked, so a Busy
                    // block is never lost. Both are staged and land together in the commit below.
                    let old = try existingCopy(localID, in: try writableCalendar(spec.target), marker: spec.marker)
                    try create(spec)
                    if let old {
                        do {
                            try store.remove(old, span: .thisEvent, commit: false)
                        } catch {
                            // The new copy stays staged; the next run's keep-one rule removes the extra copy.
                            report.created += 1
                            throw error
                        }
                    }
                    report.replaced += 1
                case let .delete(localID, target):
                    if try !delete(localID, in: target) { alreadyGone += 1 }
                    report.deleted += 1
                }
            } catch {
                report.failures.append("\(label(action)): \(reason(error))")
            }
        }
        // Every counted replacement staged at least its create, so it always needs the commit; `alreadyGone`
        // counts plain deletes only.
        if report.created + report.updated + report.replaced + report.deleted - alreadyGone > 0 {
            do {
                try store.commit()
            } catch {
                store.reset()
                let ns = error as NSError
                // Domain and code only: an error's description may quote the events, and copies carry titles.
                logger.error("commit failed \(ns.domain, privacy: .public) \(ns.code, privacy: .public); batch discarded")
                throw CalendarStoreError.commitFailed
            }
        }
        logger.info("""
            applied \(actions.count, privacy: .public) actions: created \(report.created, privacy: .public), \
            updated \(report.updated, privacy: .public), replaced \(report.replaced, privacy: .public), \
            deleted \(report.deleted, privacy: .public) (\(alreadyGone, privacy: .public) already gone), \
            failed \(report.failures.count, privacy: .public)
            """)
        for failure in report.failures {
            logger.error("\(failure, privacy: .public)")
        }
        return report
    }

    private func create(_ spec: CopySpec) throws {
        let calendar = try writableCalendar(spec.target)
        try requireValidMarker(spec.marker)
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        applyCopyShape(to: event, spec: spec)
        try save(event)
    }

    private func update(_ localID: String, _ spec: CopySpec) throws {
        let calendar = try writableCalendar(spec.target)
        try requireValidMarker(spec.marker)
        guard let event = try existingCopy(localID, in: calendar, marker: spec.marker) else {
            throw Refusal(.eventNotFound)
        }
        applyCopyShape(to: event, spec: spec)
        try save(event)
    }

    /// Stages the removal of the copy `localID`; false when there is nothing to remove because the event
    /// is already gone (e.g. another Mac removed it first), which counts as done.
    private func delete(_ localID: String, in target: CalendarRef) throws -> Bool {
        let calendar = try writableCalendar(target)
        guard let event = try existingCopy(localID, in: calendar, marker: nil) else { return false }
        try store.remove(event, span: .thisEvent, commit: false)
        return true
    }

    private func save(_ event: EKEvent) throws {
        do {
            try store.save(event, span: .thisEvent, commit: false)
        } catch {
            event.rollback()
            throw error
        }
    }

    // MARK: - Safety checks

    private func writableCalendar(_ ref: CalendarRef) throws -> EKCalendar {
        guard let calendar = store.calendar(withIdentifier: ref.id),
              calendar.allowedEntityTypes.contains(.event) else { throw Refusal("calendar not found") }
        guard calendar.allowsContentModifications else { throw Refusal("calendar is read-only") }
        return calendar
    }

    private func requireValidMarker(_ marker: String) throws {
        // A copy whose marker does not parse back would never be recognised and be created again every run.
        guard Marker.parse(notes: marker) == marker else { throw Refusal("invalid marker") }
    }

    /// The event `localID` if `copyWriteRefusal` accepts it as one of our copies in `calendar` (no
    /// attendees, a valid marker equal to `marker` when given, in that calendar, not recurring: neither a
    /// series nor a detached occurrence of one, as the read side counts them); nil when no such event exists.
    /// Anything else is refused.
    private func existingCopy(_ localID: String, in calendar: EKCalendar, marker expected: String?) throws -> EKEvent? {
        let event = store.calendarItem(withIdentifier: localID) as? EKEvent
        let facts = event.map {
            ExistingEvent(hasAttendees: $0.hasAttendees, notes: $0.notes,
                          isRecurring: $0.hasRecurrenceRules || $0.isDetached,
                          calendarID: $0.calendar?.calendarIdentifier)
        }
        switch copyWriteRefusal(facts, targetID: calendar.calendarIdentifier, expectedMarker: expected) {
        case nil: return event
        case .eventNotFound: return nil
        case let refusal?: throw Refusal(refusal)
        }
    }

    private func label(_ action: SyncAction) -> String {
        switch action {
        case let .create(spec): "create in \(spec.target.id)"
        case let .update(localID, _): "update \(localID)"
        case let .replace(localID, _): "replace \(localID)"
        case let .delete(localID, _): "delete \(localID)"
        }
    }

    /// Only our own refusal texts or an error's domain and code; never an error's description.
    private func reason(_ error: any Error) -> String {
        if let refusal = error as? Refusal { return refusal.reason }
        let ns = error as NSError
        return "EventKit error \(ns.domain) \(ns.code)"
    }
}
