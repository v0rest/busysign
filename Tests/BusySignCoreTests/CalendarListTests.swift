import Testing
@testable import BusySignCore

private func cal(_ id: String, _ title: String, account: String, accountID: String, kind: CalendarKind = .calDAV,
                 writable: Bool = true, delegate: Bool = false, primary: Bool = false) -> CalendarInfo {
    CalendarInfo(ref: CalendarRef(id: id), title: title, accountTitle: account, accountKind: "x",
                 isWritable: writable, isSuggestedPrimary: primary, kind: kind, accountID: accountID,
                 isDelegateAccount: delegate)
}

private let fixture: [CalendarInfo] = [
    cal("ex1", "Calendar", account: "x@acme.com", accountID: "ex", kind: .exchange),
    cal("ex2", "Birthdays", account: "x@acme.com", accountID: "ex", kind: .birthday, writable: false),
    cal("ex3", "United States holidays", account: "x@acme.com", accountID: "ex", kind: .subscription, writable: false),
    cal("g1", "x@initech.com", account: "x@initech.com", accountID: "gv"),
    cal("g2", "Holidays", account: "x@initech.com", accountID: "gv", writable: false),
    cal("p1", "x@example.com", account: "Personal", accountID: "gp"),
    cal("p2", "Family", account: "Personal", accountID: "gp"),
    cal("p3", "Family", account: "Personal", accountID: "gp"),
    cal("p4", "Moon phases", account: "Personal", accountID: "gp", writable: false),
    cal("i1", "Personal", account: "iCloud", accountID: "ic"),
    cal("i2", "Initech", account: "iCloud", accountID: "ic"),
    cal("b1", "Birthdays", account: "Other", accountID: "bd", kind: .birthday, writable: false),
    cal("s1", "Jours fériés", account: "Subscribed", accountID: "sub", kind: .subscription, writable: false),
]

private func marked(_ infos: [CalendarInfo], default id: String?) -> [CalendarInfo] {
    let ids = mainCalendarIDs(infos, defaultCalendarID: id)
    return infos.map { var i = $0; i.isSuggestedPrimary = ids.contains(i.ref.id); return i }
}

@Test func hidesReadOnlyBirthdaySubscription() {
    let list = calendarList(marked(fixture, default: "i1"), selectedIDs: [])
    let all = Set((list.main + list.other).map(\.ref.id))
    #expect(all == ["ex1", "g1", "p1", "p2", "p3", "i1", "i2"])
    #expect(list.other.map(\.ref.id).sorted() == ["i2", "p2", "p3"])
}

@Test func oneMainPerAccount() {
    #expect(mainCalendarIDs(fixture, defaultCalendarID: "i1") == ["ex1", "g1", "p1", "i1"])
    // Default calendar of another account does not matter; iCloud has no rule match without it.
    #expect(mainCalendarIDs(fixture, defaultCalendarID: "g1") == ["ex1", "g1", "p1"])
}

@Test func delegateAccountNotMain() {
    let infos = [cal("d1", "Calendar", account: "Boss", accountID: "dg", kind: .exchange, delegate: true)]
    #expect(mainCalendarIDs(infos, defaultCalendarID: "d1").isEmpty)
}

@Test func selectedHiddenCalendarStaysVisible() {
    let list = calendarList(marked(fixture, default: "i1"), selectedIDs: ["g2", "b1"])
    #expect(list.main.map(\.ref.id).contains("g2"))
    #expect(list.main.map(\.ref.id).contains("b1"))
    #expect(!list.other.map(\.ref.id).contains("g2"))
}

@Test func missingSelectedReported() {
    let list = calendarList(fixture, selectedIDs: ["g1", "gone", "gone"])
    #expect(list.missingSelectedIDs == ["gone"])
}

