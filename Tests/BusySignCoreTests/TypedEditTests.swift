import Testing
@testable import BusySignCore

/// A field whose text stages as it is typed (Look ahead, a short name): what the text stages, and what Escape puts
/// back.
@Suite struct TypedEditTests {
    /// A whole number stages clamped to the range; anything else stages the applied value, so text that is not a
    /// number leaves no Look ahead change staged.
    @Test func whatTheTextStages() {
        let cases: [(String, Int)] = [
            ("31", 31), (" 7 ", 7), ("900", 90), ("90", 90), ("0", 1), ("-3", 1), ("007", 7),
            ("", 30), ("   ", 30), ("abc", 30), ("3a", 30), ("7.5", 30), ("+5", 30),
        ]
        for (text, expected) in cases {
            #expect(stagedNumber(text, in: 1...90, applied: 30) == expected, "\"\(text)\"")
        }
        #expect(TypedEdit(text: "120", before: 45).staged(in: 1...90, applied: 30) == 90)
        #expect(TypedEdit(text: "", before: 45).staged(in: 1...90, applied: 30) == 30)
    }

    /// The first keystroke remembers the value in effect; the keystrokes after it keep that value, though each one
    /// staged a new one, so Escape goes back to where the editing began, not to the last keystroke.
    @Test func escapeRestoresWhereTheEditingBegan() {
        var edit = TypedEdit.typing("4", into: nil, current: 30)
        #expect(edit == TypedEdit(text: "4", before: 30))
        edit = TypedEdit.typing("45", into: edit, current: 4)
        edit = TypedEdit.typing("", into: edit, current: 45)
        #expect(edit.text == "")
        #expect(edit.before == 30)
        // A new editing, after Return or focus loss ended that one, starts from the value in effect then.
        #expect(TypedEdit.typing("6", into: nil, current: 45).before == 45)
    }

    /// A short name's editing remembers the stored name staged when its field opened, nil (the default name)
    /// included, and keeps it however the typing goes.
    @Test func aNameEditingKeepsTheEntryItOpenedWith() {
        let none = TypedEdit<String?>(text: "Acme", before: nil)
        let typed = none.typing("Ac").typing("")
        #expect(typed.text == "")
        #expect(typed.before == nil)
        #expect(TypedEdit.typing("x", into: none, current: "Initech").before == nil)
        let named = TypedEdit<String?>(text: "Work", before: "Work")
        #expect(named.typing("Home").before == "Work")
    }
}
