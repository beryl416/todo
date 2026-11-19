import AppKit
import Observation
import TodoCore

enum ViewMode: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day: return "일"
        case .week: return "주"
        case .month: return "월"
        }
    }
    var scope: Scope {
        switch self {
        case .day: return .day
        case .week: return .week
        case .month: return .month
        }
    }
}

/// What has keyboard focus: the "add" line, a to-do or sub-task being edited,
/// or the "add sub-task" line of an open to-do.
enum Focus: Hashable {
    case add
    case item(UUID)
    case childAdd(UUID)
}

@MainActor
@Observable
final class Store {
    private(set) var state: TodoState
    var mode: ViewMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    /// The day the current view is built around.
    var anchor: Day
    private(set) var today: Day
    /// The to-do or sub-task whose title is being edited.
    private(set) var editingID: UUID?
    /// The to-do opened to show its sub-tasks.
    private(set) var expandedID: UUID?
    /// The to-do being dragged.
    var dragging: UUID?
    private(set) var online = true
    var showPairing = false
    /// Bumped to ask the view to focus the add line.
    private(set) var addRequest = 0

    @ObservationIgnored private let syncKey: String?
    @ObservationIgnored private let client: SyncClient?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var needsFullPull = true
    @ObservationIgnored private var syncGeneration = 0
    @ObservationIgnored private var saveGeneration = 0
    @ObservationIgnored private var timers: [Timer] = []

    var syncEnabled: Bool { client != nil }

    init() {
        state = Store.loadState()
        let now = Day.today()
        today = now
        anchor = now
        let savedMode = ProcessInfo.processInfo.environment["TODO_MODE"] ?? UserDefaults.standard.string(forKey: "mode")
        mode = ViewMode(rawValue: savedMode ?? "") ?? .day
        syncKey = AppConfig.loadSyncKey()
        client = syncKey.map {
            SyncClient(baseURL: AppConfig.supabaseURL, apiKey: AppConfig.publishableKey, syncKey: $0)
        }
        state.rollOver(to: now, now: Store.clock())
        showPairing = CommandLine.arguments.contains("--show-pairing")
        startTimers()
        Task { await sync() }
    }

    static func clock() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - Edits

    private func change(_ edit: (inout TodoState, Int64) -> Void) {
        edit(&state, Store.clock())
        scheduleSave()
        scheduleSync()
    }

    /// The list on screen.
    var list: ListKey { ListKey(mode.scope, containing: anchor) }

    func add(_ title: String) {
        let list = list
        change { $0.add(title, in: list, now: $1) }
    }
    func setTitle(_ id: UUID, _ title: String) { change { $0.setTitle(id, title, now: $1) } }
    func toggleDone(_ id: UUID) { change { $0.toggleDone(id, now: $1) } }
    func toggleStar(_ id: UUID) { change { $0.toggleStar(id, now: $1) } }
    func delete(_ id: UUID) {
        if editingID == id { editingID = nil }
        if expandedID == id { expandedID = nil }
        change { $0.delete(id, now: $1) }
    }

    func addChild(_ title: String, to parent: UUID) { change { $0.addChild(title, to: parent, now: $1) } }

    func changeScope(_ id: UUID, to scope: Scope) {
        if expandedID == id { collapse() }
        let today = today
        change { $0.changeScope(id, to: scope, today: today, now: $1) }
    }

    /// Opens a to-do: shows its sub-tasks and puts its title into editing.
    func open(_ id: UUID) {
        if let current = expandedID, current != id { collapse() }
        expandedID = id
        beginEditing(id)
    }

    /// Closes the open to-do and finishes any edit inside it.
    func collapse() {
        if let id = editingID { commitEditing(id) }
        expandedID = nil
    }

    /// Whether keyboard focus is still inside the open to-do (its title, a sub-task, or the add line).
    func focus(_ focus: Focus?, isInside parent: UUID) -> Bool {
        switch focus {
        case .item(let id)?: return id == parent || state.item(id)?.parent == parent
        case .childAdd(let id)?: return id == parent
        default: return false
        }
    }
    func move(_ id: UUID, to target: UUID) { change { $0.move(id, to: target, now: $1) } }
    func postpone(_ id: UUID) {
        let today = today
        change { $0.postpone(id, today: today, now: $1) }
    }

    func beginEditing(_ id: UUID) {
        if let current = editingID, current != id { commitEditing(current) }
        editingID = id
    }

    func commitEditing(_ id: UUID) {
        change { $0.commitTitle(id, now: $1) }
        if editingID == id { editingID = nil }
    }

