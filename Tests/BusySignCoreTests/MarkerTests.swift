import Foundation
import Testing
@testable import BusySignCore

@Suite struct MarkerTests {
    private let valid = "busysign-v1:AAAAAAAAAAAAAAAAAAAAAA"

    @Test func deterministic() {
        let s = snap()
        #expect(Marker.make(for: s) == Marker.make(for: s))
        #expect(Marker.make(for: s) != nil)
    }

    @Test func movedSingleEventKeepsMarker() {
        let a = snap(occurrenceDate: Date(timeIntervalSince1970: 1_800_000_000),
                     start: Date(timeIntervalSince1970: 1_800_000_000))
        let b = snap(occurrenceDate: Date(timeIntervalSince1970: 1_800_090_000),
                     start: Date(timeIntervalSince1970: 1_800_090_000))
        #expect(Marker.make(for: a) == Marker.make(for: b))
    }

    @Test func occurrencesDiffer() {
        let a = snap(occurrenceDate: Date(timeIntervalSince1970: 1_800_000_000), isRecurringOccurrence: true)
        let b = snap(occurrenceDate: Date(timeIntervalSince1970: 1_800_086_400), isRecurringOccurrence: true)
        #expect(Marker.make(for: a) != Marker.make(for: b))
    }

    @Test func subSecondsRoundToNearest() {
        func m(_ t: Double) -> String? {
            Marker.make(for: snap(occurrenceDate: Date(timeIntervalSince1970: t), isRecurringOccurrence: true))
        }
        #expect(m(1_800_000_000.4) == m(1_800_000_000.0))
        #expect(m(1_800_000_000.7) == m(1_800_000_001.0))
        #expect(m(1_800_000_000.7) != m(1_800_000_000.0))
    }

    @Test func allDayOccurrenceKeyIgnoresZone() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let la = TimeZone(identifier: "America/Los_Angeles")!
        func midnight(_ tz: TimeZone) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            return cal.date(from: DateComponents(year: 2026, month: 11, day: 13))!
        }
        func m(_ tz: TimeZone) -> String? {
            Marker.make(for: snap(occurrenceDate: midnight(tz), isRecurringOccurrence: true, isAllDay: true), timeZone: tz)
        }
        #expect(midnight(tokyo) != midnight(la))
        #expect(m(tokyo) != nil)
        #expect(m(tokyo) == m(la))
    }

    @Test func noExternalIDNoMarker() {
        #expect(Marker.make(for: snap(externalID: nil)) == nil)
        #expect(Marker.make(for: snap(externalID: "")) == nil)
    }

    @Test func opaque() throws {
        let ext = "AAMkAGI2THVSAAA="
        let m = try #require(Marker.make(for: snap(externalID: ext)))
        let chars = Array(ext)
        for i in 0...(chars.count - 6) {
            #expect(!m.contains(String(chars[i..<(i + 6)])))
        }
        #expect(!m.contains(ext))
    }

    @Test func format() throws {
        let m = try #require(Marker.make(for: snap()))
        #expect(m.wholeMatch(of: /busysign-v1:[A-Za-z0-9_-]{22}/) != nil)
    }

    @Test func goldenVector() {
        // key "evt-ext-123"
        #expect(Marker.make(for: snap(externalID: "evt-ext-123"))
            == "busysign-v1:3lce_rIAe73d2hqw3odJvE")
        // key "evt-ext-123|2026-11-13T09:30:00Z"
        let d = Date(timeIntervalSince1970: 1_794_562_200)
        #expect(Marker.make(for: snap(externalID: "evt-ext-123", occurrenceDate: d, isRecurringOccurrence: true))
            == "busysign-v1:Vqpt5Bff5HyOq1hE_t_c3W")
        // key "evt-ext-123|2026-11-13" (recurring all-day, day taken in the given zone)
        let utc = TimeZone(identifier: "UTC")!
        let day = Date(timeIntervalSince1970: 1_794_528_000) // 2026-11-13T00:00:00Z
        #expect(Marker.make(for: snap(externalID: "evt-ext-123", occurrenceDate: day,
                                      isRecurringOccurrence: true, isAllDay: true), timeZone: utc)
            == "busysign-v1:57wIPm6nheNaDrf5Z4ymPZ")
    }

    @Test func parseFindsMarkerLine() {
        #expect(Marker.parse(notes: valid) == valid)
        #expect(Marker.parse(notes: "  \n" + valid + "\n ") == valid)
        #expect(Marker.parse(notes: valid + "\r\n") == valid)
        #expect(Marker.parse(notes: "\u{FEFF}" + valid) == valid)
    }

    @Test func parseRejectsOtherText() {
        #expect(Marker.parse(notes: "Busy\nsee you") == nil)
        #expect(Marker.parse(notes: "see " + valid) == nil)
        #expect(Marker.parse(notes: valid + " tail") == nil)
        #expect(Marker.parse(notes: "Busy\n" + valid) == nil)
        #expect(Marker.parse(notes: "busysign-v1:short") == nil)
        #expect(Marker.parse(notes: valid + "A") == nil)
        #expect(Marker.parse(notes: "busysign-v1:AAAAAAAAAA+AAAAAAAAAAA") == nil)
        #expect(Marker.parse(notes: "busysign-v2:AAAAAAAAAAAAAAAAAAAAAA") == nil)
        #expect(Marker.parse(notes: nil) == nil)
        #expect(Marker.parse(notes: "") == nil)
    }

    /// `calsync-v1:` with a valid body is not a marker: the notes are an ordinary note, and the event is an
    /// original, with or without attendees.
    @Test func legacyPrefixIsAnOrdinaryNote() {
        let notes = "calsync-v1:" + "3lce_rIAe73d2hqw3odJvE"
        #expect(Marker.parse(notes: notes) == nil)
        #expect(Marker.parse(notes: " \u{FEFF}" + notes + "\n") == nil)
        for attendees in [false, true] {
            #expect(CopyReading(hasAttendees: attendees, notes: notes) == .original)
        }
    }
}
