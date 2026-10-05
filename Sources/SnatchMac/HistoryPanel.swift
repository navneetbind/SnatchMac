import AppKit
import SwiftUI

/// Maccy-style popup: search field, capture history with ⌘1–⌘9, footer actions.
/// A non-activating panel, so the app you were in stays frontmost and ⌘V lands there.
@MainActor
final class HistoryPanelController: NSObject {
    struct Actions {
        var capture: () -> Void
        var readClipboard: () -> Void
        var settings: () -> Void
        var openFile: () -> Void
        var copy: (Capture) -> Void
    }

    let model = HistoryViewModel()
    var actions: Actions!

    private var panel: KeyablePanel?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var anchorTopLeft: NSPoint = .zero
    private var lastClosed = Date.distantPast

    var isVisible: Bool { panel != nil }

    func toggle(from button: NSStatusBarButton?) {
        if isVisible { close(); return }
        // A click on the status item first resigns the panel (closing it); don't reopen on that same click.
        guard Date().timeIntervalSince(lastClosed) > 0.25 else { return }
        show(from: button)
    }

    func show(from button: NSStatusBarButton?) {
        guard panel == nil else { return }
        model.query = ""
        model.kindFilter = nil
        model.selection = 0

        let view = HistoryView(model: model, store: .shared, actions: viewActions)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize

        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentViewController = host
        panel.setContentSize(host.view.fittingSize)

        anchorTopLeft = topLeft(for: panel.frame.size, button: button)
        panel.setFrameTopLeftPoint(anchorTopLeft)
        self.panel = panel

        observers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            },
            // Filtering changes the height; keep the top edge pinned under the menu bar.
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel else { return }
                    if panel.frame.maxY != self.anchorTopLeft.y { panel.setFrameTopLeftPoint(self.anchorTopLeft) }
                }
            },
        ]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? event }
        }

        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.orderOut(nil)
        lastClosed = Date()
    }

    private var viewActions: HistoryView.Actions {
        HistoryView.Actions(
            select: { [weak self] in self?.select($0) },
            capture: { [weak self] in self?.close(); self?.actions.capture() },
            readClipboard: { [weak self] in self?.close(); self?.actions.readClipboard() },
            openFile: { [weak self] in self?.close(); self?.actions.openFile() },
            clear: { [weak self] in self?.clearHistory() },
            settings: { [weak self] in self?.close(); self?.actions.settings() },
            quit: { NSApp.terminate(nil) }
        )
    }

    private func select(_ capture: Capture) {
        close()
        actions.copy(capture)
    }

    private func clearHistory() {
        close()
        HistoryStore.shared.clear()
    }

    private func topLeft(for size: NSSize, button: NSStatusBarButton?) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var point: NSPoint
        switch Settings.popupPosition {
        case .statusItem:
            if let frame = button?.window?.frame {
                point = NSPoint(x: frame.minX, y: frame.minY - 4)
            } else {
                point = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - 4)
            }
        case .cursor:
            point = NSPoint(x: mouse.x, y: mouse.y)
        case .center:
            point = NSPoint(x: visible.midX - size.width / 2, y: visible.midY + size.height / 2)
        }
        point.x = min(max(point.x, visible.minX + 4), visible.maxX - size.width - 4)
        point.y = min(max(point.y, visible.minY + size.height + 4), visible.maxY)
        return point
    }

    // MARK: - Keyboard (Maccy bindings)

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let panel, event.window === panel else { return event }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch (event.keyCode, flags) {
        case (125, []): model.move(1); return nil                     // ↓
        case (126, []): model.move(-1); return nil                    // ↑
        case (36, []), (76, []):                                      // ↩
            if let item = model.selected { select(item) }
            return nil
        case (53, []): close(); return nil                            // Esc
        case (48, []) where Settings.showFilterTabs: model.cycleFilter(1); return nil         // ⇥
        case (48, [.shift]) where Settings.showFilterTabs: model.cycleFilter(-1); return nil  // ⇧⇥
        case (51, [.command, .option]): clearHistory(); return nil    // ⌥⌘⌫ clear
        case (51, [.option]):                                         // ⌥⌫ delete item
            if let item = model.selected { HistoryStore.shared.delete(item) }
            return nil
        default: break
        }

        if flags == [.option], chars == "p" || event.keyCode == 35 {  // ⌥P pin
            if let item = model.selected { HistoryStore.shared.togglePin(item) }
            return nil
        }
        if flags == [.command] {
            if let n = Int(chars), (1...9).contains(n) {
                let items = model.filtered
                if n - 1 < items.count { select(items[n - 1]) }
                return nil
            }
            switch chars {
            case ",": viewActions.settings(); return nil
            case "q": NSApp.terminate(nil); return nil
            default: break
            }
        }
        return event
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0 } }
    @Published var selection = 0
    @Published var kindFilter: Capture.Kind? { didSet { selection = 0 } }

    func cycleFilter(_ delta: Int) {
        let all: [Capture.Kind?] = [nil, .text, .link, .code]
        let i = all.firstIndex(of: kindFilter) ?? 0
        kindFilter = all[(i + delta + all.count) % all.count]
    }

    var filtered: [Capture] {
        var items = HistoryStore.shared.items
        if let kindFilter { items = items.filter { $0.kind == kindFilter } }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.text.localizedCaseInsensitiveContains(q) || ($0.source?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var selected: Capture? {
        let items = filtered
        return items.indices.contains(selection) ? items[selection] : nil
    }

    func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }
}