@Test func shortNames() {
    #expect(defaultShortName(accountTitle: "x@acme.com", calendarTitle: "Calendar") == "Acme")
    #expect(defaultShortName(accountTitle: "x@initech.com", calendarTitle: "x@initech.com") == "Initech")
    #expect(defaultShortName(accountTitle: "Personal", calendarTitle: "x@example.com") == "Example")
    #expect(defaultShortName(accountTitle: "iCloud", calendarTitle: "Personal") == "iCloud")
}

// MARK: - Main calendar rules

@Test func ambiguousAtTitlesPickNone() {
    // Two calendars with "@" in their titles (the user's own and a shared one): the "@" rule picks neither.
    let two = [cal("a1", "x@example.com", account: "Google", accountID: "g"),
               cal("a2", "team@group.calendar.google.com", account: "Google", accountID: "g")]
    #expect(mainCalendarIDs(two, defaultCalendarID: nil).isEmpty)
    // A single "@" title is still picked.
    let one = [cal("a1", "x@example.com", account: "Google", accountID: "g"),
               cal("a2", "Family", account: "Google", accountID: "g")]
    #expect(mainCalendarIDs(one, defaultCalendarID: nil) == ["a1"])
}

@Test func loneLocalCalendarIsNotMain() {
    let local = [cal("l1", "Home", account: "On My Mac", accountID: "local", kind: .local)]
    #expect(mainCalendarIDs(local, defaultCalendarID: nil).isEmpty)
    // The only-writable rule still applies to other kinds.
    let remote = [cal("r1", "Home", account: "Server", accountID: "srv")]
    #expect(mainCalendarIDs(remote, defaultCalendarID: nil) == ["r1"])
}

// The rule-order tests below pin behaviour that already holds; the losing candidate has the lower id, so a
// rule that came first would pick it.

@Test func defaultBeatsExchangeCalendar() {
    let infos = [cal("a", "Calendar", account: "x@corp.com", accountID: "ex", kind: .exchange),
                 cal("b", "Work", account: "x@corp.com", accountID: "ex", kind: .exchange)]
    #expect(mainCalendarIDs(infos, defaultCalendarID: "b") == ["b"])
}

@Test func exchangeCalendarBeatsTitleLikeAccount() {
    let infos = [cal("a", "x@corp.com", account: "x@corp.com", accountID: "ex", kind: .exchange),
                 cal("b", "Calendar", account: "x@corp.com", accountID: "ex", kind: .exchange)]
    #expect(mainCalendarIDs(infos, defaultCalendarID: nil) == ["b"])
}

@Test func titleLikeAccountBeatsAt() {
    let infos = [cal("a", "x@corp.com", account: "Work", accountID: "w"),
                 cal("b", "Work", account: "Work", accountID: "w")]
    #expect(mainCalendarIDs(infos, defaultCalendarID: nil) == ["b"])
}

@Test func onlyWritableCalendarDespiteReadOnlySibling() {
    let infos = [cal("a", "Holidays", account: "Server", accountID: "srv", writable: false),
                 cal("b", "Team", account: "Server", accountID: "srv")]
    #expect(mainCalendarIDs(infos, defaultCalendarID: nil) == ["b"])
}

@Test func emptyAccountIDNeverMain() {
    let infos = [cal("a", "Calendar", account: "", accountID: "", kind: .exchange)]
    #expect(mainCalendarIDs(infos, defaultCalendarID: "a").isEmpty)
}

@Test func birthdayOnlyAccountHasNoMain() {
    let infos = [cal("b1", "Birthdays", account: "Other", accountID: "bd", kind: .birthday, writable: false)]
    #expect(mainCalendarIDs(infos, defaultCalendarID: nil).isEmpty)
}

// MARK: - Display names

private func names(_ items: [(String, String, String, String)]) -> [String: String] {
    displayNames(items.map { DisplayNameItem(id: $0.0, name: $0.1, accountName: $0.2, title: $0.3) })
}

