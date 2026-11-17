import Foundation

private func isVisibleKind(_ info: CalendarInfo) -> Bool {
    info.isWritable && info.kind != .birthday && info.kind != .subscription
}

/// The main calendar of each account. Among an account's writable, non-delegate, non-subscription,
/// non-birthday calendars: the default calendar when it is in that account; else the Exchange calendar
/// titled "Calendar"; else the calendar titled like the account; else the one whose title contains "@",
/// when exactly one does (several may be the user's own and shared ones); else the only such calendar,
/// unless it is an On My Mac one; else none. Calendars without an account id are never picked.
public func mainCalendarIDs(_ infos: [CalendarInfo], defaultCalendarID: String?) -> Set<String> {
    let eligible = infos
        .filter { isVisibleKind($0) && !$0.isDelegateAccount && !$0.accountID.isEmpty }
        .sorted { $0.ref.id < $1.ref.id }
    var result = Set<String>()
    for (_, group) in Dictionary(grouping: eligible, by: \.accountID) {
        let withAt = group.filter { $0.title.contains("@") }
        let pick: CalendarInfo?
        if let defaultCalendarID, let found = group.first(where: { $0.ref.id == defaultCalendarID }) {
            pick = found
        } else if let found = group.first(where: { $0.kind == .exchange && $0.title == "Calendar" }) {
            pick = found
        } else if let found = group.first(where: { $0.title == $0.accountTitle }) {
            pick = found
        } else if withAt.count == 1 {
            pick = withAt[0]
        } else if group.count == 1 && group[0].kind != .local {
            pick = group[0]
        } else {
            pick = nil
        }
        if let pick { result.insert(pick.ref.id) }
    }
    return result
}

/// What Settings lists: main calendars, other writable ones for a disclosure, and selected ids that no
/// longer exist.
public struct CalendarList: Sendable, Equatable {
    public var main: [CalendarInfo]
    public var other: [CalendarInfo]
    public var missingSelectedIDs: [String]

    public init(main: [CalendarInfo], other: [CalendarInfo], missingSelectedIDs: [String]) {
        self.main = main
        self.other = other
        self.missingSelectedIDs = missingSelectedIDs
    }
}

/// Read-only, birthday and subscription calendars are hidden unless selected. `main` holds the suggested
/// primaries plus every selected calendar, ordered by account title.
public func calendarList(_ infos: [CalendarInfo], selectedIDs: [String]) -> CalendarList {
    let selected = Set(selectedIDs)
    let known = Set(infos.map(\.ref.id))
    func order(_ a: CalendarInfo, _ b: CalendarInfo) -> Bool {
        (a.accountTitle, a.title, a.ref.id) < (b.accountTitle, b.title, b.ref.id)
    }
    let main = infos.filter { $0.isSuggestedPrimary || selected.contains($0.ref.id) }.sorted(by: order)
    let mainIDs = Set(main.map(\.ref.id))
    let other = infos.filter { isVisibleKind($0) && !mainIDs.contains($0.ref.id) }.sorted(by: order)
    var seen = Set<String>()
    let missing = selectedIDs.filter { !known.contains($0) && seen.insert($0).inserted }
    return CalendarList(main: main, other: other, missingSelectedIDs: missing)
}

/// Default short name: an e-mail account title gives the capitalised first label of its domain; else an
/// e-mail calendar title does; else the account title.
public func defaultShortName(accountTitle: String, calendarTitle: String) -> String {
    func fromEmail(_ text: String) -> String? {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty,
              let label = parts[1].split(separator: ".", omittingEmptySubsequences: false).first,
              !label.isEmpty, parts[1].contains(".") else { return nil }
        return label.prefix(1).uppercased() + label.dropFirst().lowercased()
    }
    return fromEmail(accountTitle) ?? fromEmail(calendarTitle) ?? accountTitle
}

