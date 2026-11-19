import Foundation
import Testing
@testable import TodoCore

private let mon = Day(year: 2026, month: 11, day: 16)
private let tue = mon.adding(days: 1)
private let wed = mon.adding(days: 2)

private func titles(_ items: [TodoItem]) -> [String] { items.map(\.title) }

struct EditingTests {
    @Test func addsInOrderAndIgnoresBlank() {
        var s = TodoState()
        s.add("a", on: mon, now: 1)
        s.add("  b  ", on: mon, now: 2)
        #expect(s.add("   ", on: mon, now: 3) == nil)
        #expect(titles(s.open(on: mon)) == ["a", "b"])
        #expect(s.open(on: tue).isEmpty)
    }

    @Test func doneItemsLeaveTheOpenListAndComeBackInPlace() {
        var s = TodoState()
        let a = s.add("a", on: mon, now: 1)!
        s.add("b", on: mon, now: 2)
        s.toggleDone(a.id, now: 3)
        #expect(titles(s.open(on: mon)) == ["b"])
        #expect(titles(s.done(on: mon)) == ["a"])
        s.toggleDone(a.id, now: 4)
        #expect(titles(s.open(on: mon)) == ["a", "b"])
    }

    @Test func clearingTheTitleDeletes() {
        var s = TodoState()
        let a = s.add("a", on: mon, now: 1)!
        s.setTitle(a.id, "", now: 2)
        #expect(s.pendingPush().isEmpty) // blank titles wait while being edited
        s.commitTitle(a.id, now: 3)
        #expect(s.item(a.id) == nil)
        #expect(s.pendingPush().map(\.deleted) == [true])
    }

    @Test func commitTrims() {
        var s = TodoState()
        let a = s.add("a", on: mon, now: 1)!
        s.setTitle(a.id, " hello ", now: 2)
        s.commitTitle(a.id, now: 3)
        #expect(s.item(a.id)?.title == "hello")
    }

    @Test func dragDownLandsAfterTargetAndUpLandsBefore() {
        var s = TodoState()
        let a = s.add("a", on: mon, now: 1)!
        let b = s.add("b", on: mon, now: 2)!
        let c = s.add("c", on: mon, now: 3)!
        s.move(a.id, to: b.id, now: 4)
        #expect(titles(s.open(on: mon)) == ["b", "a", "c"])
        s.move(c.id, to: b.id, now: 5)
        #expect(titles(s.open(on: mon)) == ["c", "b", "a"])
    }

    @Test func dragOntoAnotherDayMovesTheDay() {
        var s = TodoState()
        let a = s.add("a", on: mon, now: 1)!
        let x = s.add("x", on: tue, now: 2)!
        s.move(a.id, to: x.id, now: 3)
        #expect(titles(s.open(on: tue)) == ["a", "x"])
        #expect(s.open(on: mon).isEmpty)
        s.moveToDay(a.id, wed, now: 4)
        #expect(titles(s.open(on: wed)) == ["a"])
    }

    @Test func finishedAndUnfinishedDoNotMix() {
        var s = TodoState()
        let a = s.add("a", on: mon, now: 1)!
        let b = s.add("b", on: mon, now: 2)!
        s.toggleDone(b.id, now: 3)
        s.move(a.id, to: b.id, now: 4)
        #expect(titles(s.open(on: mon)) == ["a"])
        #expect(titles(s.done(on: mon)) == ["b"])
    }

    @Test func rollOverMovesUnfinishedToTopOfToday() {
        var s = TodoState()
        let old1 = s.add("old1", on: mon, now: 1)!
        s.add("old2", on: tue, now: 2)
        let finished = s.add("finished", on: mon, now: 3)!
        s.toggleDone(finished.id, now: 4)
        s.add("today", on: wed, now: 5)
        #expect(s.rollOver(to: wed, now: 6) == 2)
        #expect(titles(s.open(on: wed)) == ["old1", "old2", "today"])
        #expect(titles(s.done(on: mon)) == ["finished"])
        #expect(s.item(old1.id)?.day == wed)
        #expect(s.rollOver(to: wed, now: 7) == 0)
    }

    @Test func everyChangeMovesTheClockForward() {
        var s = TodoState()
        let a = s.add("a", on: mon, now: 100)!
        s.toggleStar(a.id, now: 50) // device clock went backwards
        #expect(s.item(a.id)!.updatedAt == 101)
    }
}

struct SyncTests {
    private func server(_ title: String, id: UUID, on day: Day = mon, at time: Int64, deleted: Bool = false) -> TodoItem {
        TodoItem(id: id, title: title, day: day, position: 1, deleted: deleted, updatedAt: time)
    }

    @Test func pushedItemsAreCleanUnlessEditedAgain() {
        var s = TodoState()
        let a = s.add("a", on: mon, now: 1)!
        let b = s.add("b", on: mon, now: 2)!
        let batch = s.pendingPush()
        s.setTitle(b.id, "b2", now: 3) // edited while the push was in flight
        s.markPushed(batch)
        #expect(s.dirty == [b.id])
        #expect(s.item(a.id) != nil)
    }

    @Test func pushedDeletesAreForgotten() {
        var s = TodoState()
        let a = s.add("a", on: mon, now: 1)!
        s.delete(a.id, now: 2)
        s.markPushed(s.pendingPush())
        #expect(s.items.isEmpty)
        #expect(s.dirty.isEmpty)
    }

    @Test func fullPullReplacesCleanItemsAndKeepsLocalEdits() {
        var s = TodoState()
        let mine = s.add("mine", on: mon, now: 10)!
        let gone = s.add("gone", on: mon, now: 11)!
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
        let a = s.add("a", on: mon, now: 10)!
        s.markPushed(s.pendingPush())
        s.setTitle(a.id, "local", now: 20)
        s.applyChanges([server("remote", id: a.id, at: 30)], rev: 5)
        #expect(s.item(a.id)?.title == "remote")
        #expect(s.dirty.isEmpty)
    }

    @Test func olderRemoteEditDoesNotOverwriteLocal() {
        var s = TodoState()
        let a = s.add("a", on: mon, now: 10)!
        s.setTitle(a.id, "local", now: 20)
        s.applyChanges([server("remote", id: a.id, at: 15)], rev: 5)
        #expect(s.item(a.id)?.title == "local")
        #expect(s.dirty == [a.id])
    }

    @Test func remoteDeletesAndCursor() {
        var s = TodoState()
        #expect(s.pullCursor == 0)
        let a = s.add("a", on: mon, now: 10)!
        s.markPushed(s.pendingPush())
        s.applyChanges([server("a", id: a.id, at: 11, deleted: true)], rev: 100)
        #expect(s.item(a.id) == nil)
        #expect(s.pullCursor == 80)
        s.applyChanges([], rev: 3) // the server forgot old tombstones; never go backwards
        #expect(s.lastRev == 100)
    }

    @Test func savesAndLoads() throws {
        var s = TodoState()
        s.add("a", on: mon, now: 1)
        let copy = try JSONDecoder().decode(TodoState.self, from: JSONEncoder().encode(s))
        #expect(copy == s)
    }
}
