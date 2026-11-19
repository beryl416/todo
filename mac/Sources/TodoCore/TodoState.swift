import Foundation

/// Everything the app knows about its to-dos, plus which changes the server has not seen yet.
///
/// Sync rules (the web app follows the same ones):
/// - Every change stamps `updatedAt`; between two versions of an item the newer one wins.
/// - Changed items are "dirty" until the server has them.
/// - A pull never overwrites a dirty item with an older server version.
public struct TodoState: Codable, Equatable, Sendable {
    public private(set) var items: [UUID: TodoItem] = [:]
    public private(set) var dirty: Set<UUID> = []
    /// Newest server revision seen; pulls ask only for changes after it.
    public private(set) var lastRev: Int64 = 0

    public init() {}

    // MARK: - Reading

    static func inOrder(_ a: TodoItem, _ b: TodoItem) -> Bool {
        a.position != b.position ? a.position < b.position : a.id.uuidString < b.id.uuidString
    }

    public func item(_ id: UUID) -> TodoItem? {
        guard let item = items[id], !item.deleted else { return nil }
        return item
    }

    public func open(in list: ListKey) -> [TodoItem] {
        items.values.filter { !$0.deleted && $0.parent == nil && !$0.done && $0.list == list }.sorted(by: Self.inOrder)
    }

    public func done(in list: ListKey) -> [TodoItem] {
        items.values.filter { !$0.deleted && $0.parent == nil && $0.done && $0.list == list }.sorted(by: Self.inOrder)
    }

    /// A to-do's sub-tasks, in their own order (checking one off does not move it).
    public func children(of id: UUID) -> [TodoItem] {
        items.values.filter { !$0.deleted && $0.parent == id }.sorted(by: Self.inOrder)
    }

    /// How many sub-tasks are done, out of how many.
    public func progress(of id: UUID) -> (done: Int, total: Int) {
        let kids = children(of: id)
        return (kids.filter(\.done).count, kids.count)
    }

    // MARK: - Editing

