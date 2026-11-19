import Foundation
import Testing
@testable import TodoCore

private let mon = Day(year: 2026, month: 11, day: 16)
private let tue = mon.adding(days: 1)
private let wed = mon.adding(days: 2)
private func dayOf(_ d: Day) -> ListKey { ListKey(.day, containing: d) }
private func weekOf(_ d: Day) -> ListKey { ListKey(.week, containing: d) }
private func monthOf(_ d: Day) -> ListKey { ListKey(.month, containing: d) }
private func titles(_ items: [TodoItem]) -> [String] { items.map(\.title) }

struct EditingTests {
    @Test func addsInOrderAndIgnoresBlank() {
        var s = TodoState()
        s.add("a", in: dayOf(mon), now: 1)
        s.add("  b  ", in: dayOf(mon), now: 2)
        #expect(s.add("   ", in: dayOf(mon), now: 3) == nil)
        #expect(titles(s.open(in: dayOf(mon))) == ["a", "b"])
        #expect(s.open(in: dayOf(tue)).isEmpty)
    }

    @Test func doneItemsLeaveTheOpenListAndComeBackInPlace() {
        var s = TodoState()
        let a = s.add("a", in: dayOf(mon), now: 1)!
        s.add("b", in: dayOf(mon), now: 2)
        s.toggleDone(a.id, now: 3)
        #expect(titles(s.open(in: dayOf(mon))) == ["b"])
        #expect(titles(s.done(in: dayOf(mon))) == ["a"])
        s.toggleDone(a.id, now: 4)
        #expect(titles(s.open(in: dayOf(mon))) == ["a", "b"])
    }

    @Test func starringMovesToTheTopAndUnstarringStays() {
        var s = TodoState()
        s.add("a", in: dayOf(mon), now: 1)
        s.add("b", in: dayOf(mon), now: 2)
        let c = s.add("c", in: dayOf(mon), now: 3)!
        let d = s.add("d", in: dayOf(mon), now: 4)!
        s.toggleDone(d.id, now: 5)
        s.toggleStar(c.id, now: 6)
        #expect(titles(s.open(in: dayOf(mon))) == ["c", "a", "b"])
        #expect(s.item(c.id)!.starred)
        s.toggleStar(c.id, now: 7)
        #expect(titles(s.open(in: dayOf(mon))) == ["c", "a", "b"])
        #expect(!s.item(c.id)!.starred)
        s.toggleStar(d.id, now: 8) // a finished one stays with the finished
        #expect(titles(s.done(in: dayOf(mon))) == ["d"])
    }

    @Test func clearingTheTitleDeletes() {
        var s = TodoState()
        let a = s.add("a", in: dayOf(mon), now: 1)!
        s.setTitle(a.id, "", now: 2)
        #expect(s.pendingPush().isEmpty) // blank titles wait while being edited
        s.commitTitle(a.id, now: 3)
        #expect(s.item(a.id) == nil)
        #expect(s.pendingPush().map(\.deleted) == [true])
    }

    @Test func checkingTheLastSubTaskChecksTheToDo() {
        var s = TodoState()
        let p = s.add("p", in: dayOf(mon), now: 1)!
        s.add("q", in: dayOf(mon), now: 2)
        let a = s.addChild("a", to: p.id, now: 3)!
        let b = s.addChild("b", to: p.id, now: 4)!
        s.toggleDone(a.id, now: 5)
        #expect(!s.item(p.id)!.done) // one left
        s.toggleDone(b.id, now: 6)
        #expect(s.item(p.id)!.done)
        #expect(titles(s.open(in: dayOf(mon))) == ["q"])
        #expect(titles(s.done(in: dayOf(mon))) == ["p"])
        s.toggleDone(b.id, now: 7) // unchecking one opens the to-do again
        #expect(!s.item(p.id)!.done)
        #expect(titles(s.open(in: dayOf(mon))) == ["p", "q"])
    }

