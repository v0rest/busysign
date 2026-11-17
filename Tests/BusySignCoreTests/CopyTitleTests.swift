import Foundation
import Testing
@testable import BusySignCore

/// The title a copy gets per route (source and target calendar), and when a kept copy is rewritten for its title.
@Suite struct CopyTitleTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var window: DateInterval { DateInterval(start: t0 - 86_400, duration: 30 * 86_400) }
    let a = CalendarRef(id: "A")
    let b = CalendarRef(id: "B")
    let c = CalendarRef(id: "C")
    let d = CalendarRef(id: "D")
    let meeting = "Weekly sync"

    /// The route from `source` to `target`.
    func route(_ source: CalendarRef, _ target: CalendarRef) -> CopyRoute {
        CopyRoute(source: source, target: target)
    }

    /// The route of the originals in A into B, which most tests title.
    var aToB: CopyRoute { route(a, b) }

    func settings(_ selected: [CalendarRef]? = nil, formats: [CopyRoute: CopyTitleFormat] = [:],
                  labels: [CalendarRef: String] = [:], hidden: Set<String> = []) -> SyncSettings {
        SyncSettings(selected: selected ?? [a, b], copyTitleFormats: formats, sourceLabels: labels,
                     hiddenTitleKeys: hidden)
    }

    /// An original in `cal`, titled `title`, one hour from `start` (default `t0`).
    func original(_ cal: String = "A", _ ext: String = "ext", title: String? = "Weekly sync",
                  start: Date? = nil, recurring: Bool = false) -> EventSnapshot {
        let at = start ?? t0
        var e = snap(calendar: cal, localID: "\(cal)-\(ext)-\(Int(at.timeIntervalSince1970))", externalID: ext,
                     occurrenceDate: at, isRecurringOccurrence: recurring, start: at, end: at + 3600)
        e.title = title
        return e
    }

    /// A copy of `o` in `cal` that reads `title`, at `o`'s times unless `start` moves it.
    func copy(_ cal: String = "B", of o: EventSnapshot, local: String, ext: String, title: String?,
              start: Date? = nil) -> EventSnapshot {
        let at = start ?? o.start
        var e = snap(calendar: cal, localID: local, externalID: ext, start: at, end: at + o.end.timeIntervalSince(o.start),
                     isAllDay: o.isAllDay, myResponse: .none, marker: Marker.make(for: o))
        e.title = title
        return e
    }

    /// The wanted copy of `o` in `target`, titled `title`.
    func wanted(_ target: CalendarRef, of o: EventSnapshot, title: String = CopySpec.busyTitle) -> CopySpec {
        CopySpec(target: target, marker: Marker.make(for: o)!, start: o.start, end: o.end, isAllDay: o.isAllDay,
                 title: title)
    }

    /// The title of the copy `reconcile` creates for `o` in `target`, from `events` (default: `o` alone).
    func createdTitle(of o: EventSnapshot, in target: CalendarRef, _ s: SyncSettings,
                      events: [EventSnapshot]? = nil) -> String? {
        let marker = Marker.make(for: o)
        for action in reconcile(events: events ?? [o], settings: s, window: window) {
            if case let .create(spec) = action, spec.target == target, spec.marker == marker { return spec.title }
        }
        return nil
    }

    // MARK: - Normalisation

    @Test func normalizedTitleCases() {
        #expect(normalizedCopyTitle("  Weekly sync \n") == "Weekly sync")
        #expect(normalizedCopyTitle(String(repeating: "a", count: 300)) == String(repeating: "a", count: 255))
        #expect(normalizedCopyTitle(String(repeating: "a", count: 254) + " bbb") == String(repeating: "a", count: 254))
        #expect(normalizedCopyTitle("") == "")
        // The limit counts UTF-16 units, as Exchange does, and never splits a character.
        #expect(normalizedCopyTitle(String(repeating: "👍", count: 200)) == String(repeating: "👍", count: 127))
        // A flag is one character of two scalars, 4 UTF-16 units. After 128 + 31 × 4 = 252 units the next flag
        // would end at unit 256 although its first scalar ends at 254: it goes whole, never half.
        #expect(normalizedCopyTitle(String(repeating: "a", count: 128) + String(repeating: "🇪🇺", count: 65))
            == String(repeating: "a", count: 128) + String(repeating: "🇪🇺", count: 31))
    }

    // MARK: - The title each wanted copy gets

    @Test func busyOnlyIsDefault() {
        #expect(createdTitle(of: original(), in: b, settings()) == "Busy")
        #expect(CopySpec.busyTitle == "Busy")
    }

    @Test func titleFormat() {
        #expect(createdTitle(of: original(), in: b, settings(formats: [aToB: .title])) == meeting)
    }

    @Test func sourceAndTitleFormat() {
        let labelled = settings(formats: [aToB: .sourceAndTitle], labels: [a: "Acme"])
        #expect(createdTitle(of: original(), in: b, labelled) == "Acme: Weekly sync")
        let unlabelled = settings(formats: [aToB: .sourceAndTitle])
        #expect(createdTitle(of: original(), in: b, unlabelled) == meeting)
    }

    @Test func blankOriginalTitleIsBusy() {
        for title in ["   ", nil] as [String?] {
            let o = original(title: title)
            #expect(createdTitle(of: o, in: b, settings(formats: [aToB: .title])) == "Busy")
            let labelled = settings(formats: [aToB: .sourceAndTitle], labels: [a: "Acme"])
            #expect(createdTitle(of: o, in: b, labelled) == "Busy")
        }
    }

    /// A title that is one character longer than the limit normalises to nothing: `Busy`, with or without a label.
    @Test func oversizedSingleCharacterTitleIsBusy() {
        let one = "e" + String(repeating: "\u{301}", count: 300)
        #expect(one.count == 1 && one.utf16.count == 301)
        let o = original(title: one)
        #expect(createdTitle(of: o, in: b, settings(formats: [aToB: .title])) == "Busy")
        let labelled = settings(formats: [aToB: .sourceAndTitle], labels: [a: "Acme"])
        #expect(createdTitle(of: o, in: b, labelled) == "Busy")
    }

    /// A label so long that no part of the title fits after it gives the title alone, never `<label>:`.
    @Test func labelWithoutRoomGivesTheTitleAlone() {
        let long = String(repeating: "L", count: 300)
        let s = settings(formats: [aToB: .sourceAndTitle], labels: [a: long])
        #expect(createdTitle(of: original(), in: b, s) == meeting)
    }

    /// A's meeting is titled only in the target whose route from A shows titles: A→B titles B's copy, and C's copy
    /// reads `Busy` since A→C has no format; a route from another source into B (C→B) changes nothing for it.
    @Test func formatFollowsRouteIntoTarget() {
        let o = original()
        let s = settings([a, b, c], formats: [aToB: .title, route(c, b): .title])
        #expect(createdTitle(of: o, in: b, s) == meeting)
        #expect(createdTitle(of: o, in: c, s) == "Busy")
    }

    /// Only A→C shows titles: C's copy of A's meeting is titled, C's copy of B's meeting and B's copy of A's
    /// meeting read `Busy`.
    @Test func formatIsPerRoute() {
        let fromA = original("A", "one")
        let fromB = original("B", "two", start: t0 + 7200)
        let events = [fromA, fromB]
        let s = settings([a, b, c], formats: [route(a, c): .title])
        #expect(createdTitle(of: fromA, in: c, s, events: events) == meeting)
        #expect(createdTitle(of: fromB, in: c, s, events: events) == "Busy")
        #expect(createdTitle(of: fromA, in: b, s, events: events) == "Busy")
    }

    /// One meeting in A and in B, A→C titled and B→C unset: C's one copy follows the route of the original it is
    /// taken from, the winner by `precedesAsSource`.
    @Test func winnerRouteDecides() throws {
        let s = settings([a, b, c], formats: [route(a, c): .title])
        let inA = original("A", "shared")
        let marker = try #require(Marker.make(for: inA))
        func copyInC(_ events: [EventSnapshot]) -> DesiredCopy? {
            desiredCopies(events: events, settings: s, window: window)[CopyKey(target: c, marker: marker)]
        }

        // Same times: the lower calendar id, A, wins.
        let sameTimeInB = original("B", "shared")
        #expect(Marker.make(for: sameTimeInB) == marker)
        #expect(precedesAsSource(inA, sameTimeInB))
        let fromA = try #require(copyInC([sameTimeInB, inA]))
        #expect(fromA.source.calendar == a)
        #expect(fromA.spec.title == meeting)

        // B's starts earlier, so B's wins.
        let earlierInB = original("B", "shared", start: t0 - 3600)
        #expect(Marker.make(for: earlierInB) == marker)
        #expect(precedesAsSource(earlierInB, inA))
        let fromB = try #require(copyInC([inA, earlierInB]))
        #expect(fromB.source.calendar == b)
        #expect(fromB.spec.start == earlierInB.start)
        #expect(fromB.spec.title == "Busy")
    }

    /// The old choice per target becomes the same choice on every route into it from the other selected
    /// calendars; `busyOnly` and targets that are not selected give no route. The copies the old choices titled
    /// keep their titles: the first run after the upgrade plans nothing.
    @Test func migrationKeepsWantedTitles() {
        let old: [CalendarRef: CopyTitleFormat] = [c: .sourceAndTitle, b: .title, a: .busyOnly]
        let routes = copyTitleRoutes(fromTargetFormats: old, selected: [a, b, c])
        #expect(routes == [route(a, c): .sourceAndTitle, route(b, c): .sourceAndTitle,
                           route(a, b): .title, route(c, b): .title])
        for source in [a, b, c] {
            for target in [a, b, c] where target != source {
                #expect((routes[route(source, target)] ?? .busyOnly) == (old[target] ?? .busyOnly))
            }
        }

        // A target not in the selection contributes nothing, nor does a source that is not selected.
        #expect(copyTitleRoutes(fromTargetFormats: [d: .title], selected: [a, b, c]) == [:])
        #expect(copyTitleRoutes(fromTargetFormats: [c: .title, d: .title], selected: [a, c]) == [route(a, c): .title])
        // A calendar listed twice gives each route once.
        #expect(copyTitleRoutes(fromTargetFormats: [b: .title], selected: [a, b, a]) == [aToB: .title])

        let labels = [a: "Acme", b: "Initech"]
        let fromA = original("A", "one")
        let fromB = original("B", "two", title: "Planning", start: t0 + 7200)
        let events = [
            fromA, fromB,
            copy("B", of: fromA, local: "b1", ext: "x1", title: meeting),
            copy("C", of: fromA, local: "c1", ext: "x2", title: "Acme: Weekly sync"),
            copy("A", of: fromB, local: "a1", ext: "x3", title: "Busy"),
            copy("C", of: fromB, local: "c2", ext: "x4", title: "Initech: Planning"),
        ]
        let upgraded = settings([a, b, c], formats: routes, labels: labels)
        #expect(reconcile(events: events, settings: upgraded, window: window) == [])
    }

    /// `Nothing` is no title choice: the choices of before move only titles, and a pair on Nothing never titles a
    /// copy, also when asked for one.
    @Test func nothingIsNoTitleChoice() {
        #expect(CopyTitleFormat.allCases == [.nothing, .busyOnly, .title, .sourceAndTitle])
        #expect(CopyTitleFormat.allCases.filter(\.showsTitle) == [.title, .sourceAndTitle])
        #expect(copyTitleRoutes(fromTargetFormats: [c: .nothing, b: .title], selected: [a, b, c])
            == [route(a, b): .title, route(c, b): .title])
        let s = settings(formats: [aToB: .nothing])
        #expect(s.copyTitle(of: original(), in: b) == CopySpec.busyTitle)
        #expect(!s.copies(from: a, to: b) && s.copies(from: b, to: a) && !s.copies(from: a, to: a))
    }

    /// The same meeting at the same time in A and B; C holds one copy, from A, the usual winner. With A→C on Nothing,
    /// C's copy is taken from B: the copy stays, unchanged while it reads what B→C shows, retitled in place when A→C
    /// showed the title and B→C shows `Busy`; never removed and added again.
    @Test func sharedMeetingSwitchesSourceInPlace() {
        let inA = original("A", "m"), inB = original("B", "m")
        let oneWay = settings([a, b, c], formats: [route(a, c): .nothing])
        let busyCopy = copy("C", of: inA, local: "c1", ext: "x1", title: CopySpec.busyTitle)
        #expect(reconcile(events: [inA, inB, busyCopy], settings: settings([a, b, c]), window: window).isEmpty)
        #expect(reconcile(events: [inA, inB, busyCopy], settings: oneWay, window: window).isEmpty)

        let titledCopy = copy("C", of: inA, local: "c1", ext: "x1", title: meeting)
        let titled = settings([a, b, c], formats: [route(a, c): .title])
        #expect(reconcile(events: [inA, inB, titledCopy], settings: titled, window: window).isEmpty)
        #expect(reconcile(events: [inA, inB, titledCopy], settings: oneWay, window: window)
            == [.update(localID: "c1", wanted(c, of: inB))])
        #expect(mirroredItems(events: [inA, inB, titledCopy], settings: oneWay, window: window)
            .filter { $0.target == c }.map(\.sourceLocalID) == [inB.localID])
    }

    /// The calendars the switch to Live names as getting Busy blocks: those another selected calendar copies into, in
    /// selection order; all of them when none is (every pair Nothing, or fewer than two calendars).
    @Test func calendarsGettingBlocksFollowThePairs() {
        let oneWay: [CopyRoute: CopyTitleFormat] = [route(c, a): .nothing, route(c, b): .nothing,
                                                    route(a, c): .nothing, route(b, c): .title]
        #expect(calendarsGettingBlocks([c, a, b], formats: [:]) == [c, a, b])
        #expect(calendarsGettingBlocks([c, a, b], formats: oneWay) == [c, a, b])
        #expect(calendarsGettingBlocks([c, a, b], formats: oneWay.merging([route(b, c): .nothing]) { $1 }) == [a, b])
        #expect(calendarsGettingBlocks([a, b, a], formats: [route(b, a): .nothing]) == [b])

        var silent: [CopyRoute: CopyTitleFormat] = [:]
        for source in [a, b, c] {
            for target in [a, b, c] where target != source { silent[route(source, target)] = .nothing }
        }
        #expect(calendarsGettingBlocks([a, b, c], formats: silent) == [a, b, c])
        #expect(calendarsGettingBlocks([b, a, b], formats: silent) == [b, a])
        #expect(calendarsGettingBlocks([a], formats: [:]) == [a])
        #expect(calendarsGettingBlocks([], formats: [:]) == [])
    }

    /// Unticking a calendar forgets every route it is part of, as source and as target.
    @Test func droppingRoutesForgetsBothDirections() {
        let routes: [CopyRoute: CopyTitleFormat] = [route(a, c): .title, route(c, b): .sourceAndTitle,
                                                    route(b, a): .title]
        #expect(droppingRoutes(involving: c, from: routes) == [route(b, a): .title])
        #expect(droppingRoutes(involving: d, from: routes) == routes)
        #expect(droppingRoutes(involving: a, from: [:]) == [:])
    }

    /// Only the routes between selected calendars are kept: one whose source or target is not selected, left
    /// stored by an earlier build or an untick cut short, is dropped, so a calendar ticked again starts at
    /// `busyOnly` on every pair.
    @Test func keepingRoutesBetweenSelectedDropsTheOthers() {
        let routes: [CopyRoute: CopyTitleFormat] = [route(a, b): .title, route(b, a): .sourceAndTitle,
                                                    route(a, c): .title, route(c, b): .sourceAndTitle,
                                                    route(d, c): .title]
        #expect(keepingRoutes(between: [a, b], from: routes) == [route(a, b): .title, route(b, a): .sourceAndTitle])
        #expect(keepingRoutes(between: [b, c, d], from: routes) == [route(c, b): .sourceAndTitle, route(d, c): .title])
        #expect(keepingRoutes(between: [a, b, c, d], from: routes) == routes)
        // One selected calendar has no pair, nor has none.
        #expect(keepingRoutes(between: [a], from: routes) == [:])
        #expect(keepingRoutes(between: [], from: routes) == [:])
        #expect(keepingRoutes(between: [a, b], from: [:]) == [:])
    }

    /// Routes from or to a calendar that is not selected title nothing: every copy reads `Busy`.
    @Test func routeOutsideSelectionIsIgnored() {
        let s = settings([a, b, c], formats: [route(d, c): .title, route(a, d): .title])
        let events = [original("A", "one"), original("B", "two", start: t0 + 7200),
                      original("C", "three", start: t0 + 14_400), original("D", "four", start: t0 + 21_600)]
        let creates = reconcile(events: events, settings: s, window: window).compactMap { action -> CopySpec? in
            if case let .create(spec) = action { return spec }
            return nil
        }
        #expect(creates.count == 6)
        #expect(creates.allSatisfy { $0.title == CopySpec.busyTitle })
        #expect(!creates.contains { $0.target == d })
    }

    @Test func hiddenTitleIsBusy() throws {
        let o = original()
        let key = try #require(ExclusionKey.occurrence(for: o))
        let s = settings(formats: [aToB: .title], hidden: [key])
        #expect(s.hidesTitle(o))
        #expect(createdTitle(of: o, in: b, s) == "Busy")

        // Never for a copy, even one whose own keys are listed.
        let c1 = copy(of: o, local: "c1", ext: "x", title: meeting)
        let copyKey = try #require(ExclusionKey.occurrence(for: c1))
        #expect(!settings(formats: [aToB: .title], hidden: [copyKey]).hidesTitle(c1))
    }

    @Test func hiddenTitleFollowsSeriesRule() throws {
        let day1 = original("A", "series", start: t0, recurring: true)
        let day2 = original("A", "series", start: t0 + 86_400, recurring: true)
        let series = try #require(ExclusionKey.series(for: day1))
        let events = [day1, day2]

        let hidden = settings(formats: [aToB: .title], hidden: [series])
        #expect(createdTitle(of: day1, in: b, hidden, events: events) == "Busy")
        #expect(createdTitle(of: day2, in: b, hidden, events: events) == "Busy")

        let include = try #require(ExclusionKey.include(for: day2))
        let oneShown = settings(formats: [aToB: .title], hidden: [series, include])
        #expect(createdTitle(of: day1, in: b, oneShown, events: events) == "Busy")
        #expect(createdTitle(of: day2, in: b, oneShown, events: events) == meeting)
    }

    // MARK: - When a kept copy is rewritten

    /// After the upgrade every route is `Busy only`: copies reading `Busy`, and copies whose title is not
    /// read, stay as they are.
    @Test func upgradeKeepsEveryCopy() {
        let o1 = original("A", "one")
        let o2 = original("A", "two", title: "Planning", start: t0 + 7200)
        let c1 = copy(of: o1, local: "c1", ext: "x1", title: "Busy")
        let c2 = copy(of: o2, local: "c2", ext: "x2", title: nil)
        #expect(reconcile(events: [o1, o2, c1, c2], settings: settings(), window: window) == [])
    }

    @Test func renamedMeetingIsRetitled() {
        let o = original()
        let old = copy(of: o, local: "c1", ext: "x", title: "Old name")
        let r = reconcile(events: [o, old], settings: settings(formats: [aToB: .title]), window: window)
        #expect(r == [.update(localID: "c1", wanted(b, of: o, title: meeting))])
    }

    @Test func trailingSpaceDoesNotRetitle() {
        let o = original()
        let kept = copy(of: o, local: "c1", ext: "x", title: "Weekly sync ")
        #expect(reconcile(events: [o, kept], settings: settings(formats: [aToB: .title]), window: window) == [])
    }

    @Test func nilTitleIsUnknown() {
        let o = original()
        let unread = copy(of: o, local: "c1", ext: "x", title: nil)
        #expect(reconcile(events: [o, unread], settings: settings(formats: [aToB: .title]), window: window) == [])
    }

    @Test func switchingBackToBusyOnlyRetitles() {
        let o1 = original("A", "one")
        let o2 = original("A", "two", title: "Planning", start: t0 + 7200)
        let c1 = copy(of: o1, local: "c1", ext: "x1", title: meeting)
        let c2 = copy(of: o2, local: "c2", ext: "x2", title: "Planning")
        let r = reconcile(events: [o1, o2, c1, c2], settings: settings(), window: window)
        #expect(r == [.update(localID: "c1", wanted(b, of: o1)), .update(localID: "c2", wanted(b, of: o2))])
    }

    @Test func moveAndRenameIsOneUpdate() {
        let o = original()
        let old = copy(of: o, local: "c1", ext: "x", title: "Old name", start: t0 - 7200)
        let r = reconcile(events: [o, old], settings: settings(formats: [aToB: .title]), window: window)
        #expect(r == [.update(localID: "c1", wanted(b, of: o, title: meeting))])
    }

    @Test func noRetitleHoldsTitleOnly() {
        let o = original()
        let spec = wanted(b, of: o, title: meeting)
        #expect(spec.slotKey == "B|" + spec.marker)
        let s = settings(formats: [aToB: .title])

        let renamed = copy(of: o, local: "c1", ext: "x", title: "Old name")
        #expect(reconcile(events: [o, renamed], settings: s, window: window, noRetitle: [spec.slotKey]) == [])

        let moved = copy(of: o, local: "c1", ext: "x", title: "Old name", start: t0 - 7200)
        #expect(reconcile(events: [o, moved], settings: s, window: window, noRetitle: [spec.slotKey])
            == [.update(localID: "c1", spec)])
    }

    @Test func keepOnePrefersRightTitle() {
        let o = original()
        let first = copy(of: o, local: "c1", ext: "x1", title: "Old name")
        let second = copy(of: o, local: "c2", ext: "x2", title: meeting)
        let r = reconcile(events: [o, second, first], settings: settings(formats: [aToB: .title]), window: window)
        #expect(r == [.delete(localID: "c1", target: b)])
    }

    /// Every copy is a recurring occurrence at the right times: the one with the right title stays, though later
    /// in the order, so no update is planned that the write guard would refuse.
    @Test func keepOneAmongRecurringPrefersRightTitle() {
        let o = original()
        var wrong = copy(of: o, local: "s-wrong", ext: "e1", title: "Old name")
        wrong.isRecurringOccurrence = true
        var right = copy(of: o, local: "s-right", ext: "e2", title: meeting)
        right.isRecurringOccurrence = true
        let r = reconcile(events: [o, right, wrong], settings: settings(formats: [aToB: .title]), window: window)
        #expect(r == [.delete(localID: "s-wrong", target: b)])
    }

    @Test func longTitleIsCutAndStable() {
        let long = String(repeating: "b", count: 300)
        let o = original(title: long)
        let s = settings(formats: [aToB: .title])
        let title = createdTitle(of: o, in: b, s)
        #expect(title == String(repeating: "b", count: 255))
        let kept = copy(of: o, local: "c1", ext: "x", title: title)
        #expect(reconcile(events: [o, kept], settings: s, window: window) == [])

        // The label goes first and the cut applies to the whole: the label is never cut off.
        let labelled = settings(formats: [aToB: .sourceAndTitle], labels: [a: "Acme"])
        #expect(createdTitle(of: o, in: b, labelled) == "Acme: " + String(repeating: "b", count: 249))
    }

    // MARK: - Privacy

    @Test func descriptionsRedactTitle() {
        var event = original()
        event.title = "Secret"
        let spec = wanted(b, of: event, title: "Secret")
        let texts = [
            String(describing: event),
            String(describing: spec),
            String(describing: SyncAction.create(spec)),
            String(describing: SyncAction.update(localID: "c1", spec)),
            String(reflecting: event),
            String(reflecting: spec),
            "\([spec])",
        ]
        for text in texts {
            #expect(text.contains("title: <redacted>"))
            #expect(!text.contains("Secret"))
        }
        // Every other field stays readable.
        #expect(String(describing: event).contains(event.localID))
        #expect(String(describing: spec).contains(spec.marker))
        // A title that was not read prints as nil, so it can be told apart from a redacted one.
        event.title = nil
        #expect(String(describing: event).contains("title: nil"))
    }
}