/// Every name differs from every other one, also apart from case, and the input order does not matter.
private func expectDistinct(_ items: [(String, String, String, String)]) {
    let result = names(items)
    #expect(Set(result.values.map { $0.lowercased() }).count == result.count)
    #expect(names(items.reversed()) == result)
    #expect(!result.values.contains { $0.hasSuffix(" · ") || $0.contains(" ·  · ") })
}

@Test func twoFamilyCalendarsInOneAccountAreNumbered() {
    let items = [("p3", "Family", "Gmail", "Family"), ("p2", "Family", "Gmail", "Family"),
                 ("g1", "Initech", "Initech", "x@initech.com")]
    // Account and title are the same for both, so only a number tells them apart; by id.
    #expect(names(items) == ["p2": "Family #1", "p3": "Family #2", "g1": "Initech"])
    expectDistinct(items)
}

@Test func sameTitleInTwoAccountsGetsTheAccountName() {
    let items = [("g2", "busysign-test", "Initech", "busysign-test"),
                 ("e2", "busysign-test", "Acme", "busysign-test"),
                 ("e1", "Acme", "Acme", "Calendar")]
    #expect(names(items) == ["e2": "busysign-test · Acme", "g2": "busysign-test · Initech", "e1": "Acme"])
    expectDistinct(items)
}

@Test func renameToAnExistingName() {
    // The user named the Google main calendar "Initech", like the iCloud calendar "Initech". The app passes the
    // name of the account's main calendar as the account part, which repeats the main calendar's own name.
    let initech = [("g1", "Initech", "Initech", "x@initech.com"), ("i2", "Initech", "iCloud", "Initech"),
                   ("g2", "busysign-test", "Initech", "busysign-test")]
    #expect(names(initech) == ["g1": "Initech", "i2": "Initech · iCloud", "g2": "busysign-test"])
    expectDistinct(initech)
    // Two main calendars named alike: the account parts repeat the names, so the titles tell them apart.
    let mains = [("e1", "Acme", "Acme", "Calendar"), ("p1", "Acme", "Acme", "x@example.com")]
    #expect(names(mains) == ["e1": "Acme · Calendar", "p1": "Acme · x@example.com"])
    expectDistinct(mains)
    // An account part that differs is used.
    let items = [("e1", "Acme", "Acme", "Calendar"), ("p1", "Acme", "Gmail", "x@example.com")]
    #expect(names(items) == ["e1": "Acme", "p1": "Acme · Gmail"])
    expectDistinct(items)
    // Case and surrounding spaces do not make a name different.
    #expect(names([("e1", "Acme", "Acme", "Calendar"), ("p1", "acme", "Gmail", "x@example.com")])
        == ["e1": "Acme", "p1": "acme · Gmail"])
    #expect(namesMatch(" acme ", "Acme"))
    #expect(!namesMatch("Acme", "Gmail"))
    // Two calendars of one account renamed alike: their titles tell them apart.
    let sameAccount = [("e1", "Work", "Acme", "Calendar"), ("e2", "Work", "Acme", "busysign-test")]
    #expect(names(sameAccount) == ["e1": "Work · Calendar", "e2": "Work · busysign-test"])
    expectDistinct(sameAccount)
}

@Test func displayNamesStayDistinctInEdgeCases() {
    // An appended account name runs into a third calendar's name; then the title tells those two apart.
    let third = [("a", "Family", "Gmail", "Family"), ("b", "Family", "iCloud", "Family"),
                 ("c", "Family · Gmail", "Gmail", "Shared")]
    #expect(names(third) == ["a": "Family · Gmail", "b": "Family · iCloud", "c": "Family · Gmail · Shared"])
    expectDistinct(third)
    // Empty parts are never appended (a missing calendar has none); with equal rank the one without parts keeps
    // the name. A missing calendar ranks below a listed one: keeperOrderListedThenMainThenRenamed.
    let missing = [("m2", "A selected calendar", "", ""), ("m1", "A selected calendar", "", ""),
                   ("w2", "Work", "Gmail", "Work"), ("w1", "Work", "", "")]
    #expect(names(missing) == ["m1": "A selected calendar #1", "m2": "A selected calendar #2",
                               "w1": "Work", "w2": "Work · Gmail"])
    expectDistinct(missing)
    // A number already in use is skipped.
    let numbered = [("x", "Family #1", "iCloud", "Family #1"), ("p2", "Family", "Gmail", "Family"),
                    ("p3", "Family", "Gmail", "Family")]
    #expect(names(numbered) == ["x": "Family #1", "p2": "Family #2", "p3": "Family #3"])
    expectDistinct(numbered)
}

