import AppKit
import ServiceManagement
import SwiftUI

/// Maccy-style preferences: toolbar tabs, one SwiftUI pane each.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(Self.tab("General", "gearshape", GeneralPane()))
        tabs.addTabViewItem(Self.tab("Recognition", "text.viewfinder", RecognitionPane()))
        tabs.addTabViewItem(Self.tab("History", "clock.arrow.circlepath", HistoryPane()))
        tabs.addTabViewItem(Self.tab("Appearance", "paintpalette", AppearancePane()))
        tabs.addTabViewItem(Self.tab("Extras", "sparkles", ExtrasPane()))
        tabs.addTabViewItem(Self.tab("Advanced", "gearshape.2", AdvancedPane()))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func tab<V: View>(_ title: String, _ symbol: String, _ view: V) -> NSTabViewItem {
        let host = NSHostingController(rootView: view.frame(width: 500).fixedSize(horizontal: false, vertical: true))
        host.sizingOptions = .preferredContentSize
        host.title = title
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    func show() {
        if window?.isVisible != true { window?.center() }
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Layout helpers (classic right-aligned labels, like Maccy)

private struct Pane<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
            content
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct Row<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        GridRow {
            Text(label.isEmpty ? "" : label + ":")
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 6) { content }
        }
    }
}

