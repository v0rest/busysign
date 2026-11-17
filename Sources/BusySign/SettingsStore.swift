import BusySignCore
import Foundation
import os

private let logger = Logger(subsystem: "io.github.v0rest.busysign", category: "settings")

/// The app's settings in `UserDefaults`. Reads fall back to the defaults; reads and writes clamp numbers to
/// the ranges the settings window offers (the only place that clamps), so a value written by hand
/// (`defaults write`) can never stall the timer.
struct SettingsStore {
    enum Key {
        static let selectedCalendarIDs = "selectedCalendarIDs"
        static let lookAheadDays = "lookAheadDays"
        static let intervalMinutes = "intervalMinutes"
        static let unansweredAsBusy = "unansweredAsBusy"
        static let startAtLogin = "startAtLogin"
        static let mode = "mode"
        static let paused = "paused"
        static let changeTracker = "changeTracker"
        static let staleThresholdHours = "staleThresholdHours"
        static let loginItemRegisteredVersion = "loginItemRegisteredVersion"
        static let excludedKeys = "excludedKeys"
        static let calendarNames = "calendarNames"
        static let calendarFirstSeen = "calendarFirstSeen"
        static let copyTitleFormats = "copyTitleFormats"
        static let copyTitleRoutes = "copyTitleRoutes"
        static let hiddenTitleKeys = "hiddenTitleKeys"
        static let pendingRemovals = "pendingRemovals"
    }

    static let lookAheadRange = 1...90
    static let intervalRange = 1...60

    private let defaults: UserDefaults
    /// The preferences domain `defaults` writes to and removes from. Read on its own where a key from another
    /// domain (the command line's or the global one) must not count.
    private let domain: String

