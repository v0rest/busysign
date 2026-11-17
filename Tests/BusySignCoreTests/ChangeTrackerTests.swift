import Foundation
import os
import Testing
@testable import BusySignCore

@Suite struct ChangeTrackerTests {
    let cal = CalendarRef(id: "cal-a")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A calendar frozen in time (its account stopped syncing): a daily 9:00 series in one calendar and a
    /// weekday 9:30 series in the other, cached locally and never edited. Hourly runs for 4 days, across a
    /// weekend, with a 24 h threshold: both calendars turn stale once 24 h have passed.
    @Test func frozenCalendarsWithRecurringSeriesTurnStale() async {
        let other = CalendarRef(id: "cal-b")
        let gregorian = Calendar.current
        let day0 = gregorian.startOfDay(for: t0)
        let base = day0.addingTimeInterval(10 * 3600)
        var events: [EventSnapshot] = []
        for d in -2..<100 {
            let day = gregorian.date(byAdding: .day, value: d, to: day0)!
            let daily = day.addingTimeInterval(9 * 3600)
            events.append(snap(calendar: "cal-a", localID: "series-1", externalID: "standup",
                               occurrenceDate: daily, isRecurringOccurrence: true, start: daily, end: daily + 900))
            let weekday = gregorian.component(.weekday, from: day)
            if weekday != 1 && weekday != 7 {
                let sync = day.addingTimeInterval(9.5 * 3600)
                events.append(snap(calendar: "cal-b", localID: "series-2", externalID: "weekday-sync",
                                   occurrenceDate: sync, isRecurringOccurrence: true, start: sync, end: sync + 1800))
            }
        }
        let store = FakeCalendarStore(calendars: [FakeCalendarStore.calendar("cal-a"), FakeCalendarStore.calendar("cal-b")],
                                      events: events)
        let clock = OSAllocatedUnfairLock(initialState: base)
        let engine = SyncEngine(store: store, now: { clock.withLock { $0 } })
        var tracker = ChangeTracker()
        for hour in 0..<(4 * 24) {
            clock.withLock { $0 = base.addingTimeInterval(Double(hour) * 3600) }
            let r = await engine.runOnce(settings: SyncSettings(selected: [cal, other]), mode: .dryRun,
                                         tracker: tracker, staleThreshold: 24 * 3600)
            tracker = r.tracker
            #expect(r.result.skippedReason == nil)
            #expect(r.result.stale == (hour > 24 ? [cal, other] : []), "hour \(hour)")
        }
        #expect(tracker.lastChange(for: cal) == base)
        #expect(tracker.lastChange(for: other) == base)
    }

    // MARK: - Pure tracker tests

    let day: TimeInterval = 24 * 3600

    /// A window of `days` days starting `offset` days after `t0`.
    func window(_ offset: Double = 0, days: Double = 30) -> DateInterval {
        DateInterval(start: t0 + offset * day, duration: days * day)
    }

    func visible(_ events: [EventSnapshot], in w: DateInterval) -> [EventSnapshot] {
        events.filter { $0.start < w.end && $0.end > w.start }
    }

    /// A calendar nobody edits: a daily series, a weekly series, one-off events, a multi-day all-day
    /// event spanning several window starts, and events that only enter the window on later days.
    var fixedCalendar: [EventSnapshot] {
        var out: [EventSnapshot] = []
        for d in -5..<120 {
            let s = t0 + Double(d) * day + 3600
            out.append(snap(localID: "daily", externalID: "daily", occurrenceDate: s, isRecurringOccurrence: true,
                            start: s, end: s + 1800))
            if d % 7 == 0 {
                let w = s + 5 * 3600
                out.append(snap(localID: "weekly", externalID: "weekly", occurrenceDate: w, isRecurringOccurrence: true,
                                start: w, end: w + 3600, myResponse: .tentative))
            }
        }
        out.append(snap(localID: "one-1", externalID: "one-1", start: t0 + 2.5 * day, end: t0 + 2.5 * day + 3600))
        out.append(snap(localID: "one-2", externalID: nil, start: t0 + 10 * day, end: t0 + 10 * day + 900,
                        availability: .free, myResponse: .none))
        out.append(snap(localID: "trip", externalID: "trip", start: t0 + 1 * day, end: t0 + 4 * day, isAllDay: true))
        out.append(snap(localID: "late-1", externalID: "late-1", start: t0 + 32 * day, end: t0 + 32 * day + 3600))
        out.append(snap(localID: "late-2", externalID: "late-2", start: t0 + 35.5 * day, end: t0 + 36 * day))
        return out
    }

