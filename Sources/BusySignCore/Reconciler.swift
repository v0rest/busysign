import Foundation

/// What a copy should look like in a target calendar.
public struct CopySpec: Equatable, Sendable {
    /// The title of a copy that shows no meeting title.
    public static let busyTitle = "Busy"

    public var target: CalendarRef
    public var marker: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// The title to write, normalised (`normalizedCopyTitle`); never printed (`description` redacts it).
    public var title: String

    public init(target: CalendarRef, marker: String, start: Date, end: Date, isAllDay: Bool,
                title: String = CopySpec.busyTitle) {
        self.target = target
        self.marker = marker
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.title = title
    }

    /// The copy's slot as one opaque string, the target's id, `|` and the marker; it carries no title.
    public var slotKey: String { target.id + "|" + marker }
}

public enum SyncAction: Equatable, Sendable {
    case create(CopySpec)
    case update(localID: String, CopySpec)
    case delete(localID: String, target: CalendarRef)
    /// Store-level only, never planned by `reconcile`: check the copy `localID` as an update would (nothing is
    /// written if it is refused), create the copy `CopySpec` with the full copy shape, then delete the copy
    /// `localID` in the same target, only if the create succeeded. `SyncEngine` hands every planned update to the
    /// store this way (`replacingUpdates`).
    case replace(localID: String, CopySpec)
}

/// `actions` as the store executes them: each `.update` becomes a `.replace` of the same copy with the same
/// spec, in place; every other action and the order stay as they are. A server may reject an update of a copy
/// while the Mac keeps the local change, so the two diverge silently; a copy is therefore never updated.
public func replacingUpdates(_ actions: [SyncAction]) -> [SyncAction] {
    actions.map { action in
        guard case let .update(localID, spec) = action else { return action }
        return .replace(localID: localID, spec)
    }
}

/// One copy slot: a target calendar and the marker of the original it mirrors.
struct CopyKey: Hashable {
    let target: CalendarRef
    let marker: String
}

/// A copy the selection calls for, and the original it is taken from.
struct DesiredCopy {
    let spec: CopySpec
    let source: EventSnapshot
}

/// Same-marker winner rule: earliest (start, end, timed before all-day), then lowest calendar id. Both
/// keys are identical on every device.
func precedesAsSource(_ a: EventSnapshot, _ b: EventSnapshot) -> Bool {
    if a.start != b.start { return a.start < b.start }
    if a.end != b.end { return a.end < b.end }
    if a.isAllDay != b.isAllDay { return !a.isAllDay }
    return a.calendar.id < b.calendar.id
}

/// The copies the selection calls for, per target and marker, each with the original it mirrors: per
/// target, the winning busy original of the other selected calendars that copy into it (`SyncSettings.copies`:
/// not on a pair set to `nothing`) that overlaps the window and is not excluded by the user, unless the target
/// already holds a real busy event with identical start, end and all-day flag (an excluded one included). An
/// original whose pair into a target is `nothing` does not compete for that target, so the winner there is taken
/// from the other calendars. Each copy's title follows the format of the route from the winning original's
/// calendar to its target, that original's title and source label, and the hidden titles
/// (`SyncSettings.copyTitle`). Empty with fewer than two selected calendars. Shared by `reconcile` and the
/// descriptions of its plan.
func desiredCopies(events: [EventSnapshot], settings: SyncSettings, window: DateInterval) -> [CopyKey: DesiredCopy] {
    let selected = Set(settings.selected)
    guard selected.count >= 2 else { return [:] }

    let inScope = events.filter { selected.contains($0.calendar) }
    let unanswered = settings.unansweredAsBusy

    // Slots already occupied by real busy events, per calendar.
    struct Slot: Hashable { let calendar: CalendarRef; let start: Date; let end: Date; let allDay: Bool }
    var occupied = Set<Slot>()
    for e in inScope where countsAsBusy(e, unansweredAsBusy: unanswered) {
        occupied.insert(Slot(calendar: e.calendar, start: e.start, end: e.end, allDay: e.isAllDay))
    }

    var winners: [CopyKey: EventSnapshot] = [:]
    for original in inScope where countsAsBusy(original, unansweredAsBusy: unanswered)
        && original.start < window.end && original.end > window.start && !settings.excludes(original) {
        guard let marker = Marker.make(for: original) else { continue }
        for target in selected where settings.copies(from: original.calendar, to: target) {
            let key = CopyKey(target: target, marker: marker)
            if let current = winners[key], !precedesAsSource(original, current) { continue }
            winners[key] = original
        }
    }
    var desired: [CopyKey: DesiredCopy] = [:]
    for (key, o) in winners
    where !occupied.contains(Slot(calendar: key.target, start: o.start, end: o.end, allDay: o.isAllDay)) {
        desired[key] = DesiredCopy(
            spec: CopySpec(target: key.target, marker: key.marker, start: o.start, end: o.end, isAllDay: o.isAllDay,
                           title: settings.copyTitle(of: o, in: key.target)),
            source: o
        )
    }
    return desired
}

