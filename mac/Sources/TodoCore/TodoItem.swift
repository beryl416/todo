import Foundation

/// Which list a to-do lives in: a day's, a week's, or a month's.
public enum Scope: String, Codable, Sendable, CaseIterable {
    case day, week, month

    /// The first day of the period that contains `day`.
    public func start(of day: Day) -> Day {
        switch self {
        case .day: return day
        case .week: return day.weekStart
        case .month: return day.monthStart
        }
    }

    /// The first day of the next period.
    public func next(after day: Day) -> Day {
        let start = start(of: day)
        switch self {
        case .day: return start.adding(days: 1)
        case .week: return start.adding(days: 7)
        case .month: return start.adding(months: 1)
        }
    }
}

/// One list: a scope and the period it covers (named by its first day).
public struct ListKey: Hashable, Sendable {
    public let scope: Scope
    public let start: Day

    public init(_ scope: Scope, containing day: Day) {
        self.scope = scope
        self.start = scope.start(of: day)
    }
}

public struct TodoItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var scope: Scope
    /// The day, or the first day of the week or month (see `list`).
    public var day: Day
    public var done: Bool
    public var starred: Bool
    /// Order within its list; smaller comes first.
    public var position: Double
    /// A delete waiting to reach the server (and other devices).
    public var deleted: Bool
    /// Milliseconds since 1970 of the last change; the newest change wins.
    public var updatedAt: Int64
    /// Set for a sub-task: the to-do it belongs to. Sub-tasks go wherever their parent goes.
    public var parent: UUID?

    public init(id: UUID = UUID(), title: String, scope: Scope = .day, day: Day, done: Bool = false,
                starred: Bool = false, position: Double, deleted: Bool = false, updatedAt: Int64,
                parent: UUID? = nil) {
        self.id = id
        self.title = title
        self.scope = scope
        self.day = day
        self.done = done
        self.starred = starred
        self.position = position
        self.deleted = deleted
        self.updatedAt = updatedAt
        self.parent = parent
    }

    /// The list this to-do belongs to. Tolerates a day that is not the period's first day.
    public var list: ListKey { ListKey(scope, containing: day) }

    enum CodingKeys: String, CodingKey {
        case id, title, scope, day, done, starred, position, deleted, parent
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        scope = (try? c.decodeIfPresent(Scope.self, forKey: .scope)) ?? .day
        day = try c.decode(Day.self, forKey: .day)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        position = try c.decodeIfPresent(Double.self, forKey: .position) ?? 0
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        updatedAt = try c.decode(Int64.self, forKey: .updatedAt)
        parent = try c.decodeIfPresent(UUID.self, forKey: .parent)
    }
}