    /// Observes `fixedCalendar` (or `events`) as the engine would every 6 hours for `days` days.
    func slide(_ tracker: inout ChangeTracker, days: Int, events: [EventSnapshot]? = nil) {
        let all = events ?? fixedCalendar
        for d in 0..<days {
            for h in stride(from: 0.0, to: 24, by: 6) {
                let w = window(Double(d))
                tracker.observe(visible(all, in: w), in: cal, at: w.start + h * 3600, window: w)
            }
        }
    }

    @Test func firstObservationSetsLastChange() {
        var tracker = ChangeTracker()
        tracker.observe([snap()], in: cal, at: t0, window: window())
        #expect(tracker.lastChange(for: cal) == t0)
        var empty = ChangeTracker()
        empty.observe([], in: cal, at: t0, window: window())
        #expect(empty.lastChange(for: cal) == t0)
    }

    @Test func sameEventsKeepTimestamp() {
        var tracker = ChangeTracker()
        tracker.observe([snap()], in: cal, at: t0, window: window())
        tracker.observe([snap()], in: cal, at: t0 + 3600, window: window())
        #expect(tracker.lastChange(for: cal) == t0)
    }

    @Test func slidingWindowAloneIsNoChange() {
        var tracker = ChangeTracker()
        slide(&tracker, days: 7)
        #expect(tracker.lastChange(for: cal) == t0)
        #expect(tracker.stale([cal], at: t0 + 6 * day + 18 * 3600, threshold: day) == [cal])
    }

    @Test func editInsideOverlapIsAChange() {
        var tracker = ChangeTracker()
        tracker.observe(visible(fixedCalendar, in: window()), in: cal, at: t0, window: window())
        let moved = fixedCalendar.map { e in
            guard e.localID == "one-1" else { return e }
            var m = e
            m.start += 1800
            m.end += 1800
            return m
        }
        tracker.observe(visible(moved, in: window()), in: cal, at: t0 + 3600, window: window())
        #expect(tracker.lastChange(for: cal) == t0 + 3600)
    }

    @Test func editAfterDaysOfSlidingIsAChange() {
        var tracker = ChangeTracker()
        slide(&tracker, days: 3)
        #expect(tracker.lastChange(for: cal) == t0)
        // The weekly occurrence on day 7 turns from tentative to accepted.
        let answered = fixedCalendar.map { e in
            guard e.localID == "weekly", e.start > t0 + 6 * day, e.start < t0 + 8 * day else { return e }
            var a = e
            a.myResponse = .accepted
            return a
        }
        let at = t0 + 3 * day + 3600
        tracker.observe(visible(answered, in: window(3)), in: cal, at: at, window: window(3))
        #expect(tracker.lastChange(for: cal) == at)
    }

    @Test func deletionInsideOverlapIsAChange() {
        var tracker = ChangeTracker()
        slide(&tracker, days: 2)
        let occurrence = t0 + 5 * day + 3600
        let fewer = fixedCalendar.filter { !($0.localID == "daily" && $0.start == occurrence) }
        let at = t0 + 2 * day + 3600
        tracker.observe(visible(fewer, in: window(2)), in: cal, at: at, window: window(2))
        #expect(tracker.lastChange(for: cal) == at)
    }

    @Test func additionInsideOverlapIsAChange() {
        var tracker = ChangeTracker()
        slide(&tracker, days: 2)
        let added = snap(localID: "new", externalID: "new", start: t0 + 4 * day, end: t0 + 4 * day + 3600)
        let at = t0 + 2 * day + 3600
        tracker.observe(visible(fixedCalendar + [added], in: window(2)), in: cal, at: at, window: window(2))
        #expect(tracker.lastChange(for: cal) == at)
    }