    @Test func aToDoCheckedByHandStaysCheckedWhileSubTasksChange() {
        var s = TodoState()
        let p = s.add("p", in: dayOf(mon), now: 1)!
        let a = s.addChild("a", to: p.id, now: 2)!
        s.addChild("b", to: p.id, now: 3)
        s.toggleDone(p.id, now: 4)
        s.toggleDone(a.id, now: 5)
        #expect(s.item(p.id)!.done)
        #expect(s.item(a.id)!.done)
    }

    @Test func addButtonMakesAnEmptyToDoThatGoesAwayIfLeftEmpty() {
        var s = TodoState()
        s.add("a", in: dayOf(mon), now: 1)
        let d = s.add("d", in: dayOf(mon), now: 2)!
        s.toggleDone(d.id, now: 3)
        let blank = s.addBlank(in: dayOf(mon), now: 4)
        #expect(titles(s.open(in: dayOf(mon))) == ["a", ""]) // last of the unfinished
        #expect(!s.pendingPush().contains { $0.id == blank.id }) // not sent while empty
        s.setTitle(blank.id, "b", now: 5)
        s.commitTitle(blank.id, now: 6)
        #expect(titles(s.open(in: dayOf(mon))) == ["a", "b"])
        let left = s.addBlank(in: dayOf(mon), now: 7)
        s.commitTitle(left.id, now: 8)
        #expect(s.item(left.id) == nil)
        #expect(titles(s.open(in: dayOf(mon))) == ["a", "b"])
    }

    @Test func emptyToDosLeftFromLastTimeAreDropped() {
        var s = TodoState()
        let a = s.add("a", in: dayOf(mon), now: 1)!
        let blank = s.addBlank(in: dayOf(mon), now: 2)
        #expect(s.dropBlanks(now: 3) == 1)
        #expect(s.item(blank.id) == nil)
        #expect(s.item(a.id) != nil)
    }

    @Test func commitTrims() {
        var s = TodoState()
        let a = s.add("a", in: dayOf(mon), now: 1)!
        s.setTitle(a.id, " hello ", now: 2)
        s.commitTitle(a.id, now: 3)
        #expect(s.item(a.id)?.title == "hello")
    }

    @Test func dragDownLandsAfterTargetAndUpLandsBefore() {
        var s = TodoState()
        let a = s.add("a", in: dayOf(mon), now: 1)!
        let b = s.add("b", in: dayOf(mon), now: 2)!
        let c = s.add("c", in: dayOf(mon), now: 3)!
        s.move(a.id, to: b.id, now: 4)
        #expect(titles(s.open(in: dayOf(mon))) == ["b", "a", "c"])
        s.move(c.id, to: b.id, now: 5)
        #expect(titles(s.open(in: dayOf(mon))) == ["c", "b", "a"])
    }

    @Test func finishedAndUnfinishedDoNotMix() {
        var s = TodoState()
        let a = s.add("a", in: dayOf(mon), now: 1)!
        let b = s.add("b", in: dayOf(mon), now: 2)!
        s.toggleDone(b.id, now: 3)
        s.move(a.id, to: b.id, now: 4)
        #expect(titles(s.open(in: dayOf(mon))) == ["a"])
        #expect(titles(s.done(in: dayOf(mon))) == ["b"])
    }

    @Test func rollOverMovesUnfinishedToTopOfToday() {
        var s = TodoState()
        let old1 = s.add("old1", in: dayOf(mon), now: 1)!
        s.add("old2", in: dayOf(tue), now: 2)
        let finished = s.add("finished", in: dayOf(mon), now: 3)!
        s.toggleDone(finished.id, now: 4)
        s.add("today", in: dayOf(wed), now: 5)
        #expect(s.rollOver(to: wed, now: 6) == 2)
        #expect(titles(s.open(in: dayOf(wed))) == ["old1", "old2", "today"])
        #expect(titles(s.done(in: dayOf(mon))) == ["finished"])
        #expect(s.item(old1.id)?.day == wed)
        #expect(s.rollOver(to: wed, now: 7) == 0)
    }

