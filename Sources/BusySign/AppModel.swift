import AppKit
import BusySignCore
import EventKit
import Foundation
import os

private let logger = Logger(subsystem: "io.github.v0rest.busysign", category: "app")

private func currentAccess() -> AccessState {
    mapAccess(EKEventStore.authorizationStatus(for: .event))
}

/// App state and the sync loop. Every engine call (runs and removals) goes through one serial chain, so
/// at most one run is in flight, at most one more waits, and replacing the store after an access grant
/// never overlaps engine work. Lives for the whole app run.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var access: AccessState
    @Published private(set) var lastResult: SyncResult?
    /// The calendar ids `lastResult` ran with: the catalog is built for them.
    @Published private(set) var lastRunSelectedIDs: [String] = []
    /// Goes up by one whenever something a run depends on changes: Apply of staged settings (`applied`, and the
    /// calendars it leaves waiting for Live, `pendingRemovals`), the mode, a removal of Busy copies (Apply's in Live,
    /// the switch to Live's and its retries, or "Remove all Busy copies") once it goes ahead, calendar access, the calendars Calendar
    /// lists (which ones, and whether they are writable), and the default names that label `Source: Title` copies.
    /// Never goes down. Staged changes do not count: runs use the applied settings.
    @Published private(set) var inputsGeneration = 0
    /// Like `inputsGeneration`, but not for an Apply that changes only exclusions, hidden titles, what copies show
    /// or short names, nor for mode changes: the catalog already follows the exclusions and mode, and neither what
    /// copies show nor a calendar's name changes which meetings it lists, so its ticks, labels and counts hold;
    /// everything else waits for a run. A pair set to Nothing or back counts: it changes which meetings are copied.
    @Published private(set) var structureGeneration = 0
    /// The `inputsGeneration` and `structureGeneration` the run behind `lastResult` started with; nil before
    /// any run and after "Remove all Busy copies" cleared the result.
    @Published private(set) var lastRunGeneration: Int?
    @Published private(set) var lastRunStructureGeneration: Int?
    @Published private(set) var calendars: [CalendarInfo] = [] {
        didSet { refreshDisplayNames() }
    }
    /// Why the last calendar listing failed, for the settings window; `nil` after a good listing.
    @Published private(set) var calendarsError: String?
    /// The settings that decide what BusySign writes, as stored on this Mac: the ticked calendars in the order they
    /// were ticked, look-ahead days, "Treat unanswered invitations as busy", the excluded meetings and series
    /// (`ExclusionKey`s), the hidden titles (`ExclusionKey`s from the Title boxes, whose copies show `Busy` whatever
    /// their route's format), what the copies on each pair of calendars show, or that it copies nothing (`CopyRoute`:
    /// from the "Blocks from … show" lines; a missing route shows `busyOnly`, which is never stored) and the user's
    /// short names. Runs, removals and every name shown, except on the row being renamed, use these. Only routes
    /// between ticked calendars are kept: Apply drops those of calendars it unticks, and a launch drops those of
    /// calendars not ticked, so a calendar ticked again starts at `Busy only`. Calendar ids, opaque keys, formats and
    /// the user's names only, never titles. Changed by Apply only (`applyStagedChanges`).
    @Published private(set) var applied: SyncInputs {
        didSet { refreshDisplayNames() }
    }
    /// The changes waiting for Apply, in memory only (closing a window keeps them, quitting drops them): made from
    /// `applied` by the first edit of a setting that decides writes, dropped by Apply, Revert and an edit that
    /// leaves no change to `applied` (`changeCount(from:)` 0). Nothing is written to a calendar or the settings
    /// for them before Apply.
    @Published private(set) var staged: SyncInputs?
    /// What applying `staged` would do, worked out like a dry run of them (`SyncEngine.preview`) and described as
    /// Apply would act: `removals` only for the calendars Apply clears, and `syncingStops` only when Apply takes the
    /// listed selection from two calendars or more to fewer (`clearing(applying:)`). Recomputed 0.4 s after the
    /// latest staged edit and, while something is staged, after every Calendar change, a change of the calendars
    /// Calendar lists or of calendar access, each of our own runs and removals, and on a new calendar day; and
    /// again after one Apply cannot act on (`previewIsUsable`), until it can (`schedulePreviewRetry`). Nil while
    /// nothing is staged.
    @Published private(set) var preview: ChangePreview?
    /// From a request for a new preview (`schedulePreview`: a staged edit, a Calendar change, …) until it lands:
    /// `preview`, if any, is older. Not while the retry of a preview Apply cannot act on waits
    /// (`schedulePreviewRetry`): the bar keeps its reason meanwhile.
    @Published private(set) var previewInFlight = false
    @Published private(set) var paused: Bool
    @Published private(set) var mode: SyncMode
    @Published private(set) var intervalMinutes: Int
    @Published private(set) var startAtLogin: Bool
    @Published private(set) var loginItemMessage: String?
    @Published private(set) var removalsInFlight = 0
    @Published private(set) var removalSummary: String?
    /// The calendars whose Busy blocks wait for Live, in the order they joined (`PendingRemovals`, Ruling 19). Dry run
    /// writes nothing, so Apply there removes no Busy blocks: the calendars it would have cleared wait here instead
    /// (`applyStagedChanges`). The switch to Live removes their blocks before the first live run
    /// (`removePendingBeforeLive`), "Remove all Busy copies" removes them in any mode, and an Apply that ticks one
    /// again in a selection that syncs drops it; a removal that fails keeps it, and in Live it is tried again after
    /// every live run that goes ahead (`retryPendingRemovals`). Stored
    /// (`SettingsStore.pendingRemovals`), so a quit keeps them. Calendar ids only.
    @Published private(set) var pendingRemovals: [CalendarRef]
    /// The Busy blocks in each of `pendingRemovals`, from today to +400 days: worked out after every dry run
    /// (`countPendingRemovals`), and for a calendar that joins, taken from the preview of the Apply that made it wait.
    /// A calendar without an entry, and every one while nil, is not known yet; Live waits until each has one
    /// (`liveSwitchState`). Counts only.
    @Published private(set) var pendingRemovalCounts: [CalendarRef: Int]?
    /// Titles of the originals of the last result, by local id, for the Meetings window. Display only:
    /// kept in memory, never logged or saved, never passed to the core, notifications or copies. Refilled
    /// after every run; a selection change keeps them, since the window still shows the last run's meetings.
    @Published private(set) var titles: [String: String] = [:]
    /// Own titles of the days of the series in the Meetings window (`EventKitStore.occurrenceTitles(for:)`), read
    /// only while that window is open: when it opens and after every run meanwhile. Display only, like `titles`:
    /// kept in memory, never logged or saved, never passed to the core, notifications or copies; emptied when the
    /// window closes or the result is cleared.
    @Published private(set) var dayTitles: [OccurrenceRef: String] = [:]
    /// The changes behind the past-tense labels and "Last changes", from the live runs since the switch to
    /// Live (`LiveChanges.updated(after:selected:)`): the most recent run that changed something, or, from a
    /// run with failures on, every run's until the first run without failures has followed. Changes that could
    /// not be saved may carry a wrong label (the Meetings window says so). Switching to Dry run and removing all
    /// Busy copies clear them. In memory only.
    @Published private(set) var liveChanges = LiveChanges()
    /// The meetings of the last result for the calendars that run used (`lastRunSelectedIDs`) under the
    /// exclusions, hidden titles and formats of `effective` (staged ones included); the Live labels and each
    /// section's `appliedCount` follow the applied exclusions, since nothing happens before Apply. Rebuilt after
    /// every run and right after a staged edit, Apply, Revert or a mode change, so ticks and Title boxes react
    /// before the next run; a selection change waits for the run that covers it.
    @Published private(set) var catalog: MeetingsCatalog
    /// Clock for relative texts such as "Synced 2 min ago".
    @Published private(set) var now = Date()
    /// Selected calendars whose real events have not changed for `staleThresholdHours`, as of the last run that
    /// went ahead; Settings notes them (`quietNote`). A skipped run keeps the last known state.
    @Published private(set) var quietCalendars: Set<CalendarRef> = []

    /// Shown names by calendar id (`displayNames`), unique among the calendars Settings lists and the selected
    /// ones Calendar no longer lists. Follows the calendars, the selection and the user's names.
    private var displayNameByID: [String: String]
    /// Calendar ids in the order Calendar first listed them on this Mac, so the " #n" of names that clash do
    /// not change when a calendar appears. Ids only; stored.
    private var firstSeenIDs: [String]
    private let settings: SettingsStore
    private let notifier = Notifier()
    private var store: EventKitStore
    private var engine: SyncEngine
    /// Set whenever access is missing: an `EKEventStore` made before a grant may not see calendars.
    private var storeNeedsReset: Bool
    private var tracker: ChangeTracker
    /// Last operation of the serial chain.
    private var tail: Task<Void, Never>?
    private var syncQueued = false
    private var timerTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    /// Whether the Meetings window is open (`meetingsWindowDidOpen`), so `dayTitles` are needed.
    private var meetingsWindowOpen = false
    /// Bumped by every read of `dayTitles` and every clearing of them, so a read that lands after a newer one, a
    /// close or a clearing is dropped.
    private var dayTitlesGeneration = 0
    /// Bumped by every Calendar change (`storeChanged`); not published, since a change while something is staged
    /// also sets `previewInFlight`.
    private var calendarChanges = 0
    /// The `calendarChanges` when the read behind `preview` started, and the staged inputs it was worked out for.
    private var previewCalendarChanges = 0
    private var previewInputs: SyncInputs?
    /// What Apply clears for `previewInputs`, as `preview` shows it (`clearing(applying:)` when it was worked
    /// out): Apply clears these and no others.
    private var previewClearing: Clearing?
    /// The start of the calendar day on which the read behind `preview` started: its window starts that day.
    private var previewDay: Date?
    /// When the first of the latest previews in a row that Apply cannot act on landed (`previewIsUsable`), for the
    /// retry's back-off (`ChangePreview.retryDelay`); nil once a usable one lands, after a staged edit, a Calendar
    /// change and when nothing is staged.
    private var unusablePreviewsSince: Date?
    /// Bumped by every preview request and every drop of the staged inputs, so a preview overtaken meanwhile is
    /// dropped: the newest request wins.
    private var previewGeneration = 0
    /// Waits out the 0.4 s after the latest request, then queues the preview.
    private var previewTask: Task<Void, Never>?
    /// From the switch to Live that queued the removal of `pendingRemovals` (`removePendingBeforeLive`) until that
    /// removal starts: a run queued before it does not go ahead (`performSync`), so none runs Live before it; the
    /// removal asks for a run once done.
    private var pendingRemovalBeforeLive = false

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        let access = currentAccess()
        self.access = access
        let selected = settings.selectedCalendarIDs ?? []
        paused = settings.paused
        mode = settings.mode
        intervalMinutes = settings.intervalMinutes
        startAtLogin = settings.startAtLogin
        let inputs = SyncInputs(
            selected: selected.map { CalendarRef(id: $0) },
            lookAheadDays: settings.lookAheadDays,
            unansweredAsBusy: settings.unansweredAsBusy,
            excluded: Set(settings.excludedKeys),
            hiddenTitleKeys: Set(settings.hiddenTitleKeys),
            copyTitleFormats: Self.loadCopyTitleRoutes(settings, selectedIDs: selected),
            calendarNames: settings.calendarNames
        )
        applied = inputs
        var seenPending = Set<String>()
        pendingRemovals = settings.pendingRemovals.filter { seenPending.insert($0).inserted }.map { CalendarRef(id: $0) }
        firstSeenIDs = settings.calendarFirstSeen
        displayNameByID = Self.makeDisplayNames(calendars: [], selectedIDs: selected, names: inputs.calendarNames,
                                                firstSeen: settings.calendarFirstSeen)
        catalog = Self.buildCatalog(nil, mode: settings.mode, selectedIDs: [], inputs: inputs,
                                    appliedExcluded: inputs.excluded, lastLiveChanges: [])
        tracker = settings.changeTracker
        let store = EventKitStore()
        self.store = store
        engine = Self.makeEngine(store)
        storeNeedsReset = access != .granted
    }

    private static func makeEngine(_ store: EventKitStore) -> SyncEngine {
        SyncEngine(store: store, now: { Date() })
    }

    /// The stored routes (`SettingsStore.copyTitleRoutes`) between calendars of `selectedIDs`, the stored selection.
    /// Once, while the choices of before, one per calendar, are still stored (`SettingsStore.copyTitleFormats`), they
    /// move to pairs first: each becomes the same choice on every route into that calendar from the other calendars
    /// in `selectedIDs` (`copyTitleRoutes(fromTargetFormats:selected:)`), so the first run after the upgrade plans
    /// nothing. Routes stored already win over moved ones. The routes are saved before the old choices are removed.
    /// Logs how many routes the old choices gave and the stored ones did not override, never a title.
    ///
    /// A stored route whose source or target is not in `selectedIDs` is dropped and the rest saved
    /// (`keepingRoutes(between:from:)`): an untick cut short between its two writes, or one made in a build that
    /// kept the choice per calendar, can leave such a route, and it would title copies again when that calendar is
    /// ticked. Logs how many were dropped.
    private static func loadCopyTitleRoutes(_ settings: SettingsStore,
                                            selectedIDs: [String]) -> [CopyRoute: CopyTitleFormat] {
        let selected = selectedIDs.map { CalendarRef(id: $0) }
        let stored = settings.copyTitleRoutes
        let pruned = keepingRoutes(between: selected, from: stored)
        if pruned.count != stored.count {
            logger.info("""
                copy title choices dropped for calendars not selected: \(stored.count - pruned.count, privacy: .public)
                """)
        }
        guard settings.hasPerCalendarCopyTitleFormats else {
            if pruned != stored { settings.copyTitleRoutes = pruned }
            return pruned
        }
        let moved = copyTitleRoutes(fromTargetFormats: perCalendarCopyTitleFormats(settings.copyTitleFormats),
                                    selected: selected)
        let routes = moved.merging(pruned) { _, kept in kept }
        settings.copyTitleRoutes = routes
        settings.removePerCalendarCopyTitleFormats()
        let count = moved.keys.filter { stored[$0] == nil }.count
        logger.info("copy title choices moved to pairs: \(count, privacy: .public)")
        return routes
    }

    /// The choices of before by calendar, title choices only (`showsTitle`): a calendar that is missing showed
    /// `busyOnly`, and those choices never held `nothing`.
    private static func perCalendarCopyTitleFormats(_ stored: [String: String]) -> [CalendarRef: CopyTitleFormat] {
        var formats: [CalendarRef: CopyTitleFormat] = [:]
        for (id, raw) in stored {
            guard let format = CopyTitleFormat(rawValue: raw), format.showsTitle else { continue }
            formats[CalendarRef(id: id)] = format
        }
        return formats
    }

    /// Called once the app has finished launching. Asks for calendar access only when it was never
    /// asked; this shows the system prompt.
    func start() {
        guard !started else { return }
        started = true
        observeSystem()
        notifier.install()
        scheduleTimer()
        clockTask = repeating(every: .seconds(60)) { $0.clockTicked() }
        loginItemMessage = LoginItem.reconcileAtLaunch(enabled: startAtLogin, settings: settings)
        logger.info("started \(Version.current, privacy: .public), mode \(self.mode.rawValue, privacy: .public), paused \(self.paused, privacy: .public)")
        Task {
            if refreshAccess() == .notDetermined {
                _ = await store.requestAccess()
                refreshAccess()
            }
            // Lists calendars for the menu even when syncing is paused.
            reloadCalendars()
            requestSync()
        }
    }

    // MARK: - Access

    /// Re-reads calendar access. A fresh grant schedules a sync, which first replaces the store; any change asks
    /// for a new preview while something is staged.
    @discardableResult
    func refreshAccess(syncOnGrant: Bool = true) -> AccessState {
        let state = currentAccess()
        if state != access {
            logger.info("calendar access is now \(String(describing: state), privacy: .public)")
            let becameGranted = state == .granted
            access = state
            // A run skipped for missing access may go ahead now, and the reverse.
            inputsChanged()
            if staged != nil { schedulePreview() }
            if becameGranted && syncOnGrant { requestSync() }
        }
        if state != .granted { storeNeedsReset = true }
        notifier.accessChanged(state)
        return state
    }

    /// Replaces the store and the engine after a grant. Called only inside the serial chain.
    private func resetStoreIfNeeded() {
        guard storeNeedsReset, access == .granted else { return }
        storeNeedsReset = false
        store = EventKitStore()
        engine = Self.makeEngine(store)
        logger.info("calendar store recreated after access was granted")
    }

    // MARK: - Serial chain

    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task {
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }

    /// The one way to ask for a run. Does nothing while paused; while a run is waiting, further
    /// requests join it. Settings and the engine are read when the run starts, not here.
    func requestSync() {
        guard !paused, !syncQueued else { return }
        syncQueued = true
        enqueue { [weak self] in
            guard let self else { return }
            self.syncQueued = false
            await self.performSync()
        }
    }

    private func performSync() async {
        guard !paused else { return }
        // The switch to Live queued the removal of the Busy blocks waiting for it behind this run: it goes first and
        // asks for a run once done.
        guard !pendingRemovalBeforeLive else { return }
        refreshAccess(syncOnGrant: false)
        resetStoreIfNeeded()
        if access == .granted { await loadCalendars() }
        // Pausing while the calendars were listed stops this run too, and so does a switch to Live that queued the
        // removal of the Busy blocks waiting for it: the mode is read below.
        guard !paused, !pendingRemovalBeforeLive else { return }
        // The applied settings only: staged ones wait for Apply.
        let inputs = applied
        let runSelection = inputs.selected.map(\.id)
        let runGeneration = inputsGeneration
        let runStructureGeneration = structureGeneration
        // Only the routes between calendars of this run (`SyncInputs.settings`); labels after the calendars were
        // listed, so default names follow Calendar's.
        let runSettings = inputs.settings(sourceLabels: sourceLabels(of: inputs))
        let (result, newTracker) = await engine.runOnce(
            settings: runSettings,
            mode: mode,
            tracker: tracker,
            staleThreshold: settings.staleThresholdHours * 3600
        )
        tracker = newTracker
        settings.changeTracker = newTracker
        // The run may have written, or changed what the engine holds back (the empty-read guard, the titles sent),
        // so the preview's counts may no longer hold.
        if staged != nil { schedulePreview() }
        // Skipped ones too (fewer than two calendars left, say); before the result, so Live is never offered on a dry
        // run whose pending counts are still on the way.
        if result.mode == .dryRun { await countPendingRemovals() }
        // A live run that lands after a switch to Dry run leaves no labels.
        if mode == .live { liveChanges = liveChanges.updated(after: result, selected: runSettings.selected) }
        lastResult = result
        lastRunSelectedIDs = runSelection
        lastRunGeneration = runGeneration
        lastRunStructureGeneration = runStructureGeneration
        if result.skippedReason == nil { quietCalendars = Set(result.stale) }
        rebuildCatalog()
        now = Date()
        log(result)
        // A removal that failed, or has not run since a relaunch, goes again (`retryPendingRemovals`).
        if result.mode == .live, result.skippedReason == nil, !pendingRemovals.isEmpty { retryPendingRemovals() }
        let ids = Self.titledLocalIDs(of: result)
        titles = ids.isEmpty ? [:] : await store.titles(for: ids)
        await refreshDayTitles()
    }

    /// Local ids of the originals whose titles the Meetings window shows: adds, moves, mirrored meetings
    /// and originals not counted as busy.
    private static func titledLocalIDs(of result: SyncResult) -> [String] {
        let changes = result.changes.filter { $0.kind == .add || $0.kind == .move }.compactMap(\.sourceLocalID)
        return Array(Set(changes + result.mirroredItems.map(\.sourceLocalID) + result.notBusy.map(\.localID)))
    }

    private func log(_ r: SyncResult) {
        if let reason = r.skippedReason {
            logger.info("\(r.mode.rawValue, privacy: .public) run skipped: \(reason, privacy: .public)")
            return
        }
        let report = r.report
        logger.info("""
            \(r.mode.rawValue, privacy: .public) run: \(r.planned.count, privacy: .public) planned, \
            created \(report?.created ?? 0, privacy: .public), updated \(report?.updated ?? 0, privacy: .public), \
            replaced \(report?.replaced ?? 0, privacy: .public), \
            deleted \(report?.deleted ?? 0, privacy: .public), failed \(report?.failures.count ?? 0, privacy: .public), \
            retitled \(r.plannedRetitles, privacy: .public), \
            titles not sticking \(r.retitlesNotSticking, privacy: .public), \
            stale \(r.stale.count, privacy: .public), not counted as busy \(r.notBusy.count, privacy: .public)
            """)
    }

    // MARK: - Meetings catalog

    /// The Meetings window opened or came to the front: read the days' own titles for it.
    func meetingsWindowDidOpen() {
        meetingsWindowOpen = true
        Task { await refreshDayTitles() }
    }

    /// The Meetings window closed: no day titles are read until it opens again, and the ones read are dropped.
    func meetingsWindowDidClose() {
        meetingsWindowOpen = false
        clearDayTitles()
    }

    private func clearDayTitles() {
        dayTitlesGeneration += 1
        dayTitles = [:]
    }

    /// Reads the own title of every day of a series row in the catalog (`dayTitles`), while the Meetings window is
    /// open; single meetings show their own title already (`titles`). A read overtaken meanwhile is dropped.
    private func refreshDayTitles() async {
        guard meetingsWindowOpen else { return }
        dayTitlesGeneration += 1
        let generation = dayTitlesGeneration
        let days = catalog.sections.flatMap { section in
            section.rows.filter(\.isSeries).flatMap { row in
                row.occurrences.map { OccurrenceRef(calendar: section.source, localID: $0.localID, start: $0.start) }
            }
        }
        let read = days.isEmpty ? [:] : await store.occurrenceTitles(for: days)
        guard generation == dayTitlesGeneration else { return }
        dayTitles = read
    }

    /// Only the routes between the calendars `inputs` tick, so an untick drops its pairs' Title boxes at once.
    /// Labels and `appliedCount` by `appliedExcluded`.
    private static func buildCatalog(_ result: SyncResult?, mode: SyncMode, selectedIDs: [String],
                                     inputs: SyncInputs, appliedExcluded: Set<String>,
                                     lastLiveChanges: [PlannedChange]) -> MeetingsCatalog {
        meetingsCatalog(result: result ?? SyncResult(at: .distantPast, mode: mode),
                        selected: selectedIDs.map { CalendarRef(id: $0) }, excluded: inputs.excluded,
                        lastLiveChanges: lastLiveChanges, hiddenTitles: inputs.hiddenTitleKeys,
                        titleFormats: keepingRoutes(between: inputs.selected, from: inputs.copyTitleFormats),
                        appliedExcluded: appliedExcluded)
    }

    private func rebuildCatalog() {
        catalog = Self.buildCatalog(lastResult, mode: mode, selectedIDs: lastRunSelectedIDs, inputs: effective,
                                    appliedExcluded: applied.excluded, lastLiveChanges: liveChanges.changes)
    }

    /// Whether something the last run depended on changed since it started (`inputsGeneration`), also when
    /// it changed back, or no run has landed since the result was cleared. The last dry run's counts are that
    /// run's until the next run lands, so Live waits for it.
    var inputsChangedSinceRun: Bool {
        lastRunGeneration != inputsGeneration
    }

    /// The same without exclusion, hidden-title, mode, copy title and short-name changes (`structureGeneration`):
    /// the Meetings window's sections and the menu counts are the last run's until the next one lands; ticks and
    /// Title boxes are not, since the catalog follows them. A pair set to Nothing or back is not a copy title change
    /// here: it changes which meetings are copied.
    var structureChangedSinceRun: Bool {
        lastRunStructureGeneration != structureGeneration
    }

    /// `structure` is false for mode changes, label changes and an Apply of exclusion, hidden-title, copy title and
    /// short-name changes only; a copy title change that sets a pair to Nothing or back is structure.
    private func inputsChanged(structure: Bool = true) {
        inputsGeneration += 1
        if structure { structureGeneration += 1 }
    }

    // MARK: - Calendars and selection

    /// Re-lists calendars, e.g. when the settings window opens.
    func reloadCalendars() {
        enqueue { [weak self] in
            guard let self else { return }
            self.refreshAccess()
            self.resetStoreIfNeeded()
            if self.access == .granted { await self.loadCalendars() }
        }
    }

    private func loadCalendars() async {
        let list: [CalendarInfo]
        do {
            list = try await store.calendars()
        } catch {
            logger.error("calendar list not read: \(String(describing: error), privacy: .public)")
            calendarsError = (error as? CalendarStoreError)?.errorDescription ?? SyncEngine.readFailed
            return
        }
        calendarsError = nil
        // Calendars appearing, going or turning read-only change what the next run does or whether it skips.
        func listing(_ infos: [CalendarInfo]) -> Set<String> { Set(infos.map { "\($0.ref.id)|\($0.isWritable)" }) }
        if listing(list) != listing(calendars) { inputsChanged() }
        let known = Set(firstSeenIDs)
        let new = Set(list.map(\.ref.id)).subtracting(known).sorted()
        // Before `calendars` changes, so its names already number a new calendar after the others.
        if !new.isEmpty {
            firstSeenIDs += new
            settings.calendarFirstSeen = firstSeenIDs
        }
        // Nothing is ticked for the user, also on first launch: the main rows in Settings are the suggestion.
        if list != calendars {
            // Default short names follow Calendar's names, and they label `Source: Title` copies.
            let labels = sourceLabels(of: applied)
            calendars = list
            if sourceLabels(of: applied) != labels { inputsChanged(structure: false) }
            // A ticked calendar that was missing may be back, so the selection syncs again without an Apply: the
            // calendars waiting for Live that it ticks stop waiting (`PendingRemovals.stillWaiting`), and are never
            // cleared. The listing changed, so `inputsChanged` above already asks for a new dry run before Live.
            keepWaitingOnlyUnsynced()
            // A staged rename whose row went with the listing goes back to the applied name.
            restage()
            // What Apply clears (`clearing(applying:)`), the preview's counts and the names on the bar follow the
            // listing. The store lists calendars in a fixed order, so only a real change asks again.
            if staged != nil { schedulePreview() }
        }
    }

    /// What "Calendars to sync" in Settings lists (`calendarList`): `main` gets a row with a checkbox and a rename
    /// field each (`CalendarRow`), every account's main calendar and every calendar ticked, by the staged selection
    /// and, so a calendar unticked before Apply keeps its row, the applied one.
    var settingsCalendarList: CalendarList {
        Self.settingsCalendarList(calendars, effective: effective, applied: applied)
    }

    private static func settingsCalendarList(_ calendars: [CalendarInfo], effective: SyncInputs,
                                             applied: SyncInputs) -> CalendarList {
        let ticked = effective.selected.map(\.id)
        let unticked = applied.selected.map(\.id).filter { !ticked.contains($0) }
        return calendarList(calendars, selectedIDs: ticked + unticked)
    }

    /// Whether `calendar`'s checkbox is ticked: in the staged selection while something is staged, else in the
    /// applied one.
    func isSelected(_ calendar: CalendarInfo) -> Bool {
        effective.selected.contains(calendar.ref)
    }

    /// Ticks or unticks a calendar in the staged selection (`stage`); nothing is written or removed before Apply.
    /// Unticking asks nothing: the preview counts the Busy blocks Apply would remove, and Apply removes them in Live,
    /// while in Dry run they wait for Live (`applyStagedChanges`, `pendingRemovals`). A calendar ticked anew starts at
    /// `Busy only` everywhere, since only routes between applied calendars are stored; one unticked and ticked again
    /// before Apply keeps its applied routes.
    func select(_ calendar: CalendarInfo, on: Bool) {
        stage { inputs in
            guard inputs.selected.contains(calendar.ref) != on else { return }
            if on {
                inputs.selected.append(calendar.ref)
            } else {
                inputs.selected.removeAll { $0 == calendar.ref }
            }
        }
    }

    /// Drops a selected calendar that no longer exists in Calendar from the staged selection; Apply forgets it
    /// and every pair it is part of, with nothing to remove there.
    func forgetMissingCalendar(id: String) {
        stage { inputs in inputs.selected.removeAll { $0.id == id } }
    }

    // MARK: - Short names

    /// The name the app shows for a calendar, everywhere it names one: its own name (`ownName`), told apart
    /// from the other listed calendars' names by `displayNames` when they clash.
    func shortName(_ ref: CalendarRef) -> String {
        displayNameByID[ref.id] ?? ownName(ref)
    }

    /// A calendar's name before clashes are resolved: the user's name for it; else, for an account's main
    /// calendar, the default short name of its account (`defaultShortName`); else, and for every other
    /// calendar, its own title, so calendars of one account read differently. A calendar Calendar does not
    /// list and the user never named is "A selected calendar". What the rename field starts with, unless a rename
    /// is staged (`stagedOwnName`). By the applied names.
    func ownName(_ ref: CalendarRef) -> String {
        Self.ownName(ref, calendars: calendars, names: applied.calendarNames)
    }

    /// The name a staged rename gives `ref` (`ownName` by the staged names), which its row in Settings shows and
    /// its rename field starts with until Apply; nil when no rename of it is staged. Everything else shows the
    /// applied names (`shortName`) until Apply.
    func stagedOwnName(_ ref: CalendarRef) -> String? {
        guard let staged, staged.calendarNames[ref.id] != applied.calendarNames[ref.id] else { return nil }
        return Self.ownName(ref, calendars: calendars, names: staged.calendarNames)
    }

    private static func ownName(_ ref: CalendarRef, calendars: [CalendarInfo], names: [String: String]) -> String {
        if let stored = names[ref.id], !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        guard let calendar = calendars.first(where: { $0.ref == ref }) else { return "A selected calendar" }
        if calendar.isSuggestedPrimary {
            let name = defaultShortName(accountTitle: calendar.accountTitle, calendarTitle: calendar.title)
            if !name.isEmpty { return name }
        }
        return calendar.title.isEmpty ? "Unnamed calendar" : calendar.title
    }

    /// The account part of a name that clashes: the name of the account's main calendar (`ownName`, so the
    /// user's rename counts), else a default short name from the account title alone. For the main calendar
    /// itself that repeats its name, so it is never appended there; `displayNames` lets the main calendar keep
    /// its name and tells the other calendar apart ("Initech" and "Initech · iCloud").
    private static func accountName(of calendar: CalendarInfo, in calendars: [CalendarInfo],
                                    names: [String: String]) -> String {
        let main = calendar.accountID.isEmpty ? nil
            : calendars.first { $0.isSuggestedPrimary && $0.accountID == calendar.accountID }
        guard let main else { return defaultShortName(accountTitle: calendar.accountTitle, calendarTitle: "") }
        return ownName(main.ref, calendars: calendars, names: names)
    }

    /// Who keeps a clashing name: a listed calendar over a missing one, then the account's main calendar,
    /// then one the user named; numbers follow `firstSeen`.
    private static func makeDisplayNames(calendars: [CalendarInfo], selectedIDs: [String],
                                         names: [String: String], firstSeen: [String]) -> [String: String] {
        let list = calendarList(calendars, selectedIDs: selectedIDs)
        let place = Dictionary(firstSeen.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        func isRenamed(_ id: String) -> Bool {
            !(names[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let listed = (list.main + list.other).map { calendar in
            DisplayNameItem(id: calendar.ref.id, name: ownName(calendar.ref, calendars: calendars, names: names),
                            accountName: accountName(of: calendar, in: calendars, names: names), title: calendar.title,
                            isMain: calendar.isSuggestedPrimary, isRenamed: isRenamed(calendar.ref.id),
                            firstSeen: place[calendar.ref.id],
                            defaultName: ownName(calendar.ref, calendars: calendars, names: [:]))
        }
        let missing = list.missingSelectedIDs.map { id in
            DisplayNameItem(id: id, name: ownName(CalendarRef(id: id), calendars: calendars, names: names),
                            isListed: false, isRenamed: isRenamed(id), firstSeen: place[id],
                            defaultName: ownName(CalendarRef(id: id), calendars: calendars, names: [:]))
        }
        return displayNames(listed + missing)
    }

    private func refreshDisplayNames() {
        displayNameByID = Self.makeDisplayNames(calendars: calendars, selectedIDs: applied.selected.map(\.id),
                                                names: applied.calendarNames, firstSeen: firstSeenIDs)
    }

    /// The shown name of another listed calendar that already goes by `name`, for the hint under the rename
    /// field; nil when none does or `name` is blank. Renaming to it is allowed, the names are then told apart.
    func calendarNamed(_ name: String, otherThan ref: CalendarRef) -> String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let other = displayNameByID.keys.sorted().first { id in
            let other = CalendarRef(id: id)
            return other != ref && (namesMatch(name, ownName(other)) || namesMatch(name, shortName(other)))
        }
        return other.map { shortName(CalendarRef(id: $0)) }
    }

    /// Stages the user's short name for a calendar, worked out against the applied names (`renameEffect`): a blank
    /// name goes back to the default, and one that reads like the applied name it has or shows keeps the applied
    /// entry, so typing the old name back drops the staged rename. A short name is also the source label of
    /// `Source: Title` copies, so the preview counts the copies whose label changes, and after Apply, in Live, the
    /// next run replaces them.
    func rename(_ ref: CalendarRef, to name: String) {
        let stored = applied.calendarNames[ref.id]
        let newName: String? = switch renameEffect(typed: name, ownName: ownName(ref), shownName: shortName(ref),
                                                   storedName: stored) {
        case .keep: stored
        case .clear: nil
        case let .store(typed): typed
        }
        stage { inputs in inputs.calendarNames[ref.id] = newName }
    }

    /// Stages `entry` as `ref`'s stored short name exactly, without the rule `rename` applies (nil: none, so the name
    /// follows the default): Escape in the rename field puts back what was staged for it when the field opened
    /// (`NameDrafts.cancel`), the staged entry or, with no rename staged, the applied one, which drops the staged
    /// rename.
    func restoreName(_ ref: CalendarRef, to entry: String?) {
        stage { inputs in inputs.calendarNames[ref.id] = entry }
    }

    /// The source label of each calendar `inputs` tick in `Source: Title` copies: its own name by `inputs`' names
    /// (`ownName`), never the name told apart from clashing ones, which changes by itself.
    private func sourceLabels(of inputs: SyncInputs) -> [CalendarRef: String] {
        Dictionary(inputs.selected.map { ($0, Self.ownName($0, calendars: calendars, names: inputs.calendarNames)) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// "Acme", "Acme and Initech", "Acme, Initech and Gmail".
    func joinedNames(_ refs: [CalendarRef]) -> String {
        let names = refs.map(shortName)
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// The calendars Live writes Busy blocks to, for its confirmation, by short name in selection order: the applied
    /// selected calendars that Calendar lists and that another of them copies into under the applied pairs
    /// (`calendarsGettingBlocks`), so not one every pair into which is set to Nothing; all of them when no pair
    /// copies; "the selected calendars" when none is listed.
    var liveTargetNames: String {
        let listed = Set(calendars.map(\.ref))
        let refs = calendarsGettingBlocks(applied.selected.filter(listed.contains), formats: applied.copyTitleFormats)
        return refs.isEmpty ? "the selected calendars" : joinedNames(refs)
    }

    /// "No new events for a week", beside a calendar in `quietCalendars`.
    var quietNote: String {
        StatusText.quietNote(thresholdHours: settings.staleThresholdHours)
    }

    /// The tooltip of `quietNote`.
    var quietNoteHelp: String {
        StatusText.quietNoteHelp(thresholdHours: settings.staleThresholdHours)
    }

    // MARK: - Commands

    func syncNow() {
        requestSync()
    }

    func togglePause() {
        setPaused(!paused)
    }

    private func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        settings.paused = value
        logger.info("syncing \(value ? "paused" : "resumed", privacy: .public)")
        if !value { requestSync() }
    }

    /// Callers confirm a switch to live with the user first; its confirmation names the Busy blocks waiting for Live
    /// (`pendingRemovals`), which go before the first live run (`removePendingBeforeLive`). Back to Dry run, nothing
    /// is removed.
    func setMode(_ newMode: SyncMode) {
        guard newMode != mode else { return }
        mode = newMode
        settings.mode = newMode
        // The last dry run's counts no longer say what the next run does: a live run may land in between.
        inputsChanged(structure: false)
        if newMode == .dryRun { liveChanges = LiveChanges() }
        rebuildCatalog()
        logger.info("mode set to \(newMode.rawValue, privacy: .public)")
        if newMode == .live, !pendingRemovals.isEmpty { removePendingBeforeLive() }
        requestSync()
    }

    /// The switch to Live removes the Busy blocks waiting for it (`pendingRemovals`) through the removal Apply uses
    /// in Live, before the first live run: a run queued already does not go ahead (`pendingRemovalBeforeLive`), and
    /// the removal asks for one once done. The calendars are read when the removal starts, and nothing is removed if
    /// the mode is Dry run again by then (`performRemoval`). One whose removal fails keeps waiting and is tried again
    /// after every live run that goes ahead (`retryPendingRemovals`), or by "Remove all Busy copies".
    private func removePendingBeforeLive() {
        pendingRemovalBeforeLive = true
        removeCopies(.pendingBeforeLive, from: joinedNames(pendingRemovals), clearsResult: false)
    }

    /// In Live, after each live run that went ahead while Busy blocks still wait (`pendingRemovals`: a removal at the
    /// switch, or an earlier retry, failed, or the app quit before the switch's removal ran): removes them again
    /// through the same removal, queued behind that run; a removal that goes through stops them waiting. It asks for
    /// no run of its own, so a removal that keeps failing is tried once per live run, not in a loop.
    private func retryPendingRemovals() {
        removeCopies(.pendingRetry, from: joinedNames(pendingRemovals), clearsResult: false, syncsAfter: false)
    }

    /// Stages a new look-ahead, clamped to the range Settings offers (`SettingsStore.lookAheadRange`).
    func setLookAheadDays(_ days: Int) {
        let range = SettingsStore.lookAheadRange
        let clamped = min(max(days, range.lowerBound), range.upperBound)
        stage { inputs in inputs.lookAheadDays = clamped }
    }

    /// Not staged: it changes when runs happen, not what they write.
    func setIntervalMinutes(_ minutes: Int) {
        settings.intervalMinutes = minutes
        let stored = settings.intervalMinutes
        guard stored != intervalMinutes else { return }
        intervalMinutes = stored
        scheduleTimer()
    }

    func setUnansweredAsBusy(_ on: Bool) {
        stage { inputs in inputs.unansweredAsBusy = on }
    }

    /// Ticks (`on`) or unticks one meeting or one day of a series in the Meetings window, staged: after Apply,
    /// in Live, the next run adds or removes its Busy blocks.
    func toggle(_ occurrence: MeetingsCatalog.Occurrence, to on: Bool) {
        setExcludedKeys(toggling(occurrence, to: on, in: effective.excluded))
    }

    /// A click on a row of the Meetings window: a ticked series is excluded, an unticked or mixed one
    /// included again; a single meeting flips. Staged.
    func toggle(_ row: MeetingsCatalog.Row) {
        setExcludedKeys(toggling(row, in: effective.excluded))
    }

    /// The Title box of one meeting or one day of a series in the Meetings window: `shown` false hides its title,
    /// so its copies show `Busy` in every calendar. Staged: after Apply, in Live, the next run replaces the copies
    /// whose title changes.
    func toggleTitle(_ occurrence: MeetingsCatalog.Occurrence, to shown: Bool) {
        setHiddenTitleKeys(toggling(occurrence, to: shown, in: effective.hiddenTitleKeys))
    }

    /// A click on a row's Title box: a series whose titles all show is hidden, a hidden or mixed one shown again;
    /// a single meeting flips. Staged.
    func toggleTitle(_ row: MeetingsCatalog.Row) {
        setHiddenTitleKeys(toggling(row, tick: row.titleTick, in: effective.hiddenTitleKeys))
    }

    /// The meetings and series excluded, staged ones included: the `o:` and `s:` keys. `i:` keys only make
    /// exceptions to an excluded series, so they are not counted.
    var exclusionCount: Int {
        effective.excluded.filter { $0.hasPrefix("o:") || $0.hasPrefix("s:") }.count
    }

    /// "Clear exclusions" in Settings, staged without asking: Revert brings the exclusions back.
    func clearExclusions() {
        setExcludedKeys([])
    }

    /// A "Blocks from … show" line in Settings: what the copies of `route.source`'s meetings in `route.target` show,
    /// or `nothing` for no copies, staged: the preview counts the copies whose title changes and, for `nothing`, the
    /// copies that go; after Apply, in Live, the next run replaces or removes them. `busyOnly` drops the entry.
    func setCopyTitleFormat(_ format: CopyTitleFormat, for route: CopyRoute) {
        stage { inputs in
            if format == .busyOnly {
                inputs.copyTitleFormats.removeValue(forKey: route)
            } else {
                inputs.copyTitleFormats[route] = format
            }
        }
    }

    private func setExcludedKeys(_ keys: Set<String>) {
        stage { inputs in inputs.excluded = keys }
    }

    private func setHiddenTitleKeys(_ keys: Set<String>) {
        stage { inputs in inputs.hiddenTitleKeys = keys }
    }

    // MARK: - Staged changes

    /// What every control and the Meetings window's ticks show: the staged inputs while there are any, else the
    /// applied ones.
    var effective: SyncInputs {
        staged ?? applied
    }

    /// How many changes are staged (`changeCount(from:)`); 0 while nothing is.
    var stagedChangeCount: Int {
        staged?.changeCount(from: applied) ?? 0
    }

    /// Whether `preview` was worked out before the latest Calendar change, so its counts may no longer hold.
    var previewPredatesCalendarChange: Bool {
        preview != nil && previewCalendarChanges != calendarChanges
    }

    /// Whether `preview` was worked out on another calendar day than today: its window started that day, so its
    /// counts no longer hold.
    private var previewIsFromAnotherDay: Bool {
        guard let previewDay else { return false }
        return previewDay != Calendar.current.startOfDay(for: Date())
    }

    /// Whether Apply can act on `preview`'s counts: no `skippedReason`, a removal count for each calendar Apply
    /// clears (`previewClearing`), and not held (`ChangePreview.heldReason`), unless the staged look-ahead is
    /// shorter than the applied one (`heldPreviewIsApplicable`, Ruling 18). A held preview clears by itself: the
    /// retry works it out again until the preview's own wait has passed or the events are back.
    private var previewIsUsable: Bool {
        guard let preview, preview.skippedReason == nil, let previewClearing else { return false }
        guard previewClearing.calendars.allSatisfy({ preview.removals[$0] != nil }) else { return false }
        guard preview.heldReason != nil else { return true }
        guard let previewInputs else { return false }
        return heldPreviewIsApplicable(stagedLookAheadDays: previewInputs.lookAheadDays,
                                       appliedLookAheadDays: applied.lookAheadDays)
    }

    /// Whether Apply may go ahead, so nothing is written or removed on counts the user did not see: something is
    /// staged and its preview has landed, for exactly these staged inputs and with no newer one on the way, usable
    /// (`previewIsUsable`), for the calendars Apply would clear now and the same "syncing stops"
    /// (`clearing(applying:)`), and worked out today; in Live also not older than the latest Calendar change. A
    /// preview Apply cannot act on is worked out again until it can (`schedulePreviewRetry`), and one from another
    /// day on the next minute (`clockTicked`).
    var canApplyStagedChanges: Bool {
        guard let staged, !previewInFlight, preview != nil, previewInputs == staged, previewIsUsable,
              previewClearing == clearing(applying: staged), !previewIsFromAnotherDay else { return false }
        return mode != .live || !previewPredatesCalendarChange
    }

    /// Makes the staged inputs the applied ones (`canApplyStagedChanges`, else nothing happens, and a preview from
    /// another day is worked out again). Saves each setting that changed, the routes before the selection, as an
    /// untick did, and keeps only routes between the calendars ticked now. An app stopped between those two writes
    /// can be left with routes stored for a calendar that is not ticked, say one ticked anew with its pairs picked;
    /// the next launch drops them (`loadCopyTitleRoutes`). The calendars waiting for Live (`pendingRemovals`) are saved
    /// before the selection, so an app stopped in between leaves no unticked calendar with Busy blocks nothing waits
    /// to remove. Then, in Live, removes the Busy copies, from today to +400 days, in the calendars the bar counted
    /// (`previewClearing`): the ones Apply unticks that Calendar lists, and, when it takes the listed selection from two
    /// calendars or more to fewer, the ones left too, since syncing stops and no run would sweep them; then syncs. In
    /// Dry run, which writes nothing, it removes nothing: those calendars wait for Live instead, with the bar's counts
    /// (`PendingRemovals.afterApply`). In either mode a waiting calendar ticked again in a selection that syncs stops
    /// waiting. Logs counts only.
    func applyStagedChanges() {
        guard let inputs = staged, canApplyStagedChanges, let removing = previewClearing?.calendars else {
            if staged != nil, !previewInFlight, previewIsFromAnotherDay { schedulePreview() }
            return
        }
        let before = applied
        let count = inputs.changeCount(from: before)
        let removalMode = mode
        let pending = PendingRemovals.afterApply(pendingRemovals, selecting: inputs.selected,
                                                 listed: Set(calendars.map(\.ref)), clearing: removing,
                                                 mode: removalMode)
        let pendingCounts = PendingRemovals.countsAfterApply(pendingRemovalCounts, pending: pending,
                                                             removals: preview?.removals ?? [:])
        var next = inputs
        next.copyTitleFormats = keepingRoutes(between: inputs.selected, from: inputs.copyTitleFormats)
        if next.copyTitleFormats != before.copyTitleFormats { settings.copyTitleRoutes = next.copyTitleFormats }
        if next.calendarNames != before.calendarNames { settings.calendarNames = next.calendarNames }
        if next.excluded != before.excluded { settings.excludedKeys = next.excluded.sorted() }
        if next.hiddenTitleKeys != before.hiddenTitleKeys { settings.hiddenTitleKeys = next.hiddenTitleKeys.sorted() }
        if next.lookAheadDays != before.lookAheadDays {
            settings.lookAheadDays = next.lookAheadDays
            next.lookAheadDays = settings.lookAheadDays
        }
        if next.unansweredAsBusy != before.unansweredAsBusy { settings.unansweredAsBusy = next.unansweredAsBusy }
        setPendingRemovals(pending, counts: pendingCounts)
        if next.selected != before.selected { settings.selectedCalendarIDs = next.selected.map(\.id) }
        staged = nil
        dropPreview()
        applied = next
        // A pair set to Nothing or back changes which meetings are copied, so the catalog's lists wait for a run.
        let nothingPairs = Self.nothingPairs(next.copyTitleFormats)
        let nothingPairsBefore = Self.nothingPairs(before.copyTitleFormats)
        let structure = next.selected != before.selected || next.lookAheadDays != before.lookAheadDays
            || next.unansweredAsBusy != before.unansweredAsBusy || nothingPairs != nothingPairsBefore
        inputsChanged(structure: structure)
        rebuildCatalog()
        if next.excluded != before.excluded {
            logger.info("exclusions changed, now \(next.excluded.count, privacy: .public)")
        }
        if next.hiddenTitleKeys != before.hiddenTitleKeys {
            logger.info("hidden titles changed, now \(next.hiddenTitleKeys.count, privacy: .public)")
        }
        let titledPairs = next.copyTitleFormats.filter(\.value.showsTitle)
        if titledPairs != before.copyTitleFormats.filter(\.value.showsTitle) {
            logger.info("copy titles: \(titledPairs.count, privacy: .public) pairs show titles")
        }
        if nothingPairs.count != nothingPairsBefore.count {
            logger.info("copy pairs set to nothing: \(nothingPairs.count, privacy: .public)")
        }
        logger.info("applied staged changes: \(count, privacy: .public)")
        if removalMode == .dryRun || removing.isEmpty {
            requestSync()
        } else {
            // Syncs once the removal is done.
            removeCopies(.calendars(removing), from: joinedNames(removing), clearsResult: false)
        }
    }

    /// The pairs set to Nothing in `formats`.
    private static func nothingPairs(_ formats: [CopyRoute: CopyTitleFormat]) -> Set<CopyRoute> {
        Set(formats.filter { $0.value == .nothing }.keys)
    }

    /// Makes `next` the calendars waiting for Live, with `counts` for them (only theirs are kept; nil when none
    /// waits), saves them when they changed and logs how many there are, never which.
    private func setPendingRemovals(_ next: [CalendarRef], counts: [CalendarRef: Int]?) {
        let kept = counts?.filter { next.contains($0.key) }
        pendingRemovalCounts = next.isEmpty || kept?.isEmpty == true ? nil : kept
        guard next != pendingRemovals else { return }
        pendingRemovals = next
        settings.pendingRemovals = next.map(\.id)
        logger.info("pending removals: \(next.count, privacy: .public) calendars")
    }

    /// Drops from `pendingRemovals` the calendars the applied selection ticks while it syncs, by the calendars Calendar
    /// lists now (`PendingRemovals.stillWaiting`); their counts go with them.
    private func keepWaitingOnlyUnsynced() {
        setPendingRemovals(PendingRemovals.stillWaiting(pendingRemovals, selected: applied.selected,
                                                        listed: Set(calendars.map(\.ref))),
                           counts: pendingRemovalCounts)
    }

    /// After a dry run, while Busy blocks wait for Live: how many sit in each of those calendars, from today to +400
    /// days (`SyncEngine.countCopies`, which leaves the previews' memory alone), a calendar Calendar does not list
    /// holding none (`PendingRemovals.counts`). Not known (nil) when they cannot be read. Dropped when the calendars
    /// waiting changed meanwhile: the change set their counts. Called in the serial chain.
    private func countPendingRemovals() async {
        let pending = pendingRemovals
        guard !pending.isEmpty else { return }
        let read = await engine.countCopies(in: pending)
        guard pending == pendingRemovals else { return }
        if let failure = read.failure {
            pendingRemovalCounts = nil
            logger.info("pending removals not counted: \(failure, privacy: .public)")
        } else {
            pendingRemovalCounts = PendingRemovals.counts(of: pending, read: read.counts)
        }
    }

    /// Drops the staged inputs: every control shows the applied settings again.
    func revertStagedChanges() {
        guard let inputs = staged else { return }
        let count = inputs.changeCount(from: applied)
        staged = nil
        dropPreview()
        rebuildCatalog()
        logger.info("reverted staged changes: \(count, privacy: .public)")
    }

    /// Edits the staged inputs, made from `applied` on the first edit; writes nothing and does not sync
    /// (`normalized(_:against:calendars:)` keeps them comparable and drops a staged rename that has no row to show
    /// it; `restage()` applies that again when the listing changes). Inputs that make no change to `applied`
    /// (`changeCount(from:)` 0) are dropped, so editing back removes the bar. A change asks for a new preview, and
    /// logs the count when it differs from the count before this edit: Look ahead and short names are staged on every
    /// keystroke, which mostly changes a value already staged.
    private func stage(_ edit: (inout SyncInputs) -> Void) {
        let base = applied
        let countBefore = stagedChangeCount
        var inputs = staged ?? base
        edit(&inputs)
        inputs = Self.normalized(inputs, against: base, calendars: calendars)
        let count = inputs.changeCount(from: base)
        let next = count == 0 ? nil : inputs
        guard next != staged else { return }
        staged = next
        // A new change starts the retry's fast phase again (`ChangePreview.retryDelay`).
        unusablePreviewsSince = nil
        rebuildCatalog()
        if count != countBefore { logger.info("staged changes: \(count, privacy: .public)") }
        if next == nil {
            dropPreview()
        } else {
            schedulePreview()
        }
    }

    /// Normalises the staged inputs again (`normalized(_:against:calendars:)`) after something they depend on
    /// besides the edits changed, the listing: drops the staged renames left without a row. Nothing when nothing is
    /// staged or nothing changes.
    private func restage() {
        guard staged != nil else { return }
        stage { _ in }
    }

    /// The calendars `inputs` tick that `applied` ticks keep the applied order, and the ones ticked anew follow in
    /// the order they were ticked, so the order is never a change. A route between two calendars `inputs` tick is
    /// the staged one; every other route is the applied one, present or absent: unticking a calendar stages no
    /// change to its pairs (Apply drops them), and ticking it again before Apply finds the applied ones, while a
    /// calendar ticked anew finds none, as only routes between applied calendars are stored, so it starts at
    /// `Busy only`. A calendar keeps a staged short name only while Settings gives it a rename row for these inputs
    /// (`settingsCalendarList`, `namesKeepingRenames`): a staged rename shows on that row only, so one whose row went,
    /// with the listing or an untick of a calendar ticked anew, goes back to the applied name, whatever order the
    /// rename field's own callbacks come in.
    private static func normalized(_ inputs: SyncInputs, against applied: SyncInputs,
                                   calendars: [CalendarInfo]) -> SyncInputs {
        var inputs = inputs
        let ticked = Set(inputs.selected)
        let appliedTicked = Set(applied.selected)
        var seen = Set<CalendarRef>()
        let kept = applied.selected.filter(ticked.contains)
        let added = inputs.selected.filter { !appliedTicked.contains($0) }
        inputs.selected = (kept + added).filter { seen.insert($0).inserted }
        func between(_ route: CopyRoute) -> Bool { ticked.contains(route.source) && ticked.contains(route.target) }
        inputs.copyTitleFormats = inputs.copyTitleFormats.filter { between($0.key) }
            .merging(applied.copyTitleFormats.filter { !between($0.key) }) { staged, _ in staged }
        let rows = Set(settingsCalendarList(calendars, effective: inputs, applied: applied).main.map(\.ref.id))
        inputs.calendarNames = namesKeepingRenames(of: rows, staged: inputs.calendarNames,
                                                   applied: applied.calendarNames)
        return inputs
    }

    /// The calendars Apply clears, in order, and whether syncing stops with it (`clearing(applying:)`).
    private struct Clearing: Equatable {
        var calendars: [CalendarRef]
        var stopsSyncing: Bool
    }

    /// The calendars Apply clears for `inputs`, among the ones Calendar lists: the ones `applied` ticks and
    /// `inputs` does not and, when Apply takes the listed selection from two calendars or more to fewer, the ones
    /// left as well, as an untick did before Apply existed (`calendarsAlsoCleared`): syncing stops, so no run would
    /// sweep the copies of the dropped calendars' meetings out of them. A listed selection of fewer than two stays
    /// stopped and clears nothing more; a calendar Calendar no longer lists has nothing to remove. In Dry run, which
    /// writes nothing, Apply leaves these to the switch to Live instead (`pendingRemovals`).
    private func clearing(applying inputs: SyncInputs) -> Clearing {
        let listed = Set(calendars.map(\.ref))
        let ticked = Set(inputs.selected)
        let stops = Set(applied.selected).intersection(listed).count >= 2 && ticked.intersection(listed).count < 2
        var seen = Set<CalendarRef>()
        let cleared = applied.selected.filter { !ticked.contains($0) } + (stops ? inputs.selected : [])
        return Clearing(calendars: cleared.filter { listed.contains($0) && seen.insert($0).inserted },
                        stopsSyncing: stops)
    }

    /// Asks for a preview of `staged` 0.4 s from now; a newer request replaces it. `previewInFlight` at once, so
    /// Apply waits through the delay too.
    private func schedulePreview() {
        previewInFlight = true
        requestPreview(after: .milliseconds(400))
    }

    /// Asks for a preview of `staged` again after one Apply cannot act on (`previewIsUsable`), so the bar clears by
    /// itself once the cause has gone: every 10 s for the first minute since the first such preview in a row, then
    /// every 60 s (`ChangePreview.retryDelay`); a staged edit or a Calendar change starts the fast phase again. Not
    /// `previewInFlight`: the bar keeps showing the reason meanwhile, and Apply stays off, since the preview it has
    /// is not usable. A newer request replaces it.
    private func schedulePreviewRetry() {
        let since = unusablePreviewsSince ?? Date()
        unusablePreviewsSince = since
        let delay = ChangePreview.retryDelay(sinceFirstUnusable: Date().timeIntervalSince(since))
        requestPreview(after: .seconds(delay))
    }

    private func requestPreview(after delay: Duration) {
        previewGeneration += 1
        let generation = previewGeneration
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, generation == self.previewGeneration else { return }
            self.enqueue { [weak self] in await self?.performPreview(generation) }
        }
    }

    /// Nothing is staged any more: no preview is shown or worked out, and the engine forgets when previews first
    /// found calendars held (`SyncEngine.forgetPreviewHolds`), so the next staged change waits out a hold of its own.
    private func dropPreview() {
        previewGeneration += 1
        previewTask?.cancel()
        previewTask = nil
        preview = nil
        previewInputs = nil
        previewClearing = nil
        previewDay = nil
        unusablePreviewsSince = nil
        previewInFlight = false
        enqueue { [weak self] in await self?.engine.forgetPreviewHolds() }
    }

    /// Works out the preview in the serial chain, like a run: access, store and calendars first, then a dry run of
    /// the staged inputs that changes nothing (`SyncEngine.preview`), labelled by the staged names. Dropped when a
    /// newer request or a drop of the staged inputs came meanwhile; a change of the listing on the way asks for a
    /// newer one (`loadCalendars`). One Apply cannot act on asks again (`schedulePreviewRetry`). Logs counts only.
    private func performPreview(_ generation: Int) async {
        guard generation == previewGeneration else { return }
        let changes = calendarChanges
        refreshAccess()
        resetStoreIfNeeded()
        if access == .granted { await loadCalendars() }
        guard generation == previewGeneration, let inputs = staged else { return }
        let clear = clearing(applying: inputs)
        // Before the engine reads: a preview that reads across midnight counts as the earlier day's.
        let day = Calendar.current.startOfDay(for: Date())
        var result = await engine.preview(settings: inputs.settings(sourceLabels: sourceLabels(of: inputs)),
                                          dropping: clear.calendars)
        guard generation == previewGeneration else { return }
        // Described as Apply acts: the engine counts the calendars left whenever fewer than two stay ticked.
        let cleared = Set(clear.calendars)
        result.removals = result.removals.filter { cleared.contains($0.key) }
        result.syncingStops = clear.stopsSyncing
        preview = result
        previewInputs = inputs
        previewClearing = clear
        previewDay = day
        previewCalendarChanges = changes
        previewInFlight = false
        if previewIsUsable {
            unusablePreviewsSince = nil
        } else {
            schedulePreviewRetry()
        }
        logger.info("""
            preview: add \(result.add, privacy: .public), remove \(result.remove, privacy: .public), \
            retitle \(result.retitle, privacy: .public)
            """)
    }

    func setStartAtLogin(_ on: Bool) {
        startAtLogin = on
        settings.startAtLogin = on
        loginItemMessage = LoginItem.setEnabled(on, settings: settings)
    }

    /// "Remove all Busy copies", confirmed by the user beforehand: pauses syncing first so no run puts
    /// them back, then removes every copy in the applied selected calendars and in the ones waiting for Live
    /// (`pendingRemovals`), at once in any mode; the waiting ones whose removal went through stop waiting. Not staged;
    /// staged changes stay.
    func removeAllBusyCopies() {
        setPaused(true)
        let listed = Set(calendars.map(\.ref))
        var seen = Set<CalendarRef>()
        let refs = (applied.selected + pendingRemovals).filter { listed.contains($0) && seen.insert($0).inserted }
        removeCopies(.allSelected, from: refs.isEmpty ? "the selected calendars" : joinedNames(refs),
                     clearsResult: true)
    }

    /// For the confirmation of "Remove all Busy copies…" (`StatusText.removeAllMessage`): the applied selected
    /// calendars that Calendar lists and that do not wait for Live, by short name in selection order; nil when none.
    var removeAllSelectedNames: String? {
        let listed = Set(calendars.map(\.ref))
        let refs = applied.selected.filter { listed.contains($0) && !pendingRemovals.contains($0) }
        return refs.isEmpty ? nil : joinedNames(refs)
    }

    /// The same for the calendars waiting for Live that Calendar lists, in the order they joined; nil when none.
    var removeAllPendingNames: String? {
        let listed = Set(calendars.map(\.ref))
        let refs = pendingRemovals.filter(listed.contains)
        return refs.isEmpty ? nil : joinedNames(refs)
    }

    /// Opens the settings window when a notification is clicked.
    func onNotificationClick(_ action: @escaping @MainActor () -> Void) {
        notifier.onClick = action
    }

    private enum RemovalTarget {
        /// "Remove all Busy copies": the applied selected calendars and the ones waiting for Live, resolved when the
        /// removal runs, from the fresh listing.
        case allSelected
        /// Apply's in Live: the calendars the bar counted.
        case calendars([CalendarRef])
        /// The switch to Live's (`removePendingBeforeLive`): the calendars waiting for Live when the removal runs,
        /// only while the mode is still Live.
        case pendingBeforeLive
        /// The same after a live run, while some still wait (`retryPendingRemovals`).
        case pendingRetry
    }

    /// While it waits and runs, `removalsInFlight` keeps Live from being offered (`liveSwitch`). Asks for a run once
    /// done, unless `syncsAfter` is false (`retryPendingRemovals`, which a run asked for).
    private func removeCopies(_ target: RemovalTarget, from place: String, clearsResult: Bool, syncsAfter: Bool = true) {
        removalsInFlight += 1
        removalSummary = nil
        enqueue { [weak self] in
            guard let self else { return }
            await self.performRemoval(target, from: place, clearsResult: clearsResult)
            self.removalsInFlight -= 1
            // Queued behind the removal; nothing happens while paused.
            if syncsAfter { self.requestSync() }
        }
    }

    /// Removes copies only in calendars the fresh listing still has: one missing calendar would make the
    /// store refuse the whole batch. Missing ones are named in the summary. A removal only Live asked for goes ahead
    /// only while the mode is still Live (`liveRemovalStillWanted`). The calendars waiting for Live that it covered
    /// stop waiting once their removal went through (`PendingRemovals.afterRemoval`); when it does not go ahead, they
    /// keep waiting. While something is staged, its preview is worked out again once the removal is done.
    private func performRemoval(_ target: RemovalTarget, from place: String, clearsResult: Bool) async {
        if case .pendingBeforeLive = target { pendingRemovalBeforeLive = false }
        guard liveRemovalStillWanted(target) else { return }
        let knownNames = Dictionary(calendars.map { ($0.ref, shortName($0.ref)) }, uniquingKeysWith: { first, _ in first })
        refreshAccess()
        guard access == .granted else {
            removalSummary = "Nothing removed from \(place): \(SyncEngine.accessNeeded)."
            return
        }
        resetStoreIfNeeded()
        await loadCalendars()
        if let problem = calendarsError {
            removalSummary = "Nothing removed from \(place): \(problem)."
            return
        }
        // Again after listing the calendars: the mode may have changed meanwhile.
        guard liveRemovalStillWanted(target) else { return }
        switch target {
        case .pendingBeforeLive, .pendingRetry:
            // Never a calendar ticked in a selection that syncs: runs reconcile it. When that leaves none (an Apply or
            // a listing change since the switch or the run), there is nothing to remove.
            keepWaitingOnlyUnsynced()
            if pendingRemovals.isEmpty { return }
        case .allSelected, .calendars:
            break
        }
        var seen = Set<CalendarRef>()
        let wanted: [CalendarRef] = switch target {
        case .allSelected: (applied.selected + pendingRemovals).filter { seen.insert($0).inserted }
        case let .calendars(refs): refs
        case .pendingBeforeLive, .pendingRetry: pendingRemovals
        }
        let listed = Set(calendars.map(\.ref))
        let present = wanted.filter { listed.contains($0) }
        let missing = wanted.filter { !listed.contains($0) }
        // The removal goes ahead, so the last result's counts no longer hold; a run that was queued before it
        // ran ahead of it and may have counted these copies. Not for a retry after a live run: it clears only
        // calendars that run did not read (none waiting is ticked in a selection that syncs), so the run's counts
        // hold, and a retry that keeps failing does not leave the menu and the Meetings window without them.
        if case .pendingRetry = target {} else { inputsChanged() }
        let report = await engine.removeAllCopies(in: present)
        if staged != nil { schedulePreview() }
        if pendingRemovals.contains(where: wanted.contains) {
            // A failure names no calendar, so each one covered keeps waiting then, its count no longer known.
            setPendingRemovals(PendingRemovals.afterRemoval(pendingRemovals, present: present, missing: missing,
                                                            failed: !report.failures.isEmpty),
                               counts: pendingRemovalCounts?.filter { !wanted.contains($0.key) })
        }
        logger.info("""
            removed \(report.deleted, privacy: .public) copies from \(present.count, privacy: .public) calendars, \
            failed \(report.failures.count, privacy: .public), skipped \(missing.count, privacy: .public) missing
            """)
        for failure in report.failures {
            logger.error("removal failure: \(failure, privacy: .public)")
        }
        // The last result's counts and the last live changes describe copies that are gone now.
        if clearsResult {
            lastResult = nil
            lastRunSelectedIDs = []
            lastRunGeneration = nil
            lastRunStructureGeneration = nil
            titles = [:]
            clearDayTitles()
            liveChanges = LiveChanges()
            rebuildCatalog()
        }
        removalSummary = Self.summary(of: report, from: place, missing: missing.map { knownNames[$0] ?? "an unnamed calendar" })
    }

    /// Whether a removal may go ahead now. "Remove all Busy copies" acts in any mode; Apply's in Live, the switch to
    /// Live's and its retries do not once the mode is Dry run again, which writes nothing: Apply's calendars then wait for Live
    /// (`pendingRemovals`), as an Apply in Dry run leaves them, and the ones waiting keep waiting.
    private func liveRemovalStillWanted(_ target: RemovalTarget) -> Bool {
        guard mode != .live else { return true }
        switch target {
        case .allSelected:
            return true
        case let .calendars(refs):
            setPendingRemovals(PendingRemovals.afterApply(pendingRemovals, selecting: applied.selected,
                                                          listed: Set(calendars.map(\.ref)), clearing: refs,
                                                          mode: .dryRun),
                               counts: pendingRemovalCounts)
            // What the switch to Live would remove changed.
            inputsChanged()
            return false
        case .pendingBeforeLive, .pendingRetry:
            return false
        }
    }

    /// Engine failures that stand for the whole batch: fixed texts without identifiers.
    private static let batchFailures: Set<String> = [
        SyncEngine.accessNeeded, SyncEngine.readFailed, SyncEngine.saveFailed, SyncEngine.missing,
        CalendarStoreError.incompleteEvent(calendarID: "").errorDescription ?? SyncEngine.readFailed,
    ]

    /// Counts only; failure labels and identifiers stay in the log.
    private static func summary(of report: ApplyReport, from place: String, missing: [String]) -> String {
        var parts: [String] = []
        if report.deleted == 0, let reason = report.failures.first(where: { batchFailures.contains($0) }) {
            parts.append("Nothing removed from \(place): \(reason).")
        } else {
            let n = report.deleted
            parts.append(n == 0
                ? "No busy blocks removed from \(place)."
                : "Removed \(n) busy \(n == 1 ? "block" : "blocks") from \(place).")
            if !report.failures.isEmpty { parts.append("\(report.failures.count) could not be removed.") }
        }
        if !missing.isEmpty {
            parts.append("Skipped, no longer in Calendar: \(missing.joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Triggers

    private func scheduleTimer() {
        timerTask?.cancel()
        timerTask = repeating(every: .seconds(intervalMinutes * 60)) { $0.requestSync() }
    }

    private func repeating(
        every interval: Duration,
        _ action: @escaping @MainActor (AppModel) -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                action(self)
            }
        }
    }

    private func observeSystem() {
        on(.EKEventStoreChanged) { $0.storeChanged() }
        // The status menu opening, and the app becoming active (settings window, System Settings
        // round trip): pick up a fresh grant promptly and refresh relative times.
        on(NSMenu.didBeginTrackingNotification) { $0.userLooked() }
        on(NSApplication.didBecomeActiveNotification) { $0.userLooked() }
    }

    private func on(_ name: Notification.Name, _ handler: @escaping @MainActor @Sendable (AppModel) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        })
    }

    /// Calendar data changed (also after our own writes): sync once things settle for 10 s. While something is
    /// staged, the preview is worked out again, and Apply in Live waits for it (`canApplyStagedChanges`).
    private func storeChanged() {
        calendarChanges += 1
        // Starts the retry's fast phase again (`ChangePreview.retryDelay`).
        unusablePreviewsSince = nil
        if staged != nil { schedulePreview() }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.requestSync()
        }
    }

    /// Every minute: relative texts follow the clock (`now`), which also redraws Apply, and a preview worked out on
    /// another day is worked out again (`canApplyStagedChanges`).
    private func clockTicked() {
        now = Date()
        if staged != nil, !previewInFlight, previewIsFromAnotherDay { schedulePreview() }
    }

    private func userLooked() {
        now = Date()
        refreshAccess()
    }
}