/// A calendar for `displayNames`.
public struct DisplayNameItem: Sendable, Equatable {
    public var id: String
    /// The calendar's own short name.
    public var name: String
    public var accountName: String
    public var title: String
    /// Whether Calendar lists it; false for a selected calendar that is no longer there.
    public var isListed: Bool
    public var isMain: Bool
    /// Whether `name` is one the user stored.
    public var isRenamed: Bool
    /// Its place in the order the calendars were first seen; nil when unknown.
    public var firstSeen: Int?
    /// The name it would have without the user's name for it; `name` when nil.
    public var defaultName: String?

    public init(id: String, name: String, accountName: String = "", title: String = "", isListed: Bool = true,
                isMain: Bool = false, isRenamed: Bool = false, firstSeen: Int? = nil, defaultName: String? = nil) {
        self.id = id
        self.name = name
        self.accountName = accountName
        self.title = title
        self.isListed = isListed
        self.isMain = isMain
        self.isRenamed = isRenamed
        self.firstSeen = firstSeen
        self.defaultName = defaultName
    }
}

/// Names that tell the listed calendars apart, by calendar id, for every place the app names a calendar.
/// Names clash when they read the same (`namesMatch`).
///
/// Of calendars whose own names (`name`) clash, the one that ranks first keeps its name: one Calendar lists
/// over a missing one, then a main calendar over another, then one the user named over a default name. When
/// two or more rank first alike, none keeps it for that reason. The others are told apart step by step:
/// " · " and the account's name, then " · " and the calendar's title, then a number. A step never appends an
/// empty part or one that repeats the name, and it leaves out a part that two or more calendars of a clash,
/// all ranking first or all ranking below, would all get alike, since that leaves them clashing.
///
/// A calendar that still clashes after that gets " #n", where n is its slot for its own name: its 1-based
/// place, in the order first seen (`firstSeen`, those without one after, then by id), among every calendar
/// whose default name (`defaultName`) reads like that name, followed by those the user named so. The one that
/// keeps the plain name shows no number, and calendars told apart by a part hold their slot too, so numbers
/// may have gaps. A calendar renamed away keeps its slot under its default name, so renaming one calendar
/// changes no other calendar's number while its name still clashes. Only when the number is in use as a name
/// already does it move on to the next free one. A calendar that ranks below another with its name and has
/// nothing else to tell it apart is numbered the same way. Names that clash with nothing come back as they
/// are. The result does not depend on the order of `items`; of an id listed twice, the first entry counts.
public func displayNames(_ items: [DisplayNameItem]) -> [String: String] {
    typealias Item = DisplayNameItem
    var seenIDs = Set<String>()
    let items = items.filter { seenIDs.insert($0.id).inserted }.sorted { a, b in
        (a.firstSeen ?? Int.max, a.id) < (b.firstSeen ?? Int.max, b.id)
    }
    let position = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
    func rank(_ item: Item) -> Int { (item.isListed ? 4 : 0) + (item.isMain ? 2 : 0) + (item.isRenamed ? 1 : 0) }
    var names: [String: String] = [:]
    for item in items { names[item.id] = item.name }
    func current(_ item: Item) -> String { names[item.id] ?? item.name }
    /// Groups of two or more items whose names clash, each in order, the groups by their first item.
    func clashes() -> [[Item]] {
        Dictionary(grouping: items) { nameKey(current($0)) }.values
            .filter { $0.count > 1 }
            .sorted { position[$0[0].id, default: 0] < position[$1[0].id, default: 0] }
    }
    /// The items of a clash that rank first, and the others.
    func split(_ clash: [Item]) -> (first: [Item], below: [Item]) {
        let best = clash.map(rank).max() ?? 0
        return (clash.filter { rank($0) == best }, clash.filter { rank($0) < best })
    }

    // Those ranking below another calendar with their own name must not end up keeping it.
    var mustChange = Set<String>()
    for clash in clashes() { mustChange.formUnion(split(clash).below.map(\.id)) }

    let parts: [(Item) -> String] = [{ $0.accountName }, { $0.title }]
    for part in parts {
        for clash in clashes() {
            let (first, below) = split(clash)
            // A calendar that alone ranks first keeps its name.
            for group in first.count > 1 ? [first, below] : [below] {
                let added = group.map { part($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                if group.count > 1 && Set(added.map(nameKey)).count == 1 { continue }
                for (item, text) in zip(group, added) where !text.isEmpty
                    && nameKey(text) != nameKey(item.name) && nameKey(text) != nameKey(current(item)) {
                    names[item.id] = current(item) + " · " + text
                }
            }
        }
    }

    let remaining = clashes().map { clash in
        let first = split(clash).first
        let keeper = first.count == 1 ? first[0] : nil
        // In the order first seen alone, so a rename that changes who ranks first moves no other number.
        let numbered = clash.filter { $0.id != keeper?.id }
        return (keeper: keeper, numbered: numbered)
    }
    let renumbered = Set(remaining.flatMap { $0.numbered.map(\.id) })
    var used = Set(items.filter { !renumbered.contains($0.id) }.map { nameKey(current($0)) })
    /// The item's slot for its own name: its 1-based place among the calendars whose default name reads like
    /// it, in the order first seen, then those the user named so, also in that order.
    func slot(_ item: Item) -> Int {
        let key = nameKey(item.name)
        let byDefault = items.filter { nameKey($0.defaultName ?? $0.name) == key }
        let byRename = items.filter { nameKey($0.defaultName ?? $0.name) != key && nameKey($0.name) == key }
        return ((byDefault + byRename).firstIndex { $0.id == item.id } ?? 0) + 1
    }
    func number(_ item: Item) {
        let base = current(item)
        var n = slot(item)
        while used.contains(nameKey("\(base) #\(n)")) { n += 1 }
        names[item.id] = "\(base) #\(n)"
        used.insert(nameKey("\(base) #\(n)"))
    }
    for clash in remaining {
        for item in clash.numbered { number(item) }
    }
    for item in items where mustChange.contains(item.id) && current(item) == item.name {
        used.remove(nameKey(item.name))
        number(item)
    }
    return names
}

/// What saving a calendar's rename field does.
public enum RenameEffect: Sendable, Equatable {
    case keep
    /// Back to the default name.
    case clear
    case store(String)
}

/// What saving `typed` in the rename field of a calendar does: its own name (`ownName`), its shown name
/// (`shownName`, with what tells clashing names apart), and the name the user stored for it, if any. Blank goes
/// back to the default name. A name that reads like the own or the shown name (`namesMatch`) stores nothing, so
/// a default name typed back, in any case, never turns into one the user named and never changes which
/// calendar keeps a clashing name or anyone's number. The one exception is a new casing of the stored name
/// itself ("initech" → "Initech"): that is stored, since the calendar ranks as named already.
public func renameEffect(typed: String, ownName: String, shownName: String, storedName: String?) -> RenameEffect {
    let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    let stored = storedName.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    guard !name.isEmpty else { return stored == nil ? .keep : .clear }
    if let stored, namesMatch(name, stored) { return name == stored ? .keep : .store(name) }
    if namesMatch(name, ownName) || namesMatch(name, shownName) { return .keep }
    return .store(name)
}

/// The staged short names (`SyncInputs.calendarNames`, by calendar id) with a rename staged only for the calendars
/// in `rows`, the ones Settings gives a rename row: every other calendar has its `applied` entry, present or absent,
/// whatever was staged for it, since a staged rename shows on its own row only and must never wait for Apply where
/// no row shows it.
public func namesKeepingRenames(of rows: Set<String>, staged: [String: String],
                                applied: [String: String]) -> [String: String] {
    var names = staged.filter { rows.contains($0.key) }
    for (id, name) in applied where !rows.contains(id) { names[id] = name }
    return names
}

/// Whether two calendar names read the same: equal apart from case and surrounding spaces.
public func namesMatch(_ a: String, _ b: String) -> Bool {
    nameKey(a) == nameKey(b)
}

private func nameKey(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}