private struct Note: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @State private var capture = Settings.captureShortcut
    @State private var history = Settings.historyShortcut
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @AppStorage("showToast") private var showToast = true

    var body: some View {
        Pane {
            Row(label: "Capture text") {
                ShortcutRecorder(shortcut: $capture)
            }
            Row(label: "Open history") {
                ShortcutRecorder(shortcut: $history)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            Row(label: "Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                if let loginError { Note(text: loginError) }
            }
            Row(label: "After capture") {
                Toggle("Show “Copied” notification", isOn: $showToast)
            }
        }
        .onChange(of: capture) { _, value in Settings.captureShortcut = value }
        .onChange(of: history) { _, value in Settings.historyShortcut = value }
        .onChange(of: launchAtLogin) { _, enabled in
            do {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginError = nil
            } catch {
                loginError = error.localizedDescription
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
}

// MARK: - Recognition

private struct RecognitionPane: View {
    @AppStorage("fastMode") private var fastMode = false
    @AppStorage("languageCorrection") private var languageCorrection = true
    @AppStorage("keepLineBreaks") private var keepLineBreaks = true
    @AppStorage("recognitionLanguage") private var language = "auto"
    @AppStorage("detectCodes") private var detectCodes = true
    @AppStorage("openQRLinks") private var openQRLinks = false

    var body: some View {
        Pane {
            Row(label: "Mode") {
                Picker("", selection: $fastMode) {
                    Text("Accurate").tag(false)
                    Text("Fast").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Note(text: "Accurate handles small text and handwriting better. Fast is near-instant.")
            }
            Row(label: "Language") {
                Picker("", selection: $language) {
                    Text("Automatic").tag("auto")
                    Divider()
                    ForEach(Recognizer.supportedLanguages, id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Row(label: "Text") {
                Toggle("Keep line breaks", isOn: $keepLineBreaks)
                Toggle("Use language correction", isOn: $languageCorrection)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            Row(label: "Codes") {
                Toggle("Read QR codes and barcodes", isOn: $detectCodes)
                Toggle("Open QR links automatically", isOn: $openQRLinks)
                    .disabled(!detectCodes)
            }
        }
    }
}

// MARK: - History

private struct HistoryPane: View {
    @ObservedObject private var store = HistoryStore.shared
    @AppStorage("saveHistory") private var saveHistory = true
    @AppStorage("historySize") private var historySize = 200

    var body: some View {
        Pane {
            Row(label: "History") {
                Toggle("Save captures to history", isOn: $saveHistory)
            }
            Row(label: "Size") {
                HStack {
                    TextField("", value: $historySize, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $historySize, in: 10...5000, step: 10).labelsHidden()
                    Text("items")
                }
                .disabled(!saveHistory)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            Row(label: "Stored") {
                Text("\(store.items.count) captures, \(store.items.filter(\.pinned).count) pinned")
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.open(store.folderURL) }
                    Button("Clear History…", role: .destructive, action: confirmClear)
                }
                Note(text: "History stays on this Mac. Nothing is uploaded.")
            }
        }
        .onChange(of: historySize) { _, value in
            if value < 1 { historySize = 1 }
            store.trim()
        }
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear capture history?"
        alert.informativeText = "This removes every capture, including pinned ones."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { store.clearAll() }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @AppStorage("popupPosition") private var position = PopupPosition.statusItem.rawValue
    @AppStorage("showMetadata") private var showMetadata = false
    @AppStorage("visibleItems") private var visibleItems = 10

    var body: some View {
        Pane {
            Row(label: "Popup at") {
                Picker("", selection: $position) {
                    ForEach(PopupPosition.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Row(label: "Visible items") {
                HStack {
                    Text("\(visibleItems)").monospacedDigit().frame(width: 24, alignment: .trailing)
                    Stepper("", value: $visibleItems, in: 3...30).labelsHidden()
                }
            }
            Row(label: "Rows") {
                Toggle("Show source app and time", isOn: $showMetadata)
            }
        }
    }
}

// MARK: - Extras (all optional, all off by default)

private struct ExtrasPane: View {
    @State private var singleLine = Settings.singleLineShortcut
    @AppStorage("spaceToMove") private var spaceToMove = false
    @AppStorage("cleanupText") private var cleanupText = false
    @AppStorage("editBeforeCopy") private var editBeforeCopy = false
    @AppStorage("showFilterTabs") private var showFilterTabs = false
    @AppStorage("showOpenFile") private var showOpenFile = false
    @AppStorage("speakCaptures") private var speakCaptures = false

    var body: some View {
        Pane {
            Row(label: "Single line") {
                ShortcutRecorder(shortcut: $singleLine)
                Note(text: "A second shortcut that captures with all lines joined into one.")
            }
            Row(label: "Selection") {
                Toggle("Hold Space to move the selection", isOn: $spaceToMove)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            Row(label: "Text") {
                Toggle("Clean up text", isOn: $cleanupText)
                Note(text: "Rejoins words hyphenated across lines and merges wrapped lines into paragraphs. Lists keep their breaks.")
                Toggle("Hold ⌥ when releasing to edit before copying", isOn: $editBeforeCopy)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            Row(label: "Popup") {
                Toggle("Show All / Text / Links / QR tabs", isOn: $showFilterTabs)
                Toggle("Show “Open Image or PDF…”", isOn: $showOpenFile)
            }
            Row(label: "Speech") {
                Toggle("Read captured text aloud", isOn: $speakCaptures)
            }
        }
        .onChange(of: singleLine) { _, value in Settings.singleLineShortcut = value }
    }
}

// MARK: - Advanced

private struct AdvancedPane: View {
    var body: some View {
        Pane {
            Row(label: "URL scheme") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(["capture", "clipboard", "history", "settings"], id: \.self) { route in
                        Text("snatchmac://\(route)")
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Note(text: "Anything that can open a URL can drive SnatchMac: Raycast, Alfred, Shortcuts.")
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            Row(label: "Permissions") {
                Button("Open Screen Recording Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Row(label: "Reset") {
                Button("Restore Default Settings") { Settings.resetAll() }
                Note(text: "Resets preferences and shortcuts. History is kept.")
            }
        }
    }
}

// MARK: - Shortcut recorder

struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? "Type shortcut…" : (shortcut?.display ?? "Record Shortcut"))
                    .frame(minWidth: 120)
                    .foregroundStyle(recording || shortcut == nil ? .secondary : .primary)
            }
            if shortcut != nil, !recording {
                Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        NotificationCenter.default.post(name: .shortcutRecording, object: nil, userInfo: ["active": true])
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53, flags.isEmpty { stop(); return nil }                 // Esc cancels
            if event.keyCode == 51 || event.keyCode == 117, flags.isEmpty {             // ⌫ clears
                shortcut = nil; stop(); return nil
            }
            let hasRealModifier = !flags.intersection([.command, .option, .control]).isEmpty
            guard hasRealModifier || KeyNames.isFunctionKey(event.keyCode) else { NSSound.beep(); return nil }
            shortcut = Shortcut(keyCode: Int(event.keyCode),
                                modifiers: KeyNames.carbonModifiers(for: flags),
                                display: KeyNames.symbols(for: flags) + KeyNames.name(for: event.keyCode))
            stop()
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.post(name: .shortcutRecording, object: nil, userInfo: ["active": false])
    }
}