    @Test func everyChangeMovesTheClockForward() {
        var s = TodoState()
        let a = s.add("a", in: dayOf(mon), now: 100)!
        s.toggleStar(a.id, now: 50) // device clock went backwards
        #expect(s.item(a.id)!.updatedAt == 101)
    }
}

struct ListTests {
    @Test func dayWeekAndMonthListsAreSeparate() {
        var s = TodoState()
        s.add("daily", in: dayOf(wed), now: 1)
        let weekly = s.add("weekly", in: weekOf(wed), now: 2)!
        let monthly = s.add("monthly", in: monthOf(wed), now: 3)!
        #expect(titles(s.open(in: dayOf(wed))) == ["daily"])
        #expect(titles(s.open(in: weekOf(tue))) == ["weekly"])          // any day in the week finds it
        #expect(titles(s.open(in: monthOf(mon))) == ["monthly"])
        #expect(weekly.scope == .week && weekly.day == mon)               // stored under the week's Monday
        #expect(monthly.day == Day(year: 2026, month: 11, day: 1))
    }

    @Test func listsDoNotMixWhenDragging() {
        var s = TodoState()
        let d = s.add("daily", in: dayOf(mon), now: 1)!
        let w = s.add("weekly", in: weekOf(mon), now: 2)!
        s.move(d.id, to: w.id, now: 3)
        #expect(s.item(d.id)?.scope == .day)
        #expect(titles(s.open(in: weekOf(mon))) == ["weekly"])
    }

    @Test func weeksAndMonthsRollOverToTheCurrentOne() {
        var s = TodoState()
        let lastWeek = mon.adding(days: -7)
        let lastMonth = Day(year: 2026, month: 10, day: 20)
        s.add("old week", in: weekOf(lastWeek), now: 1)
        s.add("old month", in: monthOf(lastMonth), now: 2)
        s.add("this week", in: weekOf(mon), now: 3)
        #expect(s.rollOver(to: wed, now: 4) == 2)
        #expect(titles(s.open(in: weekOf(wed))) == ["old week", "this week"])
        #expect(titles(s.open(in: monthOf(wed))) == ["old month"])
    }

    @Test func postponeGoesToTheNextPeriod() {
        var s = TodoState()
        let d = s.add("d", in: dayOf(wed), now: 1)!
        let w = s.add("w", in: weekOf(wed), now: 2)!
        let m = s.add("m", in: monthOf(wed), now: 3)!
        s.postpone(d.id, today: wed, now: 4)
        s.postpone(w.id, today: wed, now: 5)
        s.postpone(m.id, today: wed, now: 6)
        #expect(s.item(d.id)?.day == wed.adding(days: 1))
        #expect(s.item(w.id)?.day == Day(year: 2026, month: 11, day: 23))
        #expect(s.item(m.id)?.day == Day(year: 2026, month: 12, day: 1))
    }

    @Test func movesBetweenDayWeekAndMonth() {
        var s = TodoState()
        let a = s.add("a", in: dayOf(wed), now: 1)!
        s.changeScope(a.id, to: .week, today: wed, now: 2)
        #expect(titles(s.open(in: weekOf(wed))) == ["a"])
        #expect(s.open(in: dayOf(wed)).isEmpty)
        s.changeScope(a.id, to: .month, today: wed, now: 3)
        #expect(titles(s.open(in: monthOf(wed))) == ["a"])
        s.changeScope(a.id, to: .day, today: wed, now: 4)      // this month holds today → today
        #expect(titles(s.open(in: dayOf(wed))) == ["a"])
    }

    @Test func movingANonCurrentWeekToDayUsesItsFirstDay() {
        var s = TodoState()
        let nextWeek = mon.adding(days: 7)
        let w = s.add("w", in: weekOf(nextWeek), now: 1)!
        s.changeScope(w.id, to: .day, today: wed, now: 2)
        #expect(s.item(w.id)?.day == nextWeek)
        #expect(s.item(w.id)?.scope == .day)
    }

