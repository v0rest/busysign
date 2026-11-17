import Foundation

public enum SyncMode: String, Codable, Sendable {
    case dryRun, live
}

public struct SyncResult: Sendable, Equatable {
    public var at: Date
    public var mode: SyncMode
    public var planned: [SyncAction]
    public var report: ApplyReport?
    public var skippedReason: String?
    public var stale: [CalendarRef]
    /// Per selected target: marked copies in the window after this run's plan. Empty on skipped runs.
    public var mirrored: [CalendarRef: Int]
    /// Selected calendars whose empty read was accepted on this run, once the empty-read hold had passed,
    /// in selection order.
    public var emptiedCalendars: [CalendarRef]
    /// The plan as one entry per target and marker, sorted by start, then target id. Empty on skipped runs.
    public var changes: [PlannedChange]
    /// Originals that produce no copy and why, sorted by start. Empty on skipped runs.
    public var notBusy: [SkippedOriginal]
    /// Every copy the selection calls for after exclusions, already there or planned, sorted by start,
    /// then target id. Empty on skipped runs.
    public var mirroredItems: [MirroredItem]
    /// Copy slots that hold only copies an earlier live run of this engine wrote (the successor of a replacement, a
    /// created copy), one of which reads another title than the wanted one although that run wrote the wanted
    /// title (`SyncEngine`): the server rewrote it, so no retitle is planned for them. Never a slot that wants
    /// `Busy`: its copy is retitled instead (`heldRetitles`). 0 on skipped runs.
    public var retitlesNotSticking: Int

    public init(
        at: Date,
        mode: SyncMode,
        planned: [SyncAction] = [],
        report: ApplyReport? = nil,
        skippedReason: String? = nil,
        stale: [CalendarRef] = [],
        mirrored: [CalendarRef: Int] = [:],
        emptiedCalendars: [CalendarRef] = [],
        changes: [PlannedChange] = [],
        notBusy: [SkippedOriginal] = [],
        mirroredItems: [MirroredItem] = [],
        retitlesNotSticking: Int = 0
    ) {
        self.at = at
        self.mode = mode
        self.planned = planned
        self.report = report
        self.skippedReason = skippedReason
        self.stale = stale
        self.mirrored = mirrored
        self.emptiedCalendars = emptiedCalendars
        self.changes = changes
        self.notBusy = notBusy
        self.mirroredItems = mirroredItems
        self.retitlesNotSticking = retitlesNotSticking
    }

    /// Planned creates and deletes; updates are not counted.
    public var plannedCounts: (add: Int, remove: Int) {
        var counts = (add: 0, remove: 0)
        for action in planned {
            switch action {
            case .create: counts.add += 1
            case .delete: counts.remove += 1
            case .update, .replace: break
            }
        }
        return counts
    }

    /// Planned retitles: the `.retitle` entries of `changes`. 0 on skipped runs.
    public var plannedRetitles: Int {
        changes.filter { $0.kind == .retitle }.count
    }
}

/// Number of marked copies per selected target that overlap `window` once `planned` is applied:
/// existing copies not planned for deletion, plus planned creates.
public func mirroredCountsPerTarget(
    events: [EventSnapshot], planned: [SyncAction], selected: [CalendarRef], window: DateInterval
) -> [CalendarRef: Int] {
    var deleted = Set<String>()
    for case let .delete(localID, _) in planned { deleted.insert(localID) }
    var counts: [CalendarRef: Int] = [:]
    for target in selected { counts[target] = 0 }
    for e in events where e.marker != nil && e.start < window.end && e.end > window.start
        && !deleted.contains(e.localID) && counts[e.calendar] != nil {
        counts[e.calendar, default: 0] += 1
    }
    for case let .create(spec) in planned where counts[spec.target] != nil {
        counts[spec.target, default: 0] += 1
    }
    return counts
}

