import Foundation

/// A number typed into a Settings field, such as Look ahead or Check every: the whole number clamped to
/// `range`, or nil when the text, once surrounding whitespace is trimmed, is not a plain whole number (an
/// optional leading "-" and ASCII digits only: no "+", decimals, spaces inside or other digits). A whole
/// number too long for `Int` clamps like any other out of range.
public func typedNumber(_ text: String, in range: ClosedRange<Int>) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let negative = trimmed.hasPrefix("-")
    let digits = negative ? trimmed.dropFirst() : Substring(trimmed)
    guard !digits.isEmpty, digits.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
        return nil
    }
    guard let magnitude = Int(digits) else { return negative ? range.lowerBound : range.upperBound }
    return min(max(negative ? -magnitude : magnitude, range.lowerBound), range.upperBound)
}

/// What a number field that stages as it is typed (Look ahead) stages for `text`: the whole number clamped to `range`
/// (`typedNumber`), else `applied`, so text that is not a number leaves no change of that setting staged.
public func stagedNumber(_ text: String, in range: ClosedRange<Int>, applied: Int) -> Int {
    typedNumber(text, in: range) ?? applied
}