    @Test func eventMovedOutOfTheOverlapIsAChange() {
        var tracker = ChangeTracker()
        tracker.observe(visible(fixedCalendar, in: window()), in: cal, at: t0, window: window())
        // Moved past the end of the previous window, into the day the window gained.
        let moved = fixedCalendar.map { e in
            guard e.localID == "one-1" else { return e }
            var m = e
            m.start = t0 + 30.5 * day
            m.end = m.start + 3600
            return m
        }
        let at = t0 + day + 3600
        tracker.observe(visible(moved, in: window(1)), in: cal, at: at, window: window(1))
        #expect(tracker.lastChange(for: cal) == at)
    }

    @Test func longerLookAheadIsNoChange() {
        var tracker = ChangeTracker()
        tracker.observe(visible(fixedCalendar, in: window()), in: cal, at: t0, window: window())
        let longer = window(days: 60)
        tracker.observe(visible(fixedCalendar, in: longer), in: cal, at: t0 + 3600, window: longer)
        tracker.observe(visible(fixedCalendar, in: longer), in: cal, at: t0 + 7200, window: longer)
        #expect(tracker.lastChange(for: cal) == t0)
    }

    /// A read may include events that only touch the window: one ending exactly at its start, one starting
    /// exactly at its end. They are outside it, so neither repeated reads nor a slide count them as changes.
    @Test func eventsTouchingTheWindowEdgesAreIgnored() {
        func touching(_ w: DateInterval) -> [EventSnapshot] {
            [snap(localID: "ends-at-start", externalID: "e1", start: w.start - day, end: w.start, isAllDay: true),
             snap(localID: "starts-at-end", externalID: "e2", start: w.end, end: w.end + day, isAllDay: true)]
        }
        var tracker = ChangeTracker()
        let w0 = window(), w1 = window(1)
        tracker.observe(visible(fixedCalendar, in: w0) + touching(w0), in: cal, at: t0, window: w0)
        tracker.observe(visible(fixedCalendar, in: w0) + touching(w0), in: cal, at: t0 + 3600, window: w0)
        tracker.observe(visible(fixedCalendar, in: w1) + touching(w1), in: cal, at: t0 + day, window: w1)
        tracker.observe(visible(fixedCalendar, in: w1) + touching(w1), in: cal, at: t0 + day + 3600, window: w1)
        #expect(tracker.lastChange(for: cal) == t0)
    }

    /// Re-selected after a long break, or the Mac was off longer than the look-ahead: nothing to compare
    /// with, so the read counts as a first observation instead of an instant stale warning.
    @Test func nonOverlappingWindowsActAsFirstObservation() {
        var tracker = ChangeTracker()
        tracker.observe(visible(fixedCalendar, in: window()), in: cal, at: t0, window: window())
        let later = window(40)
        let at = later.start + 3600
        tracker.observe(visible(fixedCalendar, in: later), in: cal, at: at, window: later)
        #expect(tracker.lastChange(for: cal) == at)
        #expect(tracker.stale([cal], at: at, threshold: day).isEmpty)
        // From there on it is compared as usual.
        let next = window(41)
        tracker.observe(visible(fixedCalendar, in: next), in: cal, at: next.start + 3600, window: next)
        #expect(tracker.lastChange(for: cal) == at)
    }

