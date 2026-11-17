import Foundation

/// The kind of a calendar, as the store reports it.
public enum CalendarKind: Sendable, Equatable {
    case local, calDAV, exchange, subscription, birthday, other
}

/// One calendar as offered for selection.
public struct CalendarInfo: Sendable, Equatable {
    public var ref: CalendarRef
    public var title: String
    public var accountTitle: String
    /// Kind of account the calendar belongs to, e.g. `Exchange` or `CalDAV`.
    public var accountKind: String
    public var isWritable: Bool
    public var isSuggestedPrimary: Bool
    public var kind: CalendarKind
    /// Identifier of the account (source) the calendar belongs to; empty when unknown.
    public var accountID: String
    /// True for an account another user delegated to this one.
    public var isDelegateAccount: Bool

    public init(
        ref: CalendarRef,
        title: String,
        accountTitle: String,
        accountKind: String,
        isWritable: Bool,
        isSuggestedPrimary: Bool,
        kind: CalendarKind = .other,
        accountID: String = "",
        isDelegateAccount: Bool = false
    ) {
        self.ref = ref
        self.title = title
        self.accountTitle = accountTitle
        self.accountKind = accountKind
        self.isWritable = isWritable
        self.isSuggestedPrimary = isSuggestedPrimary
        self.kind = kind
        self.accountID = accountID
        self.isDelegateAccount = isDelegateAccount
    }
}

/// Outcome of one `CalendarStore.apply` call. `deleted` includes deletes whose event was already gone.
/// `replaced` counts replacements whose new copy was created and whose old copy is deleted or already gone; one
/// whose create succeeded but whose delete failed counts in `created` and records a failure, one whose old copy
/// is refused or whose create failed counts nothing and records a failure. `failures` hold short texts naming
/// the action kind and identifiers only, never event content.
public struct ApplyReport: Sendable, Equatable {
    public var created: Int
    public var updated: Int
    public var replaced: Int
    public var deleted: Int
    public var failures: [String]

    public init(created: Int = 0, updated: Int = 0, replaced: Int = 0, deleted: Int = 0, failures: [String] = []) {
        self.created = created
        self.updated = updated
        self.replaced = replaced
        self.deleted = deleted
        self.failures = failures
    }
}

public enum AccessState: Sendable {
    case granted, notDetermined, denied
}

public enum CalendarStoreError: Error, Sendable, Equatable {
    case accessNotGranted
    /// A requested calendar id is not present in the store.
    case calendarNotFound(id: String)
    /// The store returned an event without a calendar or dates; the whole read is rejected so a
    /// broken read never looks like "the original is gone".
    case incompleteEvent(calendarID: String)
    /// Saving the batch failed; nothing of it was written.
    case commitFailed
}

extension CalendarStoreError: LocalizedError {
    /// Fixed texts without identifiers or event content, safe to show in the menu.
    public var errorDescription: String? {
        switch self {
        case .accessNotGranted: "Calendar access not granted"
        case .calendarNotFound: "A selected calendar is missing"
        case .incompleteEvent: "A calendar returned an incomplete event"
        case .commitFailed: "Saving calendar changes failed"
        }
    }
}

/// The storage boundary of the sync logic. Implementations never prompt for access except in
/// `requestAccess()`.
public protocol CalendarStore: Sendable {
    func accessState() async -> AccessState
    func requestAccess() async -> Bool
    /// Every event calendar of every account. Throws when access is not granted.
    func calendars() async throws -> [CalendarInfo]
    /// Events of the given calendars overlapping `window`, recurrences expanded. Throws when access is
    /// not granted or any requested calendar is missing.
    func events(in calendars: [CalendarRef], window: DateInterval) async throws -> [EventSnapshot]
    /// Applies the actions in order. Per-action problems go to `ApplyReport.failures`, except a delete
    /// whose event no longer exists, which is done. A `.replace` first checks the old copy as an update would
    /// (a refused one fails the replacement before anything is written), then creates the new copy and deletes
    /// the old one only if that create succeeded; an old copy that is already gone counts as deleted. Throws only
    /// when access is not granted or the final commit fails.
    func apply(_ actions: [SyncAction]) async throws -> ApplyReport
}