    /// Adds a to-do at the end of the list's unfinished items. Blank titles are ignored.
    @discardableResult
    public mutating func add(_ title: String, in list: ListKey, now: Int64, id: UUID = UUID()) -> TodoItem? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = TodoItem(id: id, title: trimmed, scope: list.scope, day: list.start,
                            position: (open(in: list).last?.position ?? 0) + 1, updatedAt: now)
        write(item)
        return item
    }

    /// The add button: an empty to-do at the end of the list's unfinished items, for its
    /// title to be typed in. It is not sent while empty, and `commitTitle` deletes it if
    /// it is left that way.
    @discardableResult
    public mutating func addBlank(in list: ListKey, now: Int64, id: UUID = UUID()) -> TodoItem {
        let item = TodoItem(id: id, title: "", scope: list.scope, day: list.start,
                            position: (open(in: list).last?.position ?? 0) + 1, updatedAt: now)
        write(item)
        return item
    }

    /// At launch: deletes to-dos left empty when the app last closed mid-edit.
    @discardableResult
    public mutating func dropBlanks(now: Int64) -> Int {
        let blanks = items.values.filter { !$0.deleted && $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for item in blanks { delete(item.id, now: now) }
        return blanks.count
    }

    /// Adds a sub-task at the end of a to-do's sub-tasks. Sub-tasks cannot have their own.
    @discardableResult
    public mutating func addChild(_ title: String, to parentID: UUID, now: Int64, id: UUID = UUID()) -> TodoItem? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parent = item(parentID), parent.parent == nil else { return nil }
        let item = TodoItem(id: id, title: trimmed, scope: parent.scope, day: parent.day,
                            position: (children(of: parentID).last?.position ?? 0) + 1,
                            updatedAt: now, parent: parentID)
        write(item)
        return item
    }

    /// Live typing. Kept as typed; `commitTitle` tidies it up.
    public mutating func setTitle(_ id: UUID, _ title: String, now: Int64) {
        update(id, now) { $0.title = title }
    }

    /// Ends an edit: trims the title, and deletes the to-do if nothing is left.
    public mutating func commitTitle(_ id: UUID, now: Int64) {
        guard let item = item(id) else { return }
        let trimmed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete(id, now: now)
        } else if trimmed != item.title {
            update(id, now) { $0.title = trimmed }
        }
    }

    /// Checking a to-do's last open sub-task checks the to-do too; unchecking a sub-task
    /// of a checked to-do opens the to-do again.
    public mutating func toggleDone(_ id: UUID, now: Int64) {
        guard let current = item(id) else { return }
        update(id, now) { $0.done.toggle() }
        guard let parentID = current.parent, let parent = item(parentID) else { return }
        let checked = !current.done
        if checked, !parent.done, children(of: parentID).allSatisfy(\.done) {
            update(parentID, now) { $0.done = true }
        } else if !checked, parent.done {
            update(parentID, now) { $0.done = false }
        }
    }

    /// Starring a to-do also moves it to the top of its list (unfinished or finished);
    /// un-starring leaves it where it is.
    public mutating func toggleStar(_ id: UUID, now: Int64) {
        guard let current = item(id) else { return }
        guard !current.starred, current.parent == nil else {
            update(id, now) { $0.starred.toggle() }
            return
        }
        let first = (current.done ? done(in: current.list) : open(in: current.list)).first { $0.id != id }
        update(id, now) {
            $0.starred = true
            if let first, first.position <= $0.position { $0.position = first.position - 1 }
        }
    }

    /// Deletes a to-do, and its sub-tasks with it.
    public mutating func delete(_ id: UUID, now: Int64) {
        for child in children(of: id) { update(child.id, now) { $0.deleted = true } }
        update(id, now) { $0.deleted = true }
    }

    /// Moves a to-do to the end of another list of the same kind (day, week or month).
    public mutating func move(_ id: UUID, toListContaining day: Day, now: Int64) {
        guard let item = item(id), item.parent == nil else { return }
        let list = ListKey(item.scope, containing: day)
        guard list != item.list else { return }
        let others = item.done ? done(in: list) : open(in: list)
        let position = (others.last?.position ?? 0) + 1
        update(id, now) { $0.day = list.start; $0.position = position }
    }

    /// Moves a to-do between the day, week and month lists (its sub-tasks come along).
    /// A week or month takes the one around the to-do's own date. A day takes today when
    /// today falls in the to-do's current week or month, otherwise that period's first day.
    public mutating func changeScope(_ id: UUID, to scope: Scope, today: Day, now: Int64) {
        guard let item = item(id), item.parent == nil, item.scope != scope else { return }
        let start = item.list.start
        let around: Day
        if scope == .day, ListKey(item.scope, containing: today) == item.list {
            around = today
        } else {
            around = start
        }
        let target = ListKey(scope, containing: around)
        let others = item.done ? done(in: target) : open(in: target)
        let position = (others.last?.position ?? 0) + 1
        update(id, now) { $0.scope = scope; $0.day = target.start; $0.position = position }
    }

    /// "Later": the next day, week or month after whichever is later, its own or the current one.
    public mutating func postpone(_ id: UUID, today: Day, now: Int64) {
        guard let item = item(id) else { return }
        let from = max(item.list.start, item.scope.start(of: today))
        move(id, toListContaining: item.scope.next(after: from), now: now)
    }

    /// Drag and drop: places `id` where `targetID` is, within the target's list.
    /// Dragging down lands after the target, dragging up lands before it.
    /// Unfinished and finished to-dos are not mixed, nor are days, weeks and months.
    public mutating func move(_ id: UUID, to targetID: UUID, now: Int64) {
        guard id != targetID, let moving = item(id), let target = item(targetID),
              moving.parent == nil, target.parent == nil,
              moving.done == target.done, moving.scope == target.scope else { return }
        var list = moving.done ? done(in: target.list) : open(in: target.list)
        let from = list.firstIndex { $0.id == id }
        let movingDown = from.map { $0 < list.firstIndex { $0.id == targetID }! } ?? false
        list.removeAll { $0.id == id }
        let t = list.firstIndex { $0.id == targetID }!
        let at = movingDown ? t + 1 : t
        let position = Self.between(at > 0 ? list[at - 1].position : nil,
                                    at < list.count ? list[at].position : nil)
        update(id, now) { $0.day = target.list.start; $0.position = position }
    }

    /// Unfinished to-dos from earlier days, weeks and months move to the top of the
    /// current day, week and month, oldest first.
    @discardableResult
    public mutating func rollOver(to today: Day, now: Int64) -> Int {
        var moved = 0
        for scope in Scope.allCases {
            let current = ListKey(scope, containing: today)
            let stale = items.values
                .filter { !$0.deleted && !$0.done && $0.parent == nil && $0.scope == scope && $0.list.start < current.start }
                .sorted { ($0.day, $0.position, $0.id.uuidString) < ($1.day, $1.position, $1.id.uuidString) }
            guard !stale.isEmpty else { continue }
            let top = open(in: current).first?.position ?? 1
            for (i, item) in stale.enumerated() {
                let position = top - Double(stale.count - i)
                update(item.id, now) { $0.day = current.start; $0.position = position }
            }
            moved += stale.count
        }
        return moved
    }

    static func between(_ a: Double?, _ b: Double?) -> Double {
        switch (a, b) {
        case (nil, nil): return 1
        case let (a?, nil): return a + 1
        case let (nil, b?): return b - 1
        case let (a?, b?): return (a + b) / 2
        }
    }

    private mutating func update(_ id: UUID, _ now: Int64, _ change: (inout TodoItem) -> Void) {
        guard var item = item(id) else { return }
        change(&item)
        item.updatedAt = max(now, item.updatedAt + 1)
        write(item)
    }

    private mutating func write(_ item: TodoItem) {
        items[item.id] = item
        dirty.insert(item.id)
    }

    // MARK: - Sync

    /// Changes to send. An item whose title is blank (mid-edit) waits.
    public func pendingPush(limit: Int = 500) -> [TodoItem] {
        let ready = dirty.compactMap { items[$0] }.filter {
            $0.deleted || !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return Array(ready.sorted { $0.updatedAt < $1.updatedAt }.prefix(limit))
    }

    /// The server accepted these. Anything edited again since stays dirty.
    public mutating func markPushed(_ pushed: [TodoItem]) {
        for sent in pushed where items[sent.id] == sent {
            dirty.remove(sent.id)
            if sent.deleted { items[sent.id] = nil }
        }
    }

    /// A full snapshot from the server. Local changes it has not seen survive.
    public mutating func applyFull(_ server: [TodoItem], rev: Int64) {
        var next: [UUID: TodoItem] = [:]
        for item in server where !item.deleted { next[item.id] = item }
        for id in dirty {
            guard let local = items[id] else { continue }
            if let remote = next[id], remote.updatedAt > local.updatedAt {
                dirty.remove(id) // someone changed it after us; theirs wins
            } else {
                next[id] = local
            }
        }
        items = next
        lastRev = rev
    }

    /// Changes since the last pull, including deletes from other devices.
    public mutating func applyChanges(_ server: [TodoItem], rev: Int64) {
        for remote in server {
            if dirty.contains(remote.id) {
                guard let local = items[remote.id], remote.updatedAt > local.updatedAt else { continue }
                dirty.remove(remote.id)
            }
            items[remote.id] = remote.deleted ? nil : remote
        }
        lastRev = max(lastRev, rev)
    }

    /// Where the next incremental pull should start. A small overlap catches
    /// writes that committed out of order on the server.
    public var pullCursor: Int64 { lastRev == 0 ? 0 : max(1, lastRev - 20) }
}