    /// The app's own settings: `UserDefaults.standard`, whose domain is the bundle identifier, or the process name
    /// for a build run outside its bundle, as macOS names that domain.
    init() {
        self.init(defaults: .standard, domain: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
    }

    /// The settings in the suite `suiteName`, for a check on a throwaway suite; nil when macOS refuses that name.
    init?(suiteName: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.init(defaults: defaults, domain: suiteName)
    }

    private init(defaults: UserDefaults, domain: String) {
        self.defaults = defaults
        self.domain = domain
    }

    /// The selected calendar identifiers; `nil` while the key has never been written (first launch).
    var selectedCalendarIDs: [String]? {
        get { defaults.object(forKey: Key.selectedCalendarIDs) as? [String] }
        nonmutating set { defaults.set(newValue, forKey: Key.selectedCalendarIDs) }
    }

    var lookAheadDays: Int {
        get { int(Key.lookAheadDays, default: 30, in: Self.lookAheadRange) }
        nonmutating set { defaults.set(Self.clamp(newValue, to: Self.lookAheadRange), forKey: Key.lookAheadDays) }
    }

    var intervalMinutes: Int {
        get { int(Key.intervalMinutes, default: 5, in: Self.intervalRange) }
        nonmutating set { defaults.set(Self.clamp(newValue, to: Self.intervalRange), forKey: Key.intervalMinutes) }
    }

    var unansweredAsBusy: Bool {
        get { bool(Key.unansweredAsBusy, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.unansweredAsBusy) }
    }

    var startAtLogin: Bool {
        get { bool(Key.startAtLogin, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.startAtLogin) }
    }

    var mode: SyncMode {
        get { defaults.string(forKey: Key.mode).flatMap(SyncMode.init(rawValue:)) ?? .dryRun }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.mode) }
    }

    var paused: Bool {
        get { bool(Key.paused, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.paused) }
    }

    /// How long a selected calendar's real events go unchanged before Settings notes it (hidden; set by hand
    /// with `defaults write`). Read as a Double so a fraction of an hour works; absent or not positive means
    /// 168, a week.
    var staleThresholdHours: Double {
        guard let hours = number(Key.staleThresholdHours), hours.isFinite, hours > 0 else { return 168 }
        return hours
    }

    /// `ExclusionKey`s of the meetings and series the user chose not to mirror, on this Mac only. Opaque
    /// keys, never titles. Empty when absent or not a list of strings.
    var excludedKeys: [String] {
        get { defaults.stringArray(forKey: Key.excludedKeys) ?? [] }
        nonmutating set { defaults.set(newValue, forKey: Key.excludedKeys) }
    }

    /// Short names the user gave calendars, by calendar identifier, on this Mac only. Calendar names, never
    /// event content. Empty when absent; entries that are not strings are dropped.
    var calendarNames: [String: String] {
        get { (defaults.dictionary(forKey: Key.calendarNames) ?? [:]).compactMapValues { $0 as? String } }
        nonmutating set { defaults.set(newValue, forKey: Key.calendarNames) }
    }

    /// What the copies on each pair of calendars show, or that the pair copies nothing (`nothing`) (`CopyRoute`:
    /// where the Busy blocks come from and where they go), on this Mac only: calendar identifiers and
    /// `CopyTitleFormat` raw values, never titles. A route that is missing shows `busyOnly`, which is never stored;
    /// `nothing` is stored and read like the title choices. Stored as a list of `["source": id, "target": id, "format":
    /// raw]`, sorted by source, then target, so the same routes are always stored the same way. Empty when absent;
    /// entries that are not such a dictionary, have an empty identifier, run from a calendar to itself, or carry
    /// `busyOnly` or an unknown format are dropped.
    var copyTitleRoutes: [CopyRoute: CopyTitleFormat] {
        get {
            var routes: [CopyRoute: CopyTitleFormat] = [:]
            for case let entry as [String: Any] in defaults.array(forKey: Key.copyTitleRoutes) ?? [] {
                guard let source = entry["source"] as? String, let target = entry["target"] as? String,
                      !source.isEmpty, !target.isEmpty, source != target,
                      let raw = entry["format"] as? String, let format = CopyTitleFormat(rawValue: raw),
                      format != .busyOnly else { continue }
                routes[CopyRoute(source: CalendarRef(id: source), target: CalendarRef(id: target))] = format
            }
            return routes
        }
        nonmutating set {
            let entries = newValue
                .sorted { ($0.key.source.id, $0.key.target.id) < ($1.key.source.id, $1.key.target.id) }
                .map { ["source": $0.key.source.id, "target": $0.key.target.id, "format": $0.value.rawValue] }
            defaults.set(entries, forKey: Key.copyTitleRoutes)
        }
    }

    /// What the copies in each calendar showed before the choice was made per pair (`copyTitleRoutes`), by
    /// calendar identifier: `CopyTitleFormat` raw values, never titles. Read once, to move them to pairs, from the
    /// app's own domain only, the one `removePerCalendarCopyTitleFormats` clears. Empty when absent; entries that
    /// are not strings or not a known format are dropped.
    var copyTitleFormats: [String: String] {
        ((ownValues[Key.copyTitleFormats] as? [String: Any]) ?? [:])
            .compactMapValues { $0 as? String }
            .filter { CopyTitleFormat(rawValue: $0.value) != nil }
    }

    /// Whether the per-calendar choices of before (`copyTitleFormats`) are still stored in the app's own domain,
    /// whatever they hold. The same key on the command line or in the global domain does not count: removing it
    /// from the app's domain could not clear it, and the choices would move to pairs again on every launch.
    var hasPerCalendarCopyTitleFormats: Bool {
        ownValues[Key.copyTitleFormats] != nil
    }

    /// Removes the per-calendar choices of before (`copyTitleFormats`), once they have been moved to pairs.
    func removePerCalendarCopyTitleFormats() {
        defaults.removeObject(forKey: Key.copyTitleFormats)
    }

    /// `ExclusionKey`s of the meetings and series whose copies show `Busy` whatever their pair's "Blocks
    /// from … show", on this Mac only. Opaque keys, never titles. Empty when absent or not a list of strings.
    var hiddenTitleKeys: [String] {
        get { defaults.stringArray(forKey: Key.hiddenTitleKeys) ?? [] }
        nonmutating set { defaults.set(newValue, forKey: Key.hiddenTitleKeys) }
    }

    /// The calendars whose Busy blocks wait for Live (`AppModel.pendingRemovals`), by identifier, in the order they
    /// joined, so a quit keeps them. Identifiers only. Empty when absent or not a list of strings.
    var pendingRemovals: [String] {
        get { defaults.stringArray(forKey: Key.pendingRemovals) ?? [] }
        nonmutating set { defaults.set(newValue, forKey: Key.pendingRemovals) }
    }

    /// Calendar identifiers in the order Calendar first listed them on this Mac, for numbering calendars whose
    /// names clash. Identifiers only. Empty when absent or not a list of strings.
    var calendarFirstSeen: [String] {
        get { defaults.stringArray(forKey: Key.calendarFirstSeen) ?? [] }
        nonmutating set { defaults.set(newValue, forKey: Key.calendarFirstSeen) }
    }

    /// The app version the login item was last registered for.
    var loginItemRegisteredVersion: String? {
        get { defaults.string(forKey: Key.loginItemRegisteredVersion) }
        nonmutating set { defaults.set(newValue, forKey: Key.loginItemRegisteredVersion) }
    }

    /// The stored tracker, or an empty one when none is stored or it cannot be decoded.
    var changeTracker: ChangeTracker {
        get {
            guard let data = defaults.data(forKey: Key.changeTracker) else { return ChangeTracker() }
            do {
                return try JSONDecoder().decode(ChangeTracker.self, from: data)
            } catch {
                logger.error("stored change tracker unreadable; starting a new one")
                return ChangeTracker()
            }
        }
        nonmutating set {
            do {
                defaults.set(try JSONEncoder().encode(newValue), forKey: Key.changeTracker)
            } catch {
                logger.error("change tracker not saved")
            }
        }
    }

    /// What the app's own domain holds, without the command line's and the global domain's values.
    private var ownValues: [String: Any] {
        defaults.persistentDomain(forName: domain) ?? [:]
    }

    // MARK: - Reading numbers written by the app or by hand

    private func number(_ key: String) -> Double? {
        (defaults.object(forKey: key) as? NSNumber)?.doubleValue
    }

    private func int(_ key: String, default value: Int, in range: ClosedRange<Int>) -> Int {
        guard let n = number(key), n.isFinite else { return value }
        let clamped = min(max(n, Double(range.lowerBound)), Double(range.upperBound))
        return Int(clamped.rounded())
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func bool(_ key: String, default value: Bool) -> Bool {
        (defaults.object(forKey: key) as? NSNumber)?.boolValue ?? value
    }
}
