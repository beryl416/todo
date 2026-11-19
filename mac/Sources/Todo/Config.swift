import Foundation

enum AppConfig {
    /// The shared Supabase project. The publishable key is public by design;
    /// the sync key (kept only on this Mac) is what guards the to-dos.
    static let supabaseURL = URL(string: "https://hqyucrsqxvzwtyewxqhi.supabase.co")!
    static let publishableKey = "sb_publishable_ZphNZVulyrdtVsKzK910jA_cZOAlQi4"

    /// The iPhone web app.
    static let webAppURL = "https://beryl416.github.io/todo/"

    static var supportDirectory: URL {
        // Lets a second copy run against a scratch folder for testing.
        if let custom = ProcessInfo.processInfo.environment["TODO_SUPPORT_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Todo", isDirectory: true)
    }

    static var stateFile: URL { supportDirectory.appendingPathComponent("state.json") }
    static var syncFile: URL { supportDirectory.appendingPathComponent("sync.json") }

    /// The secret sync key, or nil when this Mac has not been set up for syncing.
    static func loadSyncKey() -> String? {
        struct SyncFile: Decodable { let key: String }
        guard let data = try? Data(contentsOf: syncFile),
              let file = try? JSONDecoder().decode(SyncFile.self, from: data),
              file.key.count >= 32 else { return nil }
        return file.key
    }

    /// The link the iPhone opens once. The key sits after "#", so it is never sent to the web server.
    static func pairingLink(key: String) -> String { "\(webAppURL)#k=\(key)" }
}