// MARK: - Who keeps the plain name

private func item(_ id: String, _ name: String, account: String = "", title: String = "", listed: Bool = true,
                  main: Bool = false, renamed: Bool = false, seen: Int? = nil, default: String? = nil) -> DisplayNameItem {
    DisplayNameItem(id: id, name: name, accountName: account, title: title, isListed: listed, isMain: main,
                    isRenamed: renamed, firstSeen: seen, defaultName: `default`)
}

/// Distinct names, also apart from case, whatever the input order.
private func expectDistinct(_ items: [DisplayNameItem]) {
    let result = displayNames(items)
    #expect(Set(result.values.map { $0.lowercased() }).count == result.count)
    #expect(displayNames(items.reversed()) == result)
}

@Test func reAddedExchangeAccountKeepsTheNameForTheListedCalendar() {
    // The old account's calendar is still selected but gone; the user named both "Work". The listed one keeps it.
    let items = [item("ex-old", "Work", listed: false, renamed: true, seen: 0, default: "A selected calendar"),
                 item("ex-new", "Work", account: "Work", title: "Calendar", main: true, renamed: true, seen: 2,
                      default: "Acme"),
                 item("vt", "Initech", account: "Initech", title: "x@initech.com", main: true, seen: 1)]
    #expect(displayNames(items) == ["ex-new": "Work", "ex-old": "Work #1", "vt": "Initech"])
    expectDistinct(items)
    // Also when only the old one was named like the new one's default name.
    let named = [item("ex-old", "Acme", listed: false, renamed: true, seen: 0, default: "A selected calendar"),
                 item("ex-new", "Acme", account: "Acme", title: "Calendar", main: true, seen: 1)]
    // The new main holds slot 1 of "Acme" by its default name; the old one was only named so.
    #expect(displayNames(named) == ["ex-new": "Acme", "ex-old": "Acme #2"])
    expectDistinct(named)
}

@Test func mainRenamedToASiblingsTitleKeepsIt() {
    // The Google main calendar renamed "Family", next to the account's own "Family" calendar: the main keeps the
    // name; the sibling's account part (the main's name) and title repeat it, so it gets a number.
    let items = [item("g1", "Family", account: "Family", title: "a@example.com", main: true, renamed: true,
                      default: "Gmail"),
                 item("g1f", "Family", account: "Family", title: "Family")]
    #expect(displayNames(items) == ["g1": "Family", "g1f": "Family #1"])
    expectDistinct(items)
    // A "Family" of another account is told apart by its account.
    let other = items + [item("g2", "Gmail", account: "Gmail", title: "b@example.com", main: true),
                         item("g2f", "Family", account: "Gmail", title: "Family")]
    #expect(displayNames(other) == ["g1": "Family", "g1f": "Family #1", "g2": "Gmail", "g2f": "Family · Gmail"])
    expectDistinct(other)
}

