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
}

/// What has keyboard focus: the "add" line of a day, or a to-do being edited.
enum Focus: Hashable {
    case add(Day)
    case item(UUID)
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
    /// The to-do whose title is being edited.
    private(set) var editingID: UUID?
    /// The to-do being dragged.
    var dragging: UUID?
    private(set) var online = true
    var showPairing = false
    /// Bumped to ask the view to focus `addTarget`.
    private(set) var addRequest = 0
    private(set) var addTarget: Day

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
        addTarget = now
        let savedMode = ProcessInfo.processInfo.environment["TODO_MODE"] ?? UserDefaults.standard.string(forKey: "mode")
        mode = ViewMode(rawValue: savedMode ?? "") ?? .day
        syncKey = AppConfig.loadSyncKey()
        client = syncKey.map {
            SyncClient(baseURL: AppConfig.supabaseURL, apiKey: AppConfig.publishableKey, syncKey: $0)
        }
        state.rollOver(to: now, now: Store.clock())
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

    func add(_ title: String, on day: Day) { change { $0.add(title, on: day, now: $1) } }
    func setTitle(_ id: UUID, _ title: String) { change { $0.setTitle(id, title, now: $1) } }
    func toggleDone(_ id: UUID) { change { $0.toggleDone(id, now: $1) } }
    func toggleStar(_ id: UUID) { change { $0.toggleStar(id, now: $1) } }
    func delete(_ id: UUID) {
        if editingID == id { editingID = nil }
        change { $0.delete(id, now: $1) }
    }
    func move(_ id: UUID, to target: UUID) { change { $0.move(id, to: target, now: $1) } }
    func moveToDay(_ id: UUID, _ day: Day) { change { $0.moveToDay(id, day, now: $1) } }
    func postpone(_ id: UUID) {
        guard let item = state.item(id) else { return }
        moveToDay(id, max(item.day, today).adding(days: 1))
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

    /// ⌘N: focus the add line of the day in view (today, in a week that contains it).
    func requestAdd() {
        if mode == .month { mode = .day }
        addTarget = mode == .week && anchor.week.contains(today) ? today : (mode == .week ? anchor.weekStart : anchor)
        addRequest += 1
    }

    static let weekdays = ["월", "화", "수", "목", "금", "토", "일"]

    func weekday(_ d: Day) -> String { Store.weekdays[d.isoWeekday - 1] }

    var title: String {
        let yearPrefix: (Day) -> String = { [today] d in d.year == today.year ? "" : "\(d.year)년 " }
        switch mode {
        case .day:
            return "\(yearPrefix(anchor))\(anchor.month)월 \(anchor.day)일 \(weekday(anchor))요일"
        case .week:
            let start = anchor.weekStart, end = start.adding(days: 6)
            let tail = start.month == end.month ? "\(end.day)일" : "\(end.month)월 \(end.day)일"
            return "\(yearPrefix(start))\(start.month)월 \(start.day)일 – \(tail)"
        case .month:
            return "\(anchor.year)년 \(anchor.month)월"
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
