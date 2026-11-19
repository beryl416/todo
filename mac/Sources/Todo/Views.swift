import AppKit
import SwiftUI
import TodoCore

enum Theme {
    // Menlo keeps the typewriter look for Latin text while Hangul falls back to its
    // natural width (the system monospaced design spreads Hangul syllables apart).
    static let body = Font.custom("Menlo", size: 13)
    static let bold = Font.custom("Menlo-Bold", size: 13)
    static let small = Font.custom("Menlo", size: 11)
    /// Space left of the text where the checkbox sits.
    static let gutter: CGFloat = 29
    static let side: CGFloat = 16
    static let rowPadding: CGFloat = 8
    static let lineHeight: CGFloat = 16
    static var background: Color { Color(nsColor: .textBackgroundColor) }
    static var faint: Color { Color.secondary.opacity(0.45) }
    /// The one color in the app: a starred to-do.
    static let star = Color(red: 0.96, green: 0.65, blue: 0.14)
}

// MARK: - Window

struct ContentView: View {
    @Environment(Store.self) private var store
    @FocusState private var focus: Focus?

    var body: some View {
        VStack(spacing: 0) {
            Header()
                .padding(.horizontal, Theme.side)
                .padding(.top, 10)
                .padding(.bottom, 12)
            ScrollView {
                TaskList(focus: $focus)
                    .padding(.horizontal, Theme.side)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    // Fill the visible area so a click below the list lands on the background.
                    .containerRelativeFrame(.vertical, alignment: .top) { height, _ in height }
                    .background {
                        Color.clear.contentShape(Rectangle()).onTapGesture(perform: clearFocus)
                    }
            }
            if store.syncEnabled && !store.online {
                Text("오프라인 · 연결되면 맞춰집니다")
                    .font(Theme.small)
                    .foregroundStyle(Theme.faint)
                    .padding(.bottom, 8)
            }
        }
        .background {
            // Clicking empty space (header gaps, margins) ends editing too.
            Theme.background.contentShape(Rectangle()).onTapGesture(perform: clearFocus)
        }
        .onAppear {
            // macOS puts the cursor in the first text field on its own; start with none.
            DispatchQueue.main.async(execute: clearFocus)
        }
        .onChange(of: focus) { old, new in
            if case .item(let id)? = old, new != .item(id) { store.commitEditing(id) }
            if let open = store.expandedID, !store.focus(new, isInside: open) { store.collapse() }
        }
        .onChange(of: store.editingID) { _, id in
            guard let id else { return }
            DispatchQueue.main.async { focus = .item(id) }
        }
        .onChange(of: store.addRequest) { _, _ in
            DispatchQueue.main.async { focus = .add }
        }
    }

    /// Removes the text cursor (and closes an open to-do).
    private func clearFocus() {
        focus = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        if store.expandedID != nil { store.collapse() }
    }
}

struct Header: View {
    @Environment(Store.self) private var store

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(store.title)
                .font(Theme.bold)
                .lineLimit(1)
                .onTapGesture { store.goToToday() }
                .help("오늘로")
            Spacer(minLength: 8)
            IconButton(symbol: "chevron.left", help: "이전 (⌘[)") { store.step(-1) }
            IconButton(symbol: "chevron.right", help: "다음 (⌘])") { store.step(1) }
            Spacer().frame(width: 10)
            ForEach(ViewMode.allCases) { mode in
                Text(mode.label)
                    .font(Theme.small)
                    .foregroundStyle(store.mode == mode ? Color.primary : Theme.faint)
                    .padding(.horizontal, 4)
                    .frame(height: 18)
                    .contentShape(Rectangle())
                    .onTapGesture { store.mode = mode }
            }
            Spacer().frame(width: 8)
            ThemeToggle()
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(hovering ? Color.primary : Theme.faint)
            .frame(width: 20, height: 18)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help(help)
    }
}

enum Appearance {
    static var stored: String { UserDefaults.standard.string(forKey: "appearance") ?? "" }

    static func apply(_ value: String) {
        switch value {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }

    static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    static func toggle() {
        let next = isDark ? "light" : "dark"
        UserDefaults.standard.set(next, forKey: "appearance")
        apply(next)
    }
}

struct ThemeToggle: View {
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        Image(systemName: scheme == .dark ? "sun.max" : "moon")
            .font(.system(size: 11))
            .foregroundStyle(hovering ? Color.primary : Theme.faint)
            .frame(width: 20, height: 18)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { Appearance.toggle() }
            .help(scheme == .dark ? "라이트 모드 (⇧⌘D)" : "다크 모드 (⇧⌘D)")
    }
}