    @Test func subtasksComeAlongWhenTheScopeChanges() {
        var s = TodoState()
        let p = s.add("p", in: dayOf(wed), now: 1)!
        s.addChild("c", to: p.id, now: 2)
        s.changeScope(p.id, to: .week, today: wed, now: 3)
        #expect(titles(s.open(in: weekOf(wed))) == ["p"])
        #expect(titles(s.children(of: p.id)) == ["c"])
    }

    @Test func toleratesAWeeklyItemStoredUnderAMidweekDay() {
        // An older app version could save a weekly to-do under a Thursday.
        var s = TodoState()
        let odd = TodoItem(title: "odd", scope: .week, day: mon.adding(days: 3), position: 1, updatedAt: 1)
        s.applyFull([odd], rev: 1)
        #expect(titles(s.open(in: weekOf(mon))) == ["odd"])
        #expect(s.rollOver(to: wed, now: 2) == 0)
    }

    @Test func itemsWithoutScopeDecodeAsDaily() throws {
        let json = #"{"id":"6733bdea-7a80-4402-b26f-a98936983971","title":"x","day":"2026-11-19","updated_at":1}"#
        let item = try JSONDecoder().decode(TodoItem.self, from: Data(json.utf8))
        #expect(item.scope == .day)
    }
}

struct SubtaskTests {
    @Test func subtasksLiveUnderTheirParentNotInTheList() {
        var s = TodoState()
        let p = s.add("parent", in: dayOf(mon), now: 1)!
        s.addChild("one", to: p.id, now: 2)
        s.addChild("two", to: p.id, now: 3)
        #expect(titles(s.open(in: dayOf(mon))) == ["parent"])
        #expect(titles(s.children(of: p.id)) == ["one", "two"])
    }

    @Test func checkingASubtaskKeepsItsPlaceAndCountsProgress() {
        var s = TodoState()
        let p = s.add("parent", in: dayOf(mon), now: 1)!
        let one = s.addChild("one", to: p.id, now: 2)!
        s.addChild("two", to: p.id, now: 3)
        s.toggleDone(one.id, now: 4)
        #expect(titles(s.children(of: p.id)) == ["one", "two"])
        #expect(s.progress(of: p.id) == (1, 2))
        #expect(s.item(p.id)?.done == false) // the parent is not checked for you
    }

    @Test func noSubtasksOfSubtasks() {
        var s = TodoState()
        let p = s.add("parent", in: dayOf(mon), now: 1)!
        let one = s.addChild("one", to: p.id, now: 2)!
        #expect(s.addChild("deeper", to: one.id, now: 3) == nil)
        #expect(s.addChild("   ", to: p.id, now: 4) == nil)
    }

    @Test func deletingTheParentDeletesItsSubtasks() {
        var s = TodoState()
        let p = s.add("parent", in: dayOf(mon), now: 1)!
        let one = s.addChild("one", to: p.id, now: 2)!
        s.markPushed(s.pendingPush())
        s.delete(p.id, now: 3)
        #expect(s.item(one.id) == nil)
        #expect(Set(s.pendingPush().map(\.id)) == [p.id, one.id])
        #expect(s.pendingPush().allSatisfy { $0.deleted })
    }

    @Test func subtasksFollowTheirParentAndAreNotRolledOnTheirOwn() {
        var s = TodoState()
        let p = s.add("parent", in: dayOf(mon), now: 1)!
        s.addChild("one", to: p.id, now: 2)
        #expect(s.rollOver(to: wed, now: 3) == 1)   // only the parent moves
        #expect(titles(s.open(in: dayOf(wed))) == ["parent"])
        #expect(titles(s.children(of: p.id)) == ["one"])
    }

