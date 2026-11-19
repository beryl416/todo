import AppKit
import SwiftUI

@main
struct TodoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store()

    var body: some Scene {
        Window("Todo", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 340, minHeight: 320)
                .background(WindowStyler())
                .sheet(isPresented: $store.showPairing) {
                    PairingView().environment(store)
                }
        }
        .defaultSize(width: 380, height: 560)
        .windowResizability(.contentMinSize)
        .commands { TodoCommands(store: store) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.apply(Appearance.stored)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct TodoCommands: Commands {
    let store: Store

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("새 할 일") { store.requestAdd() }
                .keyboardShortcut("n")
            Divider()
            Button("아이폰 연결…") { store.showPairing = true }
                .disabled(!store.syncEnabled)
        }
        CommandGroup(before: .toolbar) {
            Button("일간") { store.mode = .day }.keyboardShortcut("1")
            Button("주간") { store.mode = .week }.keyboardShortcut("2")
            Button("월간") { store.mode = .month }.keyboardShortcut("3")
            Divider()
            Button("이전") { store.step(-1) }.keyboardShortcut("[")
            Button("다음") { store.step(1) }.keyboardShortcut("]")
            Button("오늘") { store.goToToday() }.keyboardShortcut("t")
            Divider()
            Button("라이트/다크 모드 전환") { Appearance.toggle() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
        }
    }
}
