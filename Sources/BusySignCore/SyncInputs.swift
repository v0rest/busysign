import Foundation

/// The settings that decide what BusySign writes, as one value: the app keeps the applied ones, used by runs, and
/// the ones staged for Apply.
public struct SyncInputs: Equatable, Sendable {
    /// The ticked calendars, in the order they were ticked.
    public var selected: [CalendarRef]
    public var lookAheadDays: Int
    public var unansweredAsBusy: Bool
    /// `ExclusionKey`s of the meetings and series the user chose not to mirror.
    public var excluded: Set<String>
    /// `ExclusionKey`s of the meetings and series whose copies show `Busy` whatever their route's format.
    public var hiddenTitleKeys: Set<String>
    /// What the copies on each route show, or `nothing` for a route that copies nothing
    /// (`SyncSettings.copyTitleFormats`).
    public var copyTitleFormats: [CopyRoute: CopyTitleFormat]
    /// The user's short names, by calendar id.
    public var calendarNames: [String: String]

    public init(
        selected: [CalendarRef], lookAheadDays: Int, unansweredAsBusy: Bool, excluded: Set<String>,
        hiddenTitleKeys: Set<String>, copyTitleFormats: [CopyRoute: CopyTitleFormat], calendarNames: [String: String]
    ) {
        self.selected = selected
        self.lookAheadDays = lookAheadDays
        self.unansweredAsBusy = unansweredAsBusy
        self.excluded = excluded
        self.hiddenTitleKeys = hiddenTitleKeys
        self.copyTitleFormats = copyTitleFormats
        self.calendarNames = calendarNames
    }

    /// The settings of a run with these inputs: only the routes between the ticked calendars
    /// (`keepingRoutes(between:from:)`), and `sourceLabels` as given, since a label also depends on the name
    /// Calendar shows.
    public func settings(sourceLabels: [CalendarRef: String]) -> SyncSettings {
        SyncSettings(
            selected: selected,
            lookAheadDays: lookAheadDays,
            unansweredAsBusy: unansweredAsBusy,
            excluded: excluded,
            copyTitleFormats: keepingRoutes(between: selected, from: copyTitleFormats),
            sourceLabels: sourceLabels,
            hiddenTitleKeys: hiddenTitleKeys
        )
    }

    /// How many changes these inputs make to `applied`, the same counted either way: one per calendar ticked or
    /// unticked (their order is not a change), one for the look-ahead, one for unanswered invitations, one per key
    /// added to or removed from `excluded` and `hiddenTitleKeys`, and one per route and per short name added,
    /// removed or changed. 0 when nothing differs but the order of the ticked calendars.
    public func changeCount(from applied: SyncInputs) -> Int {
        func keys<T: Hashable>(_ mine: Set<T>, _ theirs: Set<T>) -> Int { mine.symmetricDifference(theirs).count }
        func entries<K: Hashable, V: Equatable>(_ mine: [K: V], _ theirs: [K: V]) -> Int {
            Set(mine.keys).union(theirs.keys).count { mine[$0] != theirs[$0] }
        }
        return keys(Set(selected), Set(applied.selected))
            + (lookAheadDays == applied.lookAheadDays ? 0 : 1)
            + (unansweredAsBusy == applied.unansweredAsBusy ? 0 : 1)
            + keys(excluded, applied.excluded)
            + keys(hiddenTitleKeys, applied.hiddenTitleKeys)
            + entries(copyTitleFormats, applied.copyTitleFormats)
            + entries(calendarNames, applied.calendarNames)
    }
}