// MARK: - List

/// The day's, week's or month's to-dos: unfinished, then finished, then the add line.
struct TaskList: View {
    var focus: FocusState<Focus?>.Binding
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.state.open(in: store.list)) { TodoRow(item: $0, focus: focus) }
            ForEach(store.state.done(in: store.list)) { TodoRow(item: $0, focus: focus) }
            AddRow(focus: focus)
        }
    }
}

/// A title being typed into. Return (or a pasted line break) calls `onReturn`.
@MainActor
func titleBinding(_ store: Store, _ id: UUID, onReturn: @escaping () -> Void) -> Binding<String> {
    Binding(
        get: { store.state.item(id)?.title ?? "" },
        set: { value in
            if value.contains("\n") {
                store.setTitle(id, value.replacingOccurrences(of: "\n", with: " "))
                DispatchQueue.main.async(execute: onReturn)
            } else {
                store.setTitle(id, value)
            }
        }
    )
}

/// A to-do. Clicking its title opens it: the title becomes editable and its
/// sub-tasks and an "add sub-task" line appear below. Moving it to the day, week
/// or month list is in its right-click menu.
struct TodoRow: View {
    let item: TodoItem
    var focus: FocusState<Focus?>.Binding
    @Environment(Store.self) private var store
    @State private var hovering = false

    private var editing: Bool { store.editingID == item.id }
    private var expanded: Bool { store.expandedID == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow
            if expanded {
                ForEach(store.state.children(of: item.id)) { ChildRow(item: $0, focus: focus) }
                ChildAddRow(parentID: item.id, focus: focus)
            }
        }
    }

    private var mainRow: some View {
        HStack(alignment: .top, spacing: 0) {
            CheckBox(checked: item.done)
                .frame(width: Theme.gutter, height: Theme.lineHeight, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { store.toggleDone(item.id) }
            if editing {
                TextField("", text: titleBinding(store, item.id) { focus.wrappedValue = .childAdd(item.id) }, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .focused(focus, equals: .item(item.id))
                    .onSubmit { focus.wrappedValue = .childAdd(item.id) }
                    .onExitCommand { focus.wrappedValue = nil }
            } else {
                Text(item.title)
                    .font(Theme.body)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? Theme.faint : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { expanded ? store.beginEditing(item.id) : store.open(item.id) }
            }
            let progress = store.state.progress(of: item.id)
            if !expanded && progress.total > 0 {
                Text("\(progress.done)/\(progress.total)")
                    .font(Theme.small)
                    .foregroundStyle(Theme.faint)
                    .frame(height: Theme.lineHeight)
                    .padding(.leading, 8)
            }
            Image(systemName: item.starred ? "star.fill" : "star")
                .font(.system(size: 11))
                .foregroundStyle(item.starred ? Theme.star : Color.secondary)
                .frame(width: 20, height: Theme.lineHeight, alignment: .trailing)
                .opacity(hovering || expanded || item.starred ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture { store.toggleStar(item.id) }
                .padding(.leading, 8)
        }
        .padding(.vertical, Theme.rowPadding)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(item.starred ? "중요 표시 빼기" : "중요 표시") { store.toggleStar(item.id) }
            if !item.done { Button(store.postponeLabel) { store.postpone(item.id) } }
            ForEach(Scope.allCases.filter { $0 != item.scope }, id: \.self) { scope in
                Button(Store.moveLabel(scope)) { store.changeScope(item.id, to: scope) }
            }
            Divider()
            Button("삭제") { store.delete(item.id) }
        }
        .onDrag {
            store.dragging = item.id
            return NSItemProvider(object: item.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: RowDrop(target: item.id, store: store))
    }
}

/// A sub-task: indented so its checkbox lines up with the parent's title.
struct ChildRow: View {
    let item: TodoItem
    var focus: FocusState<Focus?>.Binding
    @Environment(Store.self) private var store

    var body: some View {
        let parent = item.parent ?? item.id
        HStack(alignment: .top, spacing: 0) {
            CheckBox(checked: item.done)
                .frame(width: Theme.gutter, height: Theme.lineHeight, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { store.toggleDone(item.id) }
            if store.editingID == item.id {
                TextField("", text: titleBinding(store, item.id) { focus.wrappedValue = .childAdd(parent) }, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .focused(focus, equals: .item(item.id))
                    .onSubmit { focus.wrappedValue = .childAdd(parent) }
                    .onExitCommand { focus.wrappedValue = nil }
            } else {
                Text(item.title)
                    .font(Theme.body)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? Theme.faint : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { store.beginEditing(item.id) }
            }
        }
        .padding(.leading, Theme.gutter)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu { Button("삭제") { store.delete(item.id) } }
    }
}

struct ChildAddRow: View {
    let parentID: UUID
    var focus: FocusState<Focus?>.Binding
    @Environment(Store.self) private var store
    @State private var text = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("하위 할 일 추가")
                    .font(Theme.body)
                    .foregroundStyle(Theme.faint)
                    .allowsHitTesting(false)
            }
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .focused(focus, equals: .childAdd(parentID))
                .onSubmit(submit)
                .onExitCommand {
                    text = ""
                    focus.wrappedValue = nil
                }
                .onChange(of: text) { _, value in
                    if value.contains("\n") {
                        text = value.replacingOccurrences(of: "\n", with: "")
                        submit()
                    }
                }
        }
        .padding(.leading, Theme.gutter) // starts where the sub-task checkboxes start
        .padding(.vertical, 5)
    }

    /// Return adds the sub-task; Return on an empty line closes the to-do.
    private func submit() {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        if title.isEmpty {
            focus.wrappedValue = nil
            return
        }
        store.addChild(title, to: parentID)
        DispatchQueue.main.async { focus.wrappedValue = .childAdd(parentID) }
    }
}


struct AddRow: View {
    var focus: FocusState<Focus?>.Binding
    @Environment(Store.self) private var store
    @State private var text = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("할 일 추가")
                    .font(Theme.body)
                    .foregroundStyle(Theme.faint)
                    .allowsHitTesting(false)
            }
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .focused(focus, equals: .add)
                .onSubmit(submit)
                .onExitCommand {
                    text = ""
                    focus.wrappedValue = nil
                }
                .onChange(of: text) { _, value in
                    if value.contains("\n") {
                        text = value.replacingOccurrences(of: "\n", with: "")
                        submit()
                    }
                }
        }
        .padding(.leading, Theme.gutter)
        .padding(.vertical, Theme.rowPadding)
    }

    private func submit() {
        store.add(text)
        text = ""
        DispatchQueue.main.async { focus.wrappedValue = .add }
    }
}