    // MARK: - Navigation

    func step(_ n: Int) {
        switch mode {
        case .day: anchor = anchor.adding(days: n)
        case .week: anchor = anchor.adding(days: 7 * n)
        case .month: anchor = anchor.monthStart.adding(months: n)
        }
    }

    func goToToday() { anchor = today }

    func show(day: Day) {
        anchor = day
        mode = .day
    }

    /// ⌘N: focus the add line.
    func requestAdd() { addRequest += 1 }

    static let weekdays = ["월", "화", "수", "목", "금", "토", "일"]

    func weekday(_ d: Day) -> String { Store.weekdays[d.isoWeekday - 1] }

    var title: String {
        let yearPrefix: (Day) -> String = { [today] d in d.year == today.year ? "" : "\(d.year)년 " }
        switch mode {
        case .day:
            return "\(yearPrefix(anchor))\(anchor.month)월 \(anchor.day)일 \(weekday(anchor))요일"
        case .week:
            let w = anchor.weekOfMonth
            let ordinal = ["첫째", "둘째", "셋째", "넷째", "다섯째"][w.index - 1]
            return "\(yearPrefix(Day(year: w.year, month: w.month, day: 1)))\(w.month)월 \(ordinal) 주"
        case .month:
            return "\(anchor.year)년 \(anchor.month)월"
        }
    }

    static func moveLabel(_ scope: Scope) -> String {
        switch scope {
        case .day: return "일간으로 옮기기"
        case .week: return "주간으로 옮기기"
        case .month: return "월간으로 옮기기"
        }
    }

    var postponeLabel: String {
        switch mode {
        case .day: return "내일로 미루기"
        case .week: return "다음 주로 미루기"
        case .month: return "다음 달로 미루기"
        }
    }

    var pairingLink: String? { syncKey.map(AppConfig.pairingLink(key:)) }

    // MARK: - Time

    private func startTimers() {
        let fast = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, NSApp.isActive else { return }
                await self.sync()
            }
        }
        let slow = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
        let clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDay() }
        }
        timers = [fast, slow, clock]
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.checkDay()
                await self?.sync()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    /// At midnight: unfinished to-dos move to the new day, and a view of "today" follows along.
    func checkDay() {
        let now = Day.today()
        guard now != today else { return }
        if anchor == today { anchor = now }
        today = now
        change { $0.rollOver(to: now, now: $1) }
    }

    // MARK: - Sync

    func scheduleSync(after delay: Double = 0.6) {
        guard client != nil else { return }
        syncGeneration += 1
        let generation = syncGeneration
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard generation == syncGeneration else { return }
            await sync()
        }
    }

    func sync() async {
        guard let client else { return }
        if syncing {
            syncAgain = true
            return
        }
        syncing = true
        defer { syncing = false }
        var rounds = 0
        repeat {
            syncAgain = false
            rounds += 1
            do {
                let batch = state.pendingPush()
                if !batch.isEmpty {
                    try await client.push(batch)
                    state.markPushed(batch)
                }
                let full = needsFullPull || state.pullCursor == 0
                let result = try await client.pull(since: full ? 0 : state.pullCursor)
                if full {
                    state.applyFull(result.items, rev: result.rev)
                    needsFullPull = false
                } else {
                    state.applyChanges(result.items, rev: result.rev)
                }
                if state.rollOver(to: today, now: Store.clock()) > 0 || !state.pendingPush().isEmpty {
                    syncAgain = true
                }
                online = true
            } catch {
                online = false
                syncAgain = false
            }
            scheduleSave()
        } while syncAgain && rounds < 5
    }

    // MARK: - Saving

    private static func loadState() -> TodoState {
        guard let data = try? Data(contentsOf: AppConfig.stateFile) else { return TodoState() }
        if let state = try? JSONDecoder().decode(TodoState.self, from: data) { return state }
        // Keep an unreadable file aside instead of overwriting it.
        let aside = AppConfig.supportDirectory.appendingPathComponent("state-unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: AppConfig.stateFile, to: aside)
        return TodoState()
    }

    private func scheduleSave() {
        saveGeneration += 1
        let generation = saveGeneration
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard generation == saveGeneration else { return }
            saveNow()
        }
    }

    func saveNow() {
        do {
            try FileManager.default.createDirectory(at: AppConfig.supportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: AppConfig.stateFile, options: .atomic)
        } catch {
            NSLog("Todo: could not save: \(error)")
        }
    }
}
