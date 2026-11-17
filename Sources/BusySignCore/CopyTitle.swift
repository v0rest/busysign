import Foundation

/// The choice per pair of calendars, a route from a source calendar into a target calendar: whether the route
/// copies anything, and what its copies show. Declared in the order Settings offers them.
public enum CopyTitleFormat: String, Sendable, Codable, CaseIterable {
    /// No copies at all: the source's meetings get no Busy block in the target.
    case nothing
    /// `Busy`, the default.
    case busyOnly
    /// The meeting's title.
    case title
    /// The source calendar's label, `: ` and the meeting's title; the title alone when the source has no label.
    case sourceAndTitle

    /// Whether the copies on a pair with this choice may show the meeting's title: `title` and `sourceAndTitle`.
    /// Neither `busyOnly` nor `nothing` is a title choice.
    public var showsTitle: Bool {
        switch self {
        case .title, .sourceAndTitle: true
        case .nothing, .busyOnly: false
        }
    }
}

extension [CopyRoute: CopyTitleFormat] {
    /// The choice on the pair from `source` to `target`: `busyOnly` when it is missing.
    public func format(from source: CalendarRef, to target: CalendarRef) -> CopyTitleFormat {
        self[CopyRoute(source: source, target: target)] ?? .busyOnly
    }

    /// Whether `source`'s meetings are copied into `target` at all: never into their own calendar, nor on a pair
    /// set to `nothing`.
    public func copies(from source: CalendarRef, to target: CalendarRef) -> Bool {
        source != target && format(from: source, to: target) != .nothing
    }
}

extension SyncSettings {
    /// Whether `source`'s meetings are copied into `target` at all (`copyTitleFormats`): every pair except those set
    /// to `nothing`, and never a calendar into itself. Whether both are selected is up to the caller.
    public func copies(from source: CalendarRef, to target: CalendarRef) -> Bool {
        copyTitleFormats.copies(from: source, to: target)
    }
}

/// The calendars of `selected` that get Busy blocks, each once in selection order: those another calendar of
/// `selected` copies into under `formats` (`copies(from:to:)`). When none does, with every pair set to `nothing` or
/// fewer than two calendars, all of `selected`, each once, as the switch to Live named them before pairs could be
/// set to Nothing.
public func calendarsGettingBlocks(_ selected: [CalendarRef],
                                   formats: [CopyRoute: CopyTitleFormat]) -> [CalendarRef] {
    var seen = Set<CalendarRef>()
    let order = selected.filter { seen.insert($0).inserted }
    let targets = order.filter { target in order.contains { formats.copies(from: $0, to: target) } }
    return targets.isEmpty ? order : targets
}

/// A pair of calendars the copies go between: the originals in `source` and their copies in `target`.
public struct CopyRoute: Hashable, Sendable {
    public let source: CalendarRef
    public let target: CalendarRef

    public init(source: CalendarRef, target: CalendarRef) {
        self.source = source
        self.target = target
    }
}

/// The routes that keep the per-target choices `formats`: for every target in `selected` whose format shows titles
/// (`showsTitle`), that format on the route into it from every other calendar in `selected`. Formats of targets not
/// in `selected`, `busyOnly` and `nothing` give no route: the choices of before were title choices only. A calendar
/// listed twice in `selected` counts once.
public func copyTitleRoutes(fromTargetFormats formats: [CalendarRef: CopyTitleFormat],
                            selected: [CalendarRef]) -> [CopyRoute: CopyTitleFormat] {
    var routes: [CopyRoute: CopyTitleFormat] = [:]
    for target in selected {
        guard let format = formats[target], format.showsTitle else { continue }
        for source in selected where source != target {
            routes[CopyRoute(source: source, target: target)] = format
        }
    }
    return routes
}

/// `formats` without every route that `calendar` is part of, as source or as target.
public func droppingRoutes(involving calendar: CalendarRef,
                           from formats: [CopyRoute: CopyTitleFormat]) -> [CopyRoute: CopyTitleFormat] {
    formats.filter { $0.key.source != calendar && $0.key.target != calendar }
}