/// A sharp square: a thin outline, or solid ink with a check cut out of it when done.
struct CheckBox: View {
    let checked: Bool

    var body: some View {
        ZStack {
            if checked {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.primary)
                CheckMark()
                    .stroke(Theme.background, style: StrokeStyle(lineWidth: 1.6, lineCap: .square, lineJoin: .miter))
                    .padding(EdgeInsets(top: 3.5, leading: 3, bottom: 3.5, trailing: 3))
            } else {
                RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.primary.opacity(0.55), lineWidth: 1)
            }
        }
        .frame(width: 13, height: 13)
    }
}

struct CheckMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.55))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

// MARK: - Drag and drop

struct RowDrop: DropDelegate {
    let target: UUID
    let store: Store

    func validateDrop(info: DropInfo) -> Bool { store.dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragged = store.dragging, dragged != target else { return }
        withAnimation(.easeInOut(duration: 0.12)) { store.move(dragged, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        store.dragging = nil
        return true
    }
}

// MARK: - iPhone pairing

struct PairingView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text("아이폰 연결").font(Theme.bold)
            if let link = store.pairingLink, let image = QRCode.image(for: link) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 196, height: 196)
                    .padding(10)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. 아이폰 카메라로 찍고 Safari에서 엽니다")
                    Text("2. 공유 버튼 → 홈 화면에 추가")
                }
                .font(Theme.small)
                .foregroundStyle(Color.secondary)
                Text("이 코드는 비밀번호처럼 남에게 보여주지 마세요.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center)
            } else {
                Text("이 Mac에 동기화 설정이 없습니다.").font(Theme.small).foregroundStyle(Color.secondary)
            }
            Button("닫기") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 320)
    }
}

enum QRCode {
    static func image(for text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - Window chrome

/// Makes the title bar blend into the page, like the reference.
struct WindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .textBackgroundColor
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