/// Runs one sync cycle against a `CalendarStore`. Any doubt about the data means no writes this run.
public actor SyncEngine {
    private let store: CalendarStore
    private let now: @Sendable () -> Date

    /// Per calendar: non-copy events read on the last run that went ahead.
    private var lastRealCount: [CalendarRef: Int] = [:]
    /// When the empty-read guard first fired for a calendar that has been empty since.
    private var guardFiredAt: [CalendarRef: Date] = [:]
    /// Per copy slot (`CopySpec.slotKey`): what a live run last wrote there (`SentTitle`), the digest of the title,
    /// never the title itself, and the local ids of every copy the slot held when that write was planned (none
    /// for a create). Every planned create and update writes the wanted title, so each records its slot, from
    /// runs whose apply returned, per-item failures included; an apply that throws saved nothing and records none.
    /// Once none of those earlier copies is left, a copy that reads another title than the wanted one while the
    /// wanted title is the one recorded was written by this engine and rewritten by the server, so it is not
    /// retitled again while this engine lives (`heldRetitles`): such a server would otherwise get a replacement
    /// every run. While an earlier copy is still there (a write or a removal failed), nothing is held and keep-one
    /// with an ordinary retitle settles the slot, so an old title is never left in place. A slot that wants `Busy`
    /// is never held, whatever is recorded for it: a titled copy there may not be this engine's (a second Mac with
    /// other settings, a copy the server restored, a delegate's edit), and a title the user hid must never stay
    /// showing; a server that rewrites `Busy` itself gets one replacement per run instead. A new wanted title (a
    /// rename, another format) has another digest and goes out once.
    private var titlesSent: [String: SentTitle] = [:]
    /// Previews only: per calendar a preview found held by the empty-read guard, when a preview first found it so
    /// (`preview`). Only a run of previews that each read a calendar and find it held keeps its sighting: a preview
    /// drops it when it finds the calendar not held or does not read it (not in its selection, skipped, syncing
    /// stops), and `forgetPreviewHolds` drops them all. Dropping only ever makes a wait start over. Runs never read
    /// or write it.
    private var previewHeldSince: [CalendarRef: Date] = [:]
    private let emptyReadHold: TimeInterval
    /// FIFO lock: `runOnce`, `removeAllCopies` and `preview` never overlap.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public static let accessNeeded = "Calendar access needed"
    public static let needTwo = "Tick at least two calendars"
    public static let missing = "A selected calendar is missing"
    public static let readOnly = "A selected calendar is read-only"
    public static let readFailed = "Could not read calendars"
    public static let emptyRead = "A calendar returned no events; waiting before removing busy blocks"
    public static let saveFailed = "Saving to Calendar failed"

    public init(store: CalendarStore, now: @escaping @Sendable () -> Date, emptyReadHold: TimeInterval = 300) {
        self.store = store
        self.emptyReadHold = emptyReadHold
        self.now = now
    }

    private static func reason(for error: any Error) -> String {
        guard let storeError = error as? CalendarStoreError else { return readFailed }
        if storeError == .accessNotGranted { return accessNeeded }
        return storeError.errorDescription ?? readFailed
    }

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private static func window(from now: Date, days: Int) -> DateInterval {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(Double(days) * 86400)
        return DateInterval(start: start, end: max(end, start))
    }

    /// Where `removeAllCopies` looks for copies, and the preview counts the ones Apply removes: today to +400 days.
    private static func removalWindow(from now: Date) -> DateInterval {
        window(from: now, days: 400)
    }

    public func runOnce(
        settings: SyncSettings,
        mode: SyncMode,
        tracker: ChangeTracker,
        staleThreshold: TimeInterval
    ) async -> (result: SyncResult, tracker: ChangeTracker) {
        await acquire()
        defer { release() }
        return await runOnceLocked(settings: settings, mode: mode, tracker: tracker, staleThreshold: staleThreshold)
    }

    private func runOnceLocked(
        settings: SyncSettings,
        mode: SyncMode,
        tracker: ChangeTracker,
        staleThreshold: TimeInterval
    ) async -> (result: SyncResult, tracker: ChangeTracker) {
        let at = now()
        func skip(_ reason: String) -> (result: SyncResult, tracker: ChangeTracker) {
            (SyncResult(at: at, mode: mode, skippedReason: reason), tracker)
        }

        var result: SyncResult
        let events: [EventSnapshot]
        let window: DateInterval
        switch await plan(settings: settings, mode: mode, at: at) {
        case let .skipped(reason):
            return skip(reason)
        case let .held(memory, _, _):
            remember(memory)
            return skip(Self.emptyRead)
        case let .planned(plannedResult, readEvents, readWindow, memory):
            remember(memory)
            result = plannedResult
            events = readEvents
            window = readWindow
        }

        let selected = settings.selected
        var newTracker = tracker
        for ref in selected { newTracker.observe(events, in: ref, at: at, window: window) }
        result.stale = newTracker.stale(selected, at: at, threshold: staleThreshold)

        if mode == .live {
            let planned = result.planned
            do {
                // The store never updates a copy: each planned update is executed as a replacement. `planned`
                // and everything described from it keep saying update.
                result.report = try await store.apply(replacingUpdates(planned))
                // A create's slot held no copy when it was planned, so it records none.
                let slots = copiesBySlot(events)
                for action in planned {
                    switch action {
                    case let .create(spec), let .update(_, spec), let .replace(_, spec):
                        let earlier = slots[CopyKey(target: spec.target, marker: spec.marker)] ?? []
                        titlesSent[spec.slotKey] = SentTitle(digest: Marker.digest(of: spec.title),
                                                             earlierCopies: Set(earlier.map(\.localID)))
                    case .delete: break
                    }
                }
            } catch {
                // Nothing was written, so this counts as a skipped run.
                result.skippedReason = (error as? CalendarStoreError) == .accessNotGranted ? Self.accessNeeded : Self.saveFailed
                result.mirrored = [:]
                result.changes = []
                result.notBusy = []
                result.mirroredItems = []
                result.retitlesNotSticking = 0
            }
        }
        return (result, newTracker)
    }

    /// The empty-read guard's memory: `lastRealCount` and `guardFiredAt`.
    private struct EmptyReadMemory {
        var lastRealCount: [CalendarRef: Int]
        var guardFiredAt: [CalendarRef: Date]
    }

    /// A run up to its writes (`plan(settings:mode:at:pastHold:)`).
    private enum Planning {
        /// The run skips for this reason before the empty-read guard looks at a read.
        case skipped(String)
        /// The empty-read guard holds the run back (`emptyRead`). `memory`: the guard's memory after this read.
        /// `calendars`: the ones it holds now, in selection order (not one whose hold has passed already).
        /// `pastHold`: when asked for, the plan of the run once the hold has passed, which accepts every empty read
        /// held now, without `stale` calendars or a report; else nil.
        case held(memory: EmptyReadMemory, calendars: [CalendarRef], pastHold: SyncResult?)
        /// The run goes ahead: its result without `stale` calendars or a report, the events it read in `window`,
        /// and the guard's memory after this read.
        case planned(result: SyncResult, events: [EventSnapshot], window: DateInterval, memory: EmptyReadMemory)
    }

    private func remember(_ memory: EmptyReadMemory) {
        lastRealCount = memory.lastRealCount
        guardFiredAt = memory.guardFiredAt
    }

    /// Reads the calendars and events of `settings` and plans the run at `at`, as `runOnce` does before it writes
    /// anything, from the engine's state as it is (the empty-read guard, `titlesSent`) and without changing it:
    /// what the guard would remember after this read comes back in `Planning`, for a run to keep. With `pastHold`,
    /// a run the guard holds back is planned all the same, as the run once the hold has passed: the same read,
    /// with every calendar held now emptied.
    private func plan(settings: SyncSettings, mode: SyncMode, at: Date, pastHold: Bool = false) async -> Planning {
        guard await store.accessState() == .granted else { return .skipped(Self.accessNeeded) }
        let selected = settings.selected
        guard Set(selected).count >= 2 else { return .skipped(Self.needTwo) }

        let infos: [CalendarInfo]
        do { infos = try await store.calendars() } catch { return .skipped(Self.reason(for: error)) }
        for ref in selected {
            guard let info = infos.first(where: { $0.ref == ref }) else { return .skipped(Self.missing) }
            guard info.isWritable else { return .skipped(Self.readOnly) }
        }

        let window = Self.window(from: at, days: settings.lookAheadDays)
        let events: [EventSnapshot]
        do {
            let selectedSet = Set(selected)
            events = try await store.events(in: selected, window: window).filter { selectedSet.contains($0.calendar) }
        } catch {
            return .skipped(Self.reason(for: error))
        }

        // Empty-read guard, on a copy of its memory.
        var memory = EmptyReadMemory(lastRealCount: lastRealCount, guardFiredAt: guardFiredAt)
        var realCounts: [CalendarRef: Int] = [:]
        for ref in selected {
            realCounts[ref] = events.filter { $0.calendar == ref && $0.marker == nil }.count
        }
        // A non-zero read is recorded even when this run ends up skipped; zero counts are not.
        for ref in selected {
            if let n = realCounts[ref], n > 0 {
                memory.lastRealCount[ref] = n
                memory.guardFiredAt[ref] = nil
            }
        }
        var guardTripped = false
        var emptied: [CalendarRef] = []
        // Every empty read the guard looks at, held now or not: the run once the hold has passed accepts them all.
        var emptiedPastHold: [CalendarRef] = []
        var heldNow: [CalendarRef] = []
        for ref in selected where realCounts[ref] == 0 && (memory.lastRealCount[ref] ?? 0) > 0 {
            if !emptiedPastHold.contains(ref) { emptiedPastHold.append(ref) }
            if let firedAt = memory.guardFiredAt[ref] {
                if at.timeIntervalSince(firedAt) < emptyReadHold {
                    guardTripped = true
                    if !heldNow.contains(ref) { heldNow.append(ref) }
                } else if !emptied.contains(ref) {
                    emptied.append(ref)
                }
            } else {
                memory.guardFiredAt[ref] = at
                guardTripped = true
                if !heldNow.contains(ref) { heldNow.append(ref) }
            }
        }
        if guardTripped {
            let afterHold = pastHold
                ? plannedResult(events: events, settings: settings, window: window, at: at, mode: mode,
                                emptied: emptiedPastHold)
                : nil
            return .held(memory: memory, calendars: heldNow, pastHold: afterHold)
        }
        for ref in selected {
            memory.lastRealCount[ref] = realCounts[ref]
            memory.guardFiredAt[ref] = nil
        }

        let result = plannedResult(events: events, settings: settings, window: window, at: at, mode: mode,
                                   emptied: emptied)
        return .planned(result: result, events: events, window: window, memory: memory)
    }

    /// The plan of a run that goes ahead on `events`, read in `window` at `at`, accepting the empty reads of
    /// `emptied`: without `stale` calendars or a report.
    private func plannedResult(events: [EventSnapshot], settings: SyncSettings, window: DateInterval, at: Date,
                               mode: SyncMode, emptied: [CalendarRef]) -> SyncResult {
        let heldTitles = heldRetitles(events: events, settings: settings, window: window, sent: titlesSent)
        let planned = reconcile(events: events, settings: settings, window: window, noRetitle: heldTitles)
        let mirrored = mirroredCountsPerTarget(events: events, planned: planned, selected: settings.selected,
                                               window: window)
        return SyncResult(
            at: at, mode: mode, planned: planned, mirrored: mirrored, emptiedCalendars: emptied,
            changes: plannedChanges(for: planned, events: events, settings: settings, window: window),
            notBusy: notBusyOriginals(events: events, settings: settings, window: window),
            mirroredItems: mirroredItems(events: events, settings: settings, window: window),
            retitlesNotSticking: heldTitles.count
        )
    }

    /// What applying `settings` would do, worked out as a dry run of them that changes nothing a run reads: no
    /// empty-read guard memory, no `titlesSent`, no change tracking, no writes; only its own `previewHeldSince`.
    /// Waits its turn like runs and removals.
    ///
    /// With two or more calendars in `settings`, it reads and plans exactly as a dry run would: the same window,
    /// the same retitles held, the same empty-read guard, and the reason a dry run would skip as `skippedReason`
    /// instead of a skip. The empty-read hold is the exception: a preview never arms the guard, and it plans past
    /// the hold instead, with the counts of the run once the hold has passed, `heldReason` (`emptyRead`) and the
    /// calendars held now (`heldCalendars`); runs keep holding. A preview keeps its own wait (Ruling 18): a calendar
    /// previews have found held, each in a row, for `emptyReadHold` (`previewHeldSince`) counts as emptied, as a
    /// run's does after its own wait, so it no longer makes the preview held; the counts are the same.
    ///
    /// With fewer, syncing stops: nothing is planned, and the calendars left are cleared on Apply too. `removals`: the
    /// Busy copies in each of `dropping`, and in the calendars left once syncing stops, from today to +400 days (the
    /// window of `removeAllCopies`), counted whatever the plan says, since Apply removes them either way (in Dry run
    /// once Live is switched on, `PendingRemovals`); a calendar Calendar does not list has nothing to count. When they
    /// cannot be read, the reason is `skippedReason`, unless the plan gave one already.
    public func preview(settings: SyncSettings, dropping: [CalendarRef]) async -> ChangePreview {
        await acquire()
        defer { release() }
        let at = now()
        var preview = ChangePreview()
        var cleared = dropping
        if Set(settings.selected).count < 2 {
            preview.syncingStops = true
            cleared += settings.selected
            // No plan, so nothing read for the guard.
            previewHeldSince = [:]
        } else {
            let planned: SyncResult?
            switch await plan(settings: settings, mode: .dryRun, at: at, pastHold: true) {
            case let .skipped(reason):
                preview.skippedReason = reason
                planned = nil
                previewHeldSince = [:]
            case let .held(_, held, pastHold):
                let stillHeld = notePreviewHolds(held, at: at)
                // Always planned past the hold, as asked; without that plan there would be no counts to show.
                if pastHold == nil {
                    preview.skippedReason = Self.emptyRead
                } else if !stillHeld.isEmpty {
                    preview.heldReason = Self.emptyRead
                    preview.heldCalendars = stillHeld
                }
                planned = pastHold
            case let .planned(result, _, _, _):
                _ = notePreviewHolds([], at: at)
                planned = result
            }
            if let planned {
                let counts = planned.plannedCounts
                preview.add = counts.add
                preview.remove = counts.remove
                preview.retitle = planned.plannedRetitles
            }
        }
        let copies = await copyCounts(in: cleared, at: at)
        preview.removals = copies.counts
        if preview.skippedReason == nil { preview.skippedReason = copies.failure }
        return preview
    }

    /// Keeps in `previewHeldSince` only the calendars a preview at `at` finds held, `held`: since their earlier
    /// sighting, or from now on. Every other sighting is dropped, of calendars it read and found not held as of
    /// calendars it did not read. Returns those of `held` found held for less than `emptyReadHold` so far, in their
    /// order.
    private func notePreviewHolds(_ held: [CalendarRef], at: Date) -> [CalendarRef] {
        var sightings: [CalendarRef: Date] = [:]
        var stillHeld: [CalendarRef] = []
        for ref in held where sightings[ref] == nil {
            let since = previewHeldSince[ref] ?? at
            sightings[ref] = since
            if at.timeIntervalSince(since) < emptyReadHold { stillHeld.append(ref) }
        }
        previewHeldSince = sightings
        return stillHeld
    }

    /// Forgets when previews first found calendars held (`previewHeldSince`). The app calls it once nothing is
    /// staged, so the next staged change waits out a hold of its own instead of taking an old sighting. Waits its
    /// turn like a preview, so it never lands in the middle of one.
    public func forgetPreviewHolds() async {
        await acquire()
        defer { release() }
        previewHeldSince = [:]
    }

    /// The Busy copies in each of `calendars` that Calendar lists, from today to +400 days (the window of
    /// `removeAllCopies`), as `preview` counts them for the calendars Apply clears, or why they could not be read; a
    /// calendar Calendar does not list has no entry. Changes nothing, not even the previews' own memory
    /// (`previewHeldSince`), so the app can count the Busy blocks waiting for Live after every dry run without
    /// touching the wait of a staged preview, which a preview of the applied settings would. Waits its turn like runs,
    /// removals and previews.
    public func countCopies(in calendars: [CalendarRef]) async -> (counts: [CalendarRef: Int], failure: String?) {
        await acquire()
        defer { release() }
        return await copyCounts(in: calendars, at: now())
    }

    /// The marked copies in each of `calendars` that Calendar lists, in the window of `removeAllCopies`, or why
    /// they could not be read. Changes nothing.
    private func copyCounts(in calendars: [CalendarRef],
                            at: Date) async -> (counts: [CalendarRef: Int], failure: String?) {
        guard !calendars.isEmpty else { return ([:], nil) }
        guard await store.accessState() == .granted else { return ([:], Self.accessNeeded) }
        let listed: Set<CalendarRef>
        do { listed = Set(try await store.calendars().map(\.ref)) } catch { return ([:], Self.reason(for: error)) }
        var present: [CalendarRef] = []
        for ref in calendars where listed.contains(ref) && !present.contains(ref) { present.append(ref) }
        guard !present.isEmpty else { return ([:], nil) }
        let events: [EventSnapshot]
        do { events = try await store.events(in: present, window: Self.removalWindow(from: at)) } catch {
            return ([:], Self.reason(for: error))
        }
        var counts = Dictionary(uniqueKeysWithValues: present.map { ($0, 0) })
        for e in events where e.marker != nil && counts[e.calendar] != nil {
            counts[e.calendar, default: 0] += 1
        }
        return (counts, nil)
    }

    /// Deletes every marked copy in the given calendars (window: today to +400 days). Never touches
    /// events without a marker.
    public func removeAllCopies(in calendars: [CalendarRef]) async -> ApplyReport {
        await acquire()
        defer { release() }
        return await removeAllCopiesLocked(in: calendars)
    }

    private func removeAllCopiesLocked(in calendars: [CalendarRef]) async -> ApplyReport {
        guard await store.accessState() == .granted else {
            return ApplyReport(failures: [Self.accessNeeded])
        }
        guard !calendars.isEmpty else { return ApplyReport() }
        let events: [EventSnapshot]
        do { events = try await store.events(in: calendars, window: Self.removalWindow(from: now())) } catch {
            return ApplyReport(failures: [Self.reason(for: error)])
        }
        let wanted = Set(calendars)
        let actions: [SyncAction] = events.compactMap { e in
            guard e.marker != nil, wanted.contains(e.calendar) else { return nil }
            return .delete(localID: e.localID, target: e.calendar)
        }
        guard !actions.isEmpty else { return ApplyReport() }
        do { return try await store.apply(actions) } catch {
            return ApplyReport(failures: [Self.saveFailed])
        }
    }
}
