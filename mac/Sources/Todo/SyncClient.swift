import Foundation
import TodoCore

enum SyncError: Error {
    case http(Int, String)
}

/// Talks to public.todo_pull / public.todo_push (see supabase/todo.sql).
struct SyncClient {
    let baseURL: URL
    let apiKey: String
    let syncKey: String

    struct PullResult: Decodable {
        let rev: Int64
        let items: [TodoItem]
    }

    func pull(since: Int64) async throws -> PullResult {
        struct Body: Encodable { let p_key: String; let p_since: Int64 }
        return try await call("todo_pull", Body(p_key: syncKey, p_since: since))
    }

    func push(_ items: [TodoItem]) async throws {
        struct Body: Encodable { let p_key: String; let p_items: [TodoItem] }
        struct Result: Decodable { let applied: Int }
        let _: Result = try await call("todo_push", Body(p_key: syncKey, p_items: items))
    }

    private func call<Body: Encodable, Result: Decodable>(_ function: String, _ body: Body) async throws -> Result {
        var request = URLRequest(url: baseURL.appendingPathComponent("rest/v1/rpc/\(function)"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SyncError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try JSONDecoder().decode(Result.self, from: data)
    }
}
