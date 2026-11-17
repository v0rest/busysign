import Foundation

/// One editing of a Settings field whose text is staged as it is typed (Look ahead, a calendar's short name): the
/// text in the field and the value in effect when the editing began, which Escape stages again. An editing begins
/// with the first keystroke (a short name's when its field opens) and ends on Return, on focus loss, on Escape or
/// when the field shows the value in effect again; the keystrokes in between keep `before`, though each one staged a
/// value of its own.
public struct TypedEdit<Value: Equatable>: Equatable {
    /// What the field shows while the editing lasts, exactly as typed.
    public let text: String
    /// The value in effect, staged or applied, when the editing began.
    public let before: Value

    public init(text: String, before: Value) {
        self.text = text
        self.before = before
    }

    /// The same editing with `text` in the field.
    public func typing(_ text: String) -> TypedEdit {
        TypedEdit(text: text, before: before)
    }

    /// A keystroke: `edit` with `text` in the field, or, with no editing open, a new one that began at `current`, the
    /// value in effect.
    public static func typing(_ text: String, into edit: TypedEdit?, current: Value) -> TypedEdit {
        guard let edit else { return TypedEdit(text: text, before: current) }
        return edit.typing(text)
    }
}

extension TypedEdit where Value == Int {
    /// What the text stages (`stagedNumber`).
    public func staged(in range: ClosedRange<Int>, applied: Int) -> Int {
        stagedNumber(text, in: range, applied: applied)
    }
}