/// What a live run last wrote to one copy slot, for `heldRetitles`: the digest of the title (`Marker.digest(of:)`),
/// never the title itself, and the local ids of every copy the slot held when the write was planned (`copiesBySlot`
/// of the events the plan was made from; empty for a create). Recorded for `Busy` too, but a slot whose wanted title
/// is `Busy` is never held, whatever was recorded for it.
struct SentTitle: Equatable, Sendable {
    let digest: String
    let earlierCopies: Set<String>
}

/// The copies among `events` (events with a marker), by target calendar and marker.
func copiesBySlot(_ events: [EventSnapshot]) -> [CopyKey: [EventSnapshot]] {
    var slots: [CopyKey: [EventSnapshot]] = [:]
    for e in events {
        if let marker = e.marker { slots[CopyKey(target: e.calendar, marker: marker), default: []].append(e) }
    }
    return slots
}

/// The slots (`CopySpec.slotKey`) whose title-only difference is held this run (`reconcile(noRetitle:)`): those
/// whose wanted copy's title is not `CopySpec.busyTitle`, for which `sent` holds the digest of that title, none of
/// the copies recorded there (`SentTitle.earlierCopies`) is in the slot any more, and some copy reads another title
/// than the wanted one (`titleDiffers`, never for a title that was not read).
///
/// The hold is for a server that accepts a write and then changes the title. Once every copy that was in the slot
/// before that write is gone, what is left are copies this engine wrote (the successor of a replacement, a created
/// copy), so a title that differs is the server's doing, and writing it again would only repeat. While any earlier
/// copy is still there (a replacement that failed or was refused, a removal of the replaced copy or of a duplicate
/// that failed), nothing is held: keep-one picks the copy that stays without regard to the hold, so holding could
/// leave that earlier copy and its old title in place for good. The slot is settled by keep-one and an ordinary
/// retitle instead, like any other failed write. A wanted title that changed since (a rename, another format) has
/// another digest and is not held.
///
/// A slot that wants `Busy` is never held: hiding a title always wins over sparing a server a write. Something
/// other than this engine can leave a titled copy in such a slot after every copy this engine saw there is gone (a
/// second Mac with other settings, a copy the server restored under a new id, a delegate's edit), and a hold would
/// keep that title showing for as long as this engine lives. The cost: a server that rewrites `Busy` itself gets
/// one replacement per run.
func heldRetitles(events: [EventSnapshot], settings: SyncSettings, window: DateInterval,
                  sent: [String: SentTitle]) -> Set<String> {
    guard !sent.isEmpty else { return [] }
    let selected = Set(settings.selected)
    let desired = desiredCopies(events: events, settings: settings, window: window)
    var held = Set<String>()
    for (key, copies) in copiesBySlot(events.filter { selected.contains($0.calendar) }) {
        guard let wanted = desired[key]?.spec, wanted.title != CopySpec.busyTitle, let written = sent[wanted.slotKey],
              written.digest == Marker.digest(of: wanted.title),
              !copies.contains(where: { written.earlierCopies.contains($0.localID) }),
              copies.contains(where: { titleDiffers($0, from: wanted) }) else { continue }
        held.insert(wanted.slotKey)
    }
    return held
}

