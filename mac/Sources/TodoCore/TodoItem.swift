import Foundation

public struct TodoItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var day: Day
    public var done: Bool
    public var starred: Bool
    /// Order within a day; smaller comes first.
    public var position: Double
    /// A delete waiting to reach the server (and other devices).
    public var deleted: Bool
    /// Milliseconds since 1970 of the last change; the newest change wins.
    public var updatedAt: Int64

    public init(id: UUID = UUID(), title: String, day: Day, done: Bool = false, starred: Bool = false,
                position: Double, deleted: Bool = false, updatedAt: Int64) {
        self.id = id
        self.title = title
        self.day = day
        self.done = done
        self.starred = starred
        self.position = position
        self.deleted = deleted
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, day, done, starred, position, deleted
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        day = try c.decode(Day.self, forKey: .day)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        position = try c.decodeIfPresent(Double.self, forKey: .position) ?? 0
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        updatedAt = try c.decode(Int64.self, forKey: .updatedAt)
    }
}