/// `formats` with only the routes between calendars in `selected`: a route whose source or target is not selected
/// is dropped, so a calendar ticked again starts at `busyOnly` on every pair.
public func keepingRoutes(between selected: [CalendarRef],
                          from formats: [CopyRoute: CopyTitleFormat]) -> [CopyRoute: CopyTitleFormat] {
    let selected = Set(selected)
    return formats.filter { selected.contains($0.key.source) && selected.contains($0.key.target) }
}

/// The longest title a copy gets, in UTF-16 code units: Exchange's subject limit, counted the way Exchange counts.
let copyTitleLimit = 255

/// `raw` as a copy's title is written and compared: whitespace and newlines trimmed, cut to at most
/// `copyTitleLimit` UTF-16 code units without splitting a character (whole characters are kept while their running
/// UTF-16 count stays within the limit), trimmed again. Normalising a normalised title changes nothing.
public func normalizedCopyTitle(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf16.count > copyTitleLimit else { return trimmed }
    var units = 0
    let kept = trimmed.prefix { character in
        units += character.utf16.count
        return units <= copyTitleLimit
    }
    return String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
}

extension SyncSettings {
    /// The title of the copy of `original` in `target`: `Busy` when the route from the original's calendar to
    /// `target` is no title choice (`showsTitle`: `busyOnly`, also when it has no format, and `nothing`, which
    /// `desiredCopies` never asks a title for), when the original's title normalised on its own
    /// (`normalizedCopyTitle`) is empty (missing, blank, or one character longer than the limit), or when the
    /// user hid it (`hidesTitle`); else that title, after the source's label and `: ` for `sourceAndTitle` when
    /// the source has a non-blank label, with the composed title normalised as a whole. When the label leaves no
    /// room for any of the title, the title alone: a copy is never titled `<label>:`. A route only ever titles the
    /// copies of its own source's originals.
    func copyTitle(of original: EventSnapshot, in target: CalendarRef) -> String {
        let format = copyTitleFormats.format(from: original.calendar, to: target)
        let title = normalizedCopyTitle(original.title ?? "")
        guard format.showsTitle, !title.isEmpty, !hidesTitle(original) else { return CopySpec.busyTitle }
        let label = sourceLabels[original.calendar]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard format == .sourceAndTitle, !label.isEmpty else { return title }
        let prefix = label + ": "
        let composed = normalizedCopyTitle(prefix + title)
        // The title starts with a character that is not whitespace, so any of it kept outlasts the prefix.
        return composed.utf16.count > prefix.utf16.count ? composed : title
    }
}

/// Whether the copy `copy` reads a title other than the one `spec` writes, normalised the same way. Never for a
/// copy whose title was not read (nil): its title is unknown.
func titleDiffers(_ copy: EventSnapshot, from spec: CopySpec) -> Bool {
    guard let title = copy.title else { return false }
    return normalizedCopyTitle(title) != spec.title
}

// MARK: - Descriptions without titles

extension EventSnapshot: CustomStringConvertible {
    /// Every field as the default description prints it, except the title: `title: <redacted>`, or `title: nil`
    /// when it was not read.
    public var description: String { describingRedactedTitle(self, titleIsNil: title == nil) }
}

extension CopySpec: CustomStringConvertible {
    /// Every field as the default description prints it, except the title: `title: <redacted>`.
    public var description: String { describingRedactedTitle(self, titleIsNil: false) }
}

/// `value` printed like the default description, `Type(field: value, ...)` with every field in its debug form,
/// except the field `title`, printed as `<redacted>` (`nil` when `titleIsNil`). Titles stay out of logs and test
/// output however a snapshot or spec is interpolated, an action or array holding one included.
private func describingRedactedTitle(_ value: Any, titleIsNil: Bool) -> String {
    let mirror = Mirror(reflecting: value)
    let fields = mirror.children.map { child -> String in
        let label = child.label ?? "_"
        guard label != "title" else { return "title: " + (titleIsNil ? "nil" : "<redacted>") }
        return label + ": " + String(reflecting: child.value)
    }
    return "\(mirror.subjectType)(\(fields.joined(separator: ", ")))"
}
