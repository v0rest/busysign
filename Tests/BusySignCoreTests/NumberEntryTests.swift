import Testing
@testable import BusySignCore

@Suite struct NumberEntryTests {
    @Test func typedNumberCases() {
        let lookAhead: [(String, Int?)] = [
            ("30", 30), (" 7 ", 7), ("0", 1), ("-3", 1), ("120", 90), ("90", 90),
            ("abc", nil), ("", nil), ("7.5", nil), ("3 0", nil),
        ]
        for (text, expected) in lookAhead {
            #expect(typedNumber(text, in: 1...90) == expected, "\"\(text)\"")
        }
        #expect(typedNumber("61", in: 1...60) == 60)
    }

    @Test func onlyAPlainWholeNumberCounts() {
        for text in ["+5", "-", "--3", "5-", "1e2", "0x10", "1,5", "   ", "٣", "５"] {
            #expect(typedNumber(text, in: 1...90) == nil, "\"\(text)\"")
        }
    }

    @Test func surroundingWhitespaceAndZeroesAreFine() {
        #expect(typedNumber("\t12\n", in: 1...90) == 12)
        #expect(typedNumber("007", in: 1...90) == 7)
        #expect(typedNumber("-0", in: 1...90) == 1)
    }

    /// Too many digits for an Int is still a whole number: it clamps like any other out of range.
    @Test func hugeNumbersClamp() {
        #expect(typedNumber("99999999999999999999", in: 1...90) == 90)
        #expect(typedNumber("-99999999999999999999", in: 1...90) == 1)
    }
}