// MARK: - SwiftUI

struct HistoryView: View {
    struct Actions {
        var select: (Capture) -> Void
        var capture: () -> Void
        var readClipboard: () -> Void
        var openFile: () -> Void
        var clear: () -> Void
        var settings: () -> Void
        var quit: () -> Void
    }

    @ObservedObject var model: HistoryViewModel
    @ObservedObject var store: HistoryStore
    let actions: Actions

    @AppStorage("showMetadata") private var showMetadata = false
    @AppStorage("visibleItems") private var visibleItems = 10
    @AppStorage("showFilterTabs") private var showFilterTabs = false
    @AppStorage("showOpenFile") private var showOpenFile = false
    @FocusState private var searchFocused: Bool

    private var rowHeight: CGFloat { showMetadata ? 38 : 24 }

    var body: some View {
        let items = model.filtered
        VStack(spacing: 0) {
            searchField
            if showFilterTabs { filterTabs }
            Divider().padding(.horizontal, 10)

            if items.isEmpty {
                Text(store.items.isEmpty ? "No captures yet.\nPress \(Settings.captureShortcut?.display ?? "the shortcut") to grab text from the screen."
                                         : "No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, index: index)
                                    .id(item.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: CGFloat(min(items.count, max(visibleItems, 3))) * rowHeight + 8)
                    .onChange(of: model.selection) { _, new in
                        if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
                    }
                }
            }

            Divider().padding(.horizontal, 10)
            VStack(spacing: 0) {
                MenuRow(title: "Capture Text", shortcut: Settings.captureShortcut?.display, action: actions.capture)
                MenuRow(title: "Read Clipboard Image", shortcut: nil, action: actions.readClipboard)
                if showOpenFile {
                    MenuRow(title: "Open Image or PDF…", shortcut: nil, action: actions.openFile)
                }
                Divider().padding(.horizontal, 10).padding(.vertical, 4)
                MenuRow(title: "Clear", shortcut: "⌥⌘⌫", action: actions.clear)
                MenuRow(title: "Settings…", shortcut: "⌘,", action: actions.settings)
                MenuRow(title: "Quit", shortcut: "⌘Q", action: actions.quit)
            }
            .padding(.vertical, 4)
        }
        .frame(width: 360)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Type to search…", text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var filterTabs: some View {
        Picker("", selection: $model.kindFilter) {
            Text("All").tag(Capture.Kind?.none)
            Text("Text").tag(Capture.Kind?.some(.text))
            Text("Links").tag(Capture.Kind?.some(.link))
            Text("QR").tag(Capture.Kind?.some(.code))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .help("⇥ / ⇧⇥ to switch")
    }

    private func row(_ item: Capture, index: Int) -> some View {
        let highlighted = index == model.selection
        return HStack(spacing: 8) {
            Image(systemName: item.symbol)
                .font(.system(size: 11))
                .frame(width: 14)
                .foregroundStyle(highlighted ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showMetadata {
                    Text(metadata(item))
                        .font(.system(size: 11))
                        .foregroundStyle(highlighted ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(highlighted ? .white : .secondary)
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .foregroundStyle(highlighted ? .white.opacity(0.85) : .secondary)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(highlighted ? .white : .primary)
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(highlighted ? Color.accentColor : .clear)
                .padding(.horizontal, 5)
        )
        .contentShape(Rectangle())
        .onHover { if $0 { model.selection = index } }
        .onTapGesture { actions.select(item) }
        .help(helpText(item))
    }

    private func metadata(_ item: Capture) -> String {
        let when = RelativeDateTimeFormatter().localizedString(for: item.date, relativeTo: Date())
        return [item.source, when].compactMap { $0 }.joined(separator: " · ")
    }

    private func helpText(_ item: Capture) -> String {
        let preview = item.text.count > 600 ? String(item.text.prefix(600)) + "…" : item.text
        return preview + "\n\n" + metadata(item) + "\n⌥P pin · ⌥⌫ delete"
    }
}

private struct MenuRow: View {
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let shortcut { Text(shortcut).foregroundStyle(hovering ? .white.opacity(0.85) : .secondary) }
        }
        .font(.system(size: 13))
        .foregroundStyle(hovering ? .white : .primary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovering ? Color.accentColor : .clear)
                .padding(.horizontal, 5)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