    /// With a 1-day look-ahead, consecutive windows only touch at midnight. That is still a continuous
    /// observation, so a frozen calendar turns stale after the threshold.
    @Test func touchingWindowsAreContinuous() {
        var tracker = ChangeTracker()
        for hour in 0..<(3 * 24) {
            let w = window(Double(hour / 24), days: 1)
            let at = t0 + Double(hour) * 3600
            tracker.observe(visible(fixedCalendar, in: w), in: cal, at: at, window: w)
            #expect(tracker.stale([cal], at: at, threshold: day) == (Double(hour) * 3600 > day ? [cal] : []),
                    "hour \(hour)")
        }
        #expect(tracker.lastChange(for: cal) == t0)
    }

    @Test func emptiedCalendarKeepsLastChange() {
        var tracker = ChangeTracker()
        tracker.observe(visible(fixedCalendar, in: window()), in: cal, at: t0, window: window())
        tracker.observe([], in: cal, at: t0 + 3600, window: window())
        tracker.observe([], in: cal, at: t0 + 2 * 3600, window: window())
        #expect(tracker.lastChange(for: cal) == t0)
        #expect(tracker.stale([cal], at: t0 + day + 1, threshold: day) == [cal])
        // Events showing up again are a change.
        let back = t0 + 3 * 3600
        tracker.observe([snap()], in: cal, at: back, window: window())
        #expect(tracker.lastChange(for: cal) == back)
    }

    @Test func copiesDoNotCountAsChange() {
        var tracker = ChangeTracker()
        let copy = snap(localID: "copy-1", marker: "m1")
        tracker.observe([snap(), copy], in: cal, at: t0, window: window())
        let movedCopy = snap(localID: "copy-1", start: Date(timeIntervalSince1970: 1_800_100_000), marker: "m1")
        tracker.observe([snap(), movedCopy], in: cal, at: t0.addingTimeInterval(3600), window: window())
        tracker.observe([snap()], in: cal, at: t0.addingTimeInterval(7200), window: window())
        #expect(tracker.lastChange(for: cal) == t0)
    }

    @Test func otherCalendarsEventsAreIgnored() {
        var tracker = ChangeTracker()
        tracker.observe([snap(), snap(calendar: "cal-b", localID: "x")], in: cal, at: t0, window: window())
        tracker.observe([snap()], in: cal, at: t0.addingTimeInterval(60), window: window())
        #expect(tracker.lastChange(for: cal) == t0)
    }

    @Test func eventOrderDoesNotMatter() {
        var tracker = ChangeTracker()
        let a = snap(localID: "a"), b = snap(localID: "b")
        tracker.observe([a, b], in: cal, at: t0, window: window())
        tracker.observe([b, a], in: cal, at: t0.addingTimeInterval(60), window: window())
        #expect(tracker.lastChange(for: cal) == t0)
    }

    @Test func staleAfterThreshold() {
        var tracker = ChangeTracker()
        tracker.observe([snap()], in: cal, at: t0, window: window())
        #expect(tracker.stale([cal], at: t0.addingTimeInterval(day + 1), threshold: day) == [cal])
        #expect(tracker.stale([cal], at: t0.addingTimeInterval(day - 1), threshold: day).isEmpty)
    }

    @Test func neverObservedIsNotStale() {
        let tracker = ChangeTracker()
        #expect(tracker.lastChange(for: cal) == nil)
        #expect(tracker.stale([cal], at: t0, threshold: 1).isEmpty)
    }

    @Test func roundTripsThroughCodable() throws {
        var tracker = ChangeTracker()
        tracker.observe(visible(fixedCalendar, in: window()), in: cal, at: t0, window: window())
        let data = try JSONEncoder().encode(tracker)
        var decoded = try JSONDecoder().decode(ChangeTracker.self, from: data)
        #expect(decoded == tracker)
        #expect(decoded.lastChange(for: cal) == t0)
        #expect(decoded.stale([cal], at: t0.addingTimeInterval(day + 1), threshold: day) == [cal])
        #expect(decoded.stale([cal], at: t0.addingTimeInterval(day - 1), threshold: day).isEmpty)
        // The stored keys survive coding: a slide is still no change, an edit still is.
        decoded.observe(visible(fixedCalendar, in: window(1)), in: cal, at: t0 + day, window: window(1))
        #expect(decoded.lastChange(for: cal) == t0)
        let fewer = fixedCalendar.filter { $0.localID != "one-1" }
        decoded.observe(visible(fewer, in: window(1)), in: cal, at: t0 + day + 60, window: window(1))
        #expect(decoded.lastChange(for: cal) == t0 + day + 60)
    }

    @Test func storesHashedKeysOnly() throws {
        var tracker = ChangeTracker()
        tracker.observe([snap(localID: "visible-local-id", externalID: "visible-external-id")], in: cal, at: t0,
                        window: window())
        let json = String(decoding: try JSONEncoder().encode(tracker), as: UTF8.self)
        #expect(!json.contains("visible-local-id"))
        #expect(!json.contains("visible-external-id"))
        var again = ChangeTracker()
        again.observe([snap(localID: "visible-local-id", externalID: "visible-external-id")], in: cal, at: t0,
                      window: window())
        #expect(again == tracker)
    }
}