    @Test func parentFieldRoundTrips() throws {
        var s = TodoState()
        let p = s.add("parent", in: dayOf(mon), now: 1)!
        let one = s.addChild("one", to: p.id, now: 2)!
        let data = try JSONEncoder().encode(one)
        let back = try JSONDecoder().decode(TodoItem.self, from: data)
        #expect(back.parent == p.id)
        let top = try JSONDecoder().decode(TodoItem.self, from: JSONEncoder().encode(p))
        #expect(top.parent == nil)
    }
}

struct SyncTests {
    private func server(_ title: String, id: UUID, on day: Day = mon, at time: Int64, deleted: Bool = false) -> TodoItem {
        TodoItem(id: id, title: title, day: day, position: 1, deleted: deleted, updatedAt: time)
    }

    @Test func pushedItemsAreCleanUnlessEditedAgain() {
        var s = TodoState()
        let a = s.add("a", in: dayOf(mon), now: 1)!
        let b = s.add("b", in: dayOf(mon), now: 2)!
        let batch = s.pendingPush()
        s.setTitle(b.id, "b2", now: 3) // edited while the push was in flight
        s.markPushed(batch)
        #expect(s.dirty == [b.id])
        #expect(s.item(a.id) != nil)
    }

    @Test func pushedDeletesAreForgotten() {
        var s = TodoState()
        let a = s.add("a", in: dayOf(mon), now: 1)!
        s.delete(a.id, now: 2)
        s.markPushed(s.pendingPush())
        #expect(s.items.isEmpty)
        #expect(s.dirty.isEmpty)
    }

    @Test func fullPullReplacesCleanItemsAndKeepsLocalEdits() {
        var s = TodoState()
        let mine = s.add("mine", in: dayOf(mon), now: 10)!
        let gone = s.add("gone", in: dayOf(mon), now: 11)!
        s.markPushed(s.pendingPush())
        s.setTitle(mine.id, "mine edited", now: 20)
        let theirs = UUID()
        s.applyFull([server("mine old", id: mine.id, at: 15), server("theirs", id: theirs, at: 12)], rev: 9)
        #expect(s.item(mine.id)?.title == "mine edited") // ours is newer
        #expect(s.item(gone.id) == nil)                  // deleted elsewhere
        #expect(s.item(theirs)?.title == "theirs")
        #expect(s.lastRev == 9)
    }

    @Test func newerRemoteEditBeatsOlderLocalEdit() {
        var s = TodoState()
        let a = s.add("a", in: dayOf(mon), now: 10)!
        s.markPushed(s.pendingPush())
        s.setTitle(a.id, "local", now: 20)
        s.applyChanges([server("remote", id: a.id, at: 30)], rev: 5)
        #expect(s.item(a.id)?.title == "remote")
        #expect(s.dirty.isEmpty)
    }

    @Test func olderRemoteEditDoesNotOverwriteLocal() {
        var s = TodoState()
        let a = s.add("a", in: dayOf(mon), now: 10)!
        s.setTitle(a.id, "local", now: 20)
        s.applyChanges([server("remote", id: a.id, at: 15)], rev: 5)
        #expect(s.item(a.id)?.title == "local")
        #expect(s.dirty == [a.id])
    }

    @Test func remoteDeletesAndCursor() {
        var s = TodoState()
        #expect(s.pullCursor == 0)
        let a = s.add("a", in: dayOf(mon), now: 10)!
        s.markPushed(s.pendingPush())
        s.applyChanges([server("a", id: a.id, at: 11, deleted: true)], rev: 100)
        #expect(s.item(a.id) == nil)
        #expect(s.pullCursor == 80)
        s.applyChanges([], rev: 3) // the server forgot old tombstones; never go backwards
        #expect(s.lastRev == 100)
    }

    @Test func savesAndLoads() throws {
        var s = TodoState()
        s.add("a", in: weekOf(mon), now: 1)
        let copy = try JSONDecoder().decode(TodoState.self, from: JSONEncoder().encode(s))
        #expect(copy == s)
    }
}