@Test func twoGmailAccounts() {
    // Both main calendars are named "Gmail", neither by the user, and rank alike, so both are told apart by their
    // titles; their two "Family" calendars have the same account part and title, so they are numbered in the order
    // first seen.
    let items = [item("g1", "Gmail", account: "Gmail", title: "a@example.com", main: true, seen: 0),
                 item("g2", "Gmail", account: "Gmail", title: "b@example.com", main: true, seen: 1),
                 item("g1f", "Family", account: "Gmail", title: "Family", seen: 3),
                 item("g2f", "Family", account: "Gmail", title: "Family", seen: 2),
                 item("ex", "Acme", account: "Acme", title: "Calendar", main: true, seen: 4)]
    #expect(displayNames(items) == ["g1": "Gmail · a@example.com", "g2": "Gmail · b@example.com",
                                    "g2f": "Family #1", "g1f": "Family #2", "ex": "Acme"])
    expectDistinct(items)
    // The user named the second one "Gmail": the stored name wins over the default one.
    var renamed = items
    renamed[1].isRenamed = true
    #expect(displayNames(renamed)["g2"] == "Gmail")
    #expect(displayNames(renamed)["g1"] == "Gmail · a@example.com")
    expectDistinct(renamed)
}

@Test func keeperOrderListedThenMainThenRenamed() {
    // A listed calendar over a missing one, even a missing main one the user named.
    let missing = [item("w1", "Work", listed: false, main: true, renamed: true),
                   item("w2", "Work", account: "Gmail", title: "Work")]
    #expect(displayNames(missing) == ["w1": "Work #1", "w2": "Work"])
    // A main calendar over another one the user named.
    let main = [item("i2", "Initech", account: "iCloud", title: "Initech", renamed: true),
                item("g1", "Initech", account: "Initech", title: "x@initech.com", main: true)]
    #expect(displayNames(main) == ["g1": "Initech", "i2": "Initech · iCloud"])
    // The renamed one over a default name.
    let renamed = [item("i2", "Initech", account: "iCloud", title: "Initech"),
                   item("g3", "Initech", account: "Work", title: "Team", renamed: true)]
    #expect(displayNames(renamed) == ["g3": "Initech", "i2": "Initech · iCloud"])
    // Two that rank first alike are both told apart, and one ranking below them never keeps the name.
    let tie = [item("a", "Gmail", account: "Gmail", title: "a@example.com", main: true),
               item("b", "Gmail", account: "Gmail", title: "b@example.com", main: true),
               item("c", "Gmail", listed: false)]
    // c's number is its own slot among the three "Gmail" calendars: a and b hold #1 and #2.
    #expect(displayNames(tie) == ["a": "Gmail · a@example.com", "b": "Gmail · b@example.com", "c": "Gmail #3"])
    for items in [missing, main, renamed, tie] { expectDistinct(items) }
}

@Test func numbersFollowTheOrderFirstSeen() {
    let before = [item("p2", "Family", account: "Gmail", title: "Family", seen: 0),
                  item("p3", "Family", account: "Gmail", title: "Family", seen: 1)]
    #expect(displayNames(before) == ["p2": "Family #1", "p3": "Family #2"])
    // A new "Family" with a lower id appears: it gets the next number, the others keep theirs.
    let after = before + [item("p1", "Family", account: "Gmail", title: "Family", seen: 2)]
    #expect(displayNames(after) == ["p1": "Family #3", "p2": "Family #1", "p3": "Family #2"])
    // Calendars without a place come after those with one, by id.
    let unknown = before + [item("p0", "Family", account: "Gmail", title: "Family")]
    #expect(displayNames(unknown) == ["p0": "Family #3", "p2": "Family #1", "p3": "Family #2"])
    expectDistinct(after)
    expectDistinct(unknown)
}