/// Plans the create/update/delete actions that make every selected calendar hold one copy per
/// busy original of the other selected calendars that copy into it, and nothing more. Stateless: copies are
/// recognised by their marker only.
///
/// - A pair set to `nothing` (`SyncSettings.copies`) wants no copy, so the copies of its source's originals in
///   its target are swept like any other unwanted copy, unless the same meeting is copied there from another
///   calendar.
/// - An original the user excluded (`SyncSettings.excluded`, by occurrence or series) is not
///   mirrored, so its copies are swept like any other unwanted copy. It still keeps copies of
///   others off its own slot.
/// - A copy is not planned for a target that already holds a real busy event with identical
///   start, end and all-day flag.
/// - Originals sharing a marker (the same event in several calendars) collapse to one copy per
///   target, taken from the original with the earliest (start, end, all-day), then lowest
///   calendar id, among those whose calendar copies into that target; both keys are identical on
///   every device.
/// - Unwanted copies are deleted when they overlap the window; duplicates of a wanted copy are
///   deleted regardless.
/// - Of several copies of one original in one target, the one that stays is, among those that are not an
///   occurrence of a recurring event and in the order by external id, then local id: the first that is
///   already right (the wanted start, end and all-day flag, and no other title, `titleDiffers`); else the
///   first. Only when every copy is a recurring occurrence does one of them stay: the first that is right,
///   else the first; the EventKit guard refuses to replace or delete one, so it is never kept while a
///   writable copy exists, and never moved when one is already right. So a copy that is already right is
///   never deleted while another one is moved or retitled into its place, and a copy whose removal failed is
///   only deleted again, with nothing created.
/// - The copy that stays is updated when its times differ from the original's, and when it reads a title
///   other than the wanted one (`titleDiffers`, never for a title that was not read), unless the wanted
///   copy's `slotKey` is in `noRetitle`: the caller's list of slots whose title-only difference is held this
///   run. A copy whose times differ is updated either way, and every update writes the wanted title.
///
/// Order: deletes, updates, creates; within each by target id, start, marker, localID.
public func reconcile(events: [EventSnapshot], settings: SyncSettings, window: DateInterval,
                      noRetitle: Set<String> = []) -> [SyncAction] {
    let selected = Set(settings.selected)
    guard selected.count >= 2 else { return [] }

    let inScope = events.filter { selected.contains($0.calendar) }
    let desired = desiredCopies(events: events, settings: settings, window: window).mapValues(\.spec)

    // Existing copies grouped by (target, marker).
    var groups: [CopyKey: [EventSnapshot]] = [:]
    for e in inScope {
        if let marker = e.marker { groups[CopyKey(target: e.calendar, marker: marker), default: []].append(e) }
    }

    struct Item { let target: String; let start: Date; let marker: String; let localID: String; let action: SyncAction }
    var deletes: [Item] = []
    var updates: [Item] = []
    var creates: [Item] = []

    func isBefore(_ a: EventSnapshot, _ b: EventSnapshot) -> Bool {
        switch (a.externalID, b.externalID) {
        case let (x?, y?) where x != y: return x < y
        case (.some, .none): return true
        case (.none, .some): return false
        default: return a.localID < b.localID
        }
    }

    for (key, copies) in groups {
        let ordered = copies.sorted(by: isBefore)
        func addDelete(_ e: EventSnapshot) {
            deletes.append(Item(target: key.target.id, start: e.start, marker: key.marker, localID: e.localID,
                                action: .delete(localID: e.localID, target: key.target)))
        }
        if let spec = desired[key] {
            func isRight(_ e: EventSnapshot) -> Bool {
                e.start == spec.start && e.end == spec.end && e.isAllDay == spec.isAllDay
                    && !titleDiffers(e, from: spec)
            }
            // By position, not local id: the occurrences of a recurring event share one.
            let keepIndex = ordered.firstIndex { isRight($0) && !$0.isRecurringOccurrence }
                ?? ordered.firstIndex { !$0.isRecurringOccurrence }
                ?? ordered.firstIndex(where: isRight)
                ?? 0
            let keep = ordered[keepIndex]
            let moves = keep.start != spec.start || keep.end != spec.end || keep.isAllDay != spec.isAllDay
            let retitles = titleDiffers(keep, from: spec) && !noRetitle.contains(spec.slotKey)
            if moves || retitles {
                updates.append(Item(target: key.target.id, start: spec.start, marker: key.marker, localID: keep.localID,
                                    action: .update(localID: keep.localID, spec)))
            }
            for (index, e) in ordered.enumerated() where index != keepIndex { addDelete(e) }
        } else {
            for e in ordered where e.start < window.end && e.end > window.start { addDelete(e) }
        }
    }
    for (key, spec) in desired where groups[key] == nil {
        creates.append(Item(target: key.target.id, start: spec.start, marker: key.marker, localID: "",
                            action: .create(spec)))
    }

    func sorted(_ items: [Item]) -> [SyncAction] {
        items.sorted {
            ($0.target, $0.start, $0.marker, $0.localID) < ($1.target, $1.start, $1.marker, $1.localID)
        }.map(\.action)
    }
    return sorted(deletes) + sorted(updates) + sorted(creates)
}