@Test func numbersStayWhenTheNameIsKeptOrRenamed() {
    // Three "Family" calendars of one account, first seen p2, p3, p1; the account's main calendar is "Gmail".
    let base = [item("gm", "Gmail", account: "Gmail", title: "x@example.com", main: true, seen: 0),
                item("p2", "Family", account: "Gmail", title: "Family", seen: 1),
                item("p3", "Family", account: "Gmail", title: "Family", seen: 2),
                item("p1", "Family", account: "Gmail", title: "Family", seen: 3)]
    let numbers = ["p2": "Family #1", "p3": "Family #2", "p1": "Family #3"]
    #expect(displayNames(base).filter { $0.key != "gm" } == numbers)
    // The main calendar renamed "Family" keeps the plain name; the others keep their numbers.
    var mainRenamed = base
    mainRenamed[0].name = "Family"
    mainRenamed[0].accountName = "Family"
    mainRenamed[0].isRenamed = true
    mainRenamed[0].defaultName = "Gmail"
    for i in 1...3 { mainRenamed[i].accountName = "Family" }
    #expect(displayNames(mainRenamed) == numbers.merging(["gm": "Family"]) { $1 })
    // One of them renamed "Family" by the user ranks above the others and keeps the plain name; the others stay.
    var oneRenamed = base
    oneRenamed[3].isRenamed = true
    #expect(displayNames(oneRenamed).filter { $0.key != "gm" } == ["p2": "Family #1", "p3": "Family #2", "p1": "Family"])
    // Next to a main calendar that keeps the name, a renamed one ranks above the others but does not take their
    // numbers.
    var underMain = mainRenamed
    underMain[3].isRenamed = true
    #expect(displayNames(underMain) == numbers.merging(["gm": "Family"]) { $1 })
    for items in [base, mainRenamed, oneRenamed, underMain] { expectDistinct(items) }
}

@Test func numbersAreSlotsThatOnlyTheRenamedCalendarLeaves() {
    // Three "Family" siblings first seen p2, p3, p1 hold the slots #1, #2, #3 of that name.
    let base = [item("gm", "Gmail", account: "Gmail", title: "x@example.com", main: true, seen: 0),
                item("p2", "Family", account: "Gmail", title: "Family", seen: 1),
                item("p3", "Family", account: "Gmail", title: "Family", seen: 2),
                item("p1", "Family", account: "Gmail", title: "Family", seen: 3)]
    let slots = ["gm": "Gmail", "p2": "Family #1", "p3": "Family #2", "p1": "Family #3"]
    #expect(displayNames(base) == slots)
    for i in 1...3 {
        let id = base[i].id
        // Renamed to another name: only that calendar changes, the others keep their slots (a gap is left).
        var away = base
        away[i].name = "Kids"
        away[i].isRenamed = true
        away[i].defaultName = "Family"
        #expect(displayNames(away) == slots.merging([id: "Kids"]) { $1 })
        // Renamed to the shared name in another case: stored, it ranks first and shows the plain name; the
        // others keep their slots.
        var shared = base
        shared[i].name = "family"
        shared[i].isRenamed = true
        shared[i].defaultName = "Family"
        #expect(displayNames(shared) == slots.merging([id: "family"]) { $1 })
        expectDistinct(away)
        expectDistinct(shared)
    }
}

@Test func renamingToTheNameShownStoresNothing() {
    // A default name typed back, in any case or with spaces, or the shown name with its number: nothing stored,
    // so the calendar does not start to rank as one the user named.
    for typed in ["Family", "family", "  FAMILY ", "family #2"] {
        #expect(renameEffect(typed: typed, ownName: "Family", shownName: "Family #2", storedName: nil) == .keep)
    }
    #expect(renameEffect(typed: "Kids", ownName: "Family", shownName: "Family #2", storedName: nil) == .store("Kids"))
    #expect(renameEffect(typed: "  ", ownName: "Family", shownName: "Family #2", storedName: nil) == .keep)
    // A stored name: typed back unchanged keeps it, a new casing of it is a fix the user meant and is stored,
    // blank goes back to the default.
    #expect(renameEffect(typed: "initech", ownName: "initech", shownName: "initech · iCloud", storedName: "initech")
        == .keep)
    #expect(renameEffect(typed: "Initech", ownName: "initech", shownName: "initech · iCloud", storedName: "initech")
        == .store("Initech"))
    #expect(renameEffect(typed: "Initech · icloud", ownName: "initech", shownName: "initech · iCloud",
                         storedName: "initech") == .keep)
    #expect(renameEffect(typed: "", ownName: "initech", shownName: "initech", storedName: "initech") == .clear)
}

/// SplitMix64, so the fuzz below is the same on every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func rank(_ item: DisplayNameItem) -> Int {
    (item.isListed ? 4 : 0) + (item.isMain ? 2 : 0) + (item.isRenamed ? 1 : 0)
}

@Test func displayNamesAreDistinctAndFairOnRandomInputs() {
    var rng = SeededGenerator(state: 2026_11_15)
    // Plain pools make clashes that suffixes cannot run into; the others add names that look like suffixed ones.
    let plainNames = ["Family", "family", " Family", "Gmail", "Work", "Calendar", "A selected calendar"]
    let plainParts = ["", "Gmail", "gmail", "iCloud", "Family", "Work", "Calendar", " "]
    let trickyNames = plainNames + ["Family #1", "Family #2", "Family · Gmail", "Work · Calendar", "Work #1",
                                    "Family · Gmail · Family"]
    let trickyParts = plainParts + ["Family · Gmail"]
    var failures = 0
    for round in 0..<4000 {
        let plain = round % 2 == 0
        var seenIDs = Set<String>()
        let items: [DisplayNameItem] = (0..<Int.random(in: 1...7, using: &rng)).compactMap { _ in
            let id = "id\(Int.random(in: 0..<20, using: &rng))"
            guard seenIDs.insert(id).inserted else { return nil }
            return item(id, (plain ? plainNames : trickyNames).randomElement(using: &rng)!,
                        account: (plain ? plainParts : trickyParts).randomElement(using: &rng)!,
                        title: (plain ? plainParts : trickyParts).randomElement(using: &rng)!,
                        listed: Bool.random(using: &rng), main: Bool.random(using: &rng),
                        renamed: Bool.random(using: &rng),
                        seen: Bool.random(using: &rng) ? Int.random(in: 0..<20, using: &rng) : nil)
        }
        let result = displayNames(items)
        var ok = displayNames(items.shuffled(using: &rng)) == result
        let shown = Array(result.values)
        for i in shown.indices { for j in shown.indices where j > i && namesMatch(shown[i], shown[j]) { ok = false } }
        for x in items { for y in items where x.id != y.id && namesMatch(x.name, y.name) && rank(x) > rank(y) {
            // One that ranks lower never keeps the plain name while one that ranks higher loses it.
            if result[y.id] == y.name && result[x.id] != x.name { ok = false }
        } }
        if plain {
            // The one that ranks first among those sharing a name keeps it.
            for x in items where items.allSatisfy({ $0.id == x.id || !namesMatch($0.name, x.name) || rank($0) < rank(x) }) {
                if result[x.id] != x.name { ok = false }
            }
        }
        if !ok {
            failures += 1
            if failures <= 3 { Issue.record("unfair or clashing names for \(items): \(result)") }
        }
    }
    #expect(failures == 0)
}

/// A staged rename lasts only while its calendar has a rename row in Settings: every calendar without one has the
/// applied entry, present or absent, whatever was staged for it; the calendars with a row keep what is staged.
@Test func stagedRenamesNeedARow() {
    let applied = ["A": "Acme", "B": "Work", "C": "Home"]
    let staged = ["A": "Acme Corp", "C": "Home", "D": "Gym", "E": "Club"]
    // A renamed, B cleared back to its default, C as applied, D and E new names.
    let kept = namesKeepingRenames(of: ["A", "B", "D"], staged: staged, applied: applied)
    #expect(kept == ["A": "Acme Corp", "C": "Home", "D": "Gym"])
    // No row at all: exactly the applied names.
    #expect(namesKeepingRenames(of: [], staged: staged, applied: applied) == applied)
    // Every calendar with a row: exactly the staged names.
    #expect(namesKeepingRenames(of: ["A", "B", "C", "D", "E"], staged: staged, applied: applied) == staged)
    // Nothing staged beyond the applied names: nothing changes.
    #expect(namesKeepingRenames(of: ["A"], staged: applied, applied: applied) == applied)
}
