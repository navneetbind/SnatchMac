import AppKit
import AVFoundation
import PDFKit
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []
    private let selection = SelectionController()
    private let speech = AVSpeechSynthesizer()
    private lazy var historyPanel: HistoryPanelController = {
        let controller = HistoryPanelController()
        controller.actions = .init(
            capture: { [weak self] in self?.startCapture() },
            readClipboard: { [weak self] in self?.readClipboard() },
            settings: { [weak self] in self?.openSettings() },
            openFile: { [weak self] in self?.openFile() },
            copy: { [weak self] in self?.copyFromHistory($0) }
        )
        return controller
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Registered early so a snatchmac:// URL that launched us isn't missed.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        let info = Bundle.main.infoDictionary
        Log.write("launch v\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?")) at \(Bundle.main.bundlePath), preflight=\(CGPreflightScreenCaptureAccess())")
        setUpStatusItem()
        Recognizer.warmUp()
        _ = HistoryStore.shared

        registerHotKeys()
        NotificationCenter.default.addObserver(forName: .shortcutsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKeys() }
        }
        NotificationCenter.default.addObserver(forName: .shortcutRecording, object: nil, queue: .main) { [weak self] note in
            let active = note.userInfo?["active"] as? Bool == true
            MainActor.assumeIsolated { if active { self?.hotKeys = [] } else { self?.registerHotKeys() } }
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "SnatchMac")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleHistory)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc func toggleHistory() {
        historyPanel.toggle(from: statusItem.button)
    }

    func openSettings() {
        SettingsWindowController.shared.show()
    }

    private func registerHotKeys() {
        hotKeys = [] // unregisters the old ones
        if let s = Settings.captureShortcut {
            let hk = HotKey(keyCode: s.keyCode, modifiers: s.modifiers, id: 1) { [weak self] in self?.startCapture() }
            Log.write("hotkey \(s.display) registered=\(hk.registered)")
            if !hk.registered { Toast.shared.show("\(s.display) is taken by another app", symbol: "exclamationmark.triangle") }
            hotKeys.append(hk)
        }
        if let s = Settings.historyShortcut {
            let hk = HotKey(keyCode: s.keyCode, modifiers: s.modifiers, id: 2) { [weak self] in self?.toggleHistory() }
            if !hk.registered { Toast.shared.show("\(s.display) is taken by another app", symbol: "exclamationmark.triangle") }
            hotKeys.append(hk)
        }
        if let s = Settings.singleLineShortcut {
            let hk = HotKey(keyCode: s.keyCode, modifiers: s.modifiers, id: 3) { [weak self] in self?.startCapture(singleLine: true) }
            if !hk.registered { Toast.shared.show("\(s.display) is taken by another app", symbol: "exclamationmark.triangle") }
            hotKeys.append(hk)
        }
    }

    // MARK: - Capture

    @objc func startCapture() { startCapture(singleLine: false) }

    func startCapture(singleLine: Bool) {
        Log.write("startCapture singleLine=\(singleLine) overlayActive=\(selection.isActive)")
        guard !selection.isActive else { return }
        historyPanel.close()
        Task { @MainActor in
            let permitted = await hasScreenRecordingPermission()
            Log.write("permission check -> \(permitted)")
            guard permitted else {
                showPermissionAlert()
                return
            }
            selection.begin { [weak self] result in
                Log.write(result.map { "selection \($0.rect) on \($0.screen.localizedName) scale=\($0.screen.backingScaleFactor) from=\($0.sourceApp ?? "-")" } ?? "selection cancelled")
                guard let self, let result else { return }
                Task { @MainActor in await self.captureAndRecognize(result, singleLine: singleLine) }
            }
        }
    }

    @MainActor
    private func captureAndRecognize(_ selection: Selection, singleLine: Bool) async {
        do {
            Log.write("capture start")
            let image = try await ScreenGrabber.capture(rect: selection.rect, on: selection.screen)
            Log.write("capture ok \(image.width)x\(image.height)")
            var options = Recognizer.Options()
            if singleLine { options.keepLineBreaks = false }
            await recognize(image, source: selection.sourceApp, options: options,
                            edit: Settings.editBeforeCopy && selection.optionHeld)
        } catch {
            Log.write("capture FAILED: \(error) (\((error as NSError).domain) \((error as NSError).code))")
            Toast.shared.show("Capture failed", detail: error.localizedDescription, symbol: "exclamationmark.triangle")
        }
    }

    @objc func readClipboard() {
        guard let image = NSImage(pasteboard: .general) else {
            Toast.shared.show("No image on the clipboard", symbol: "photo")
            return
        }
        // Vector images (PDF) rasterise at their point size, too small for OCR, so render them larger.
        let isVector = image.representations.contains { !($0 is NSBitmapImageRep) }
        var rect = CGRect(origin: .zero, size: isVector ? CGSize(width: image.size.width * 3, height: image.size.height * 3) : image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            Toast.shared.show("Couldn't read that image", symbol: "photo")
            return
        }
        Task { @MainActor in await recognize(cg, source: "Clipboard") }
    }

    @MainActor
    private func recognize(_ image: CGImage, source: String?,
                           options: Recognizer.Options = .init(), edit: Bool = false) async {
        do {
            let result = try await Recognizer.recognize(image, options: options)
            Log.write(result.map { "ocr \($0.kind) \($0.text.count) chars" } ?? "ocr found nothing")
            guard let result else {
                Toast.shared.show("No text found", symbol: "text.magnifyingglass")
                return
            }
            let kind: Capture.Kind = switch result.kind {
            case .text: .text
            case .link: .link
            case .code: .code
            }
            if edit {
                EditorController.shared.open(text: result.text) { [weak self] edited in
                    let editedKind: Capture.Kind = kind == .code ? .code : (Recognizer.isSingleURL(edited) ? .link : .text)
                    self?.deliver(edited, kind: editedKind, source: source)
                }
            } else {
                deliver(result.text, kind: kind, source: source)
            }
        } catch {
            Log.write("ocr FAILED: \(error)")
            Toast.shared.show("Recognition failed", detail: error.localizedDescription, symbol: "exclamationmark.triangle")
        }
    }

    /// Clipboard, history, notification, and the optional extras.
    private func deliver(_ text: String, kind: Capture.Kind, source: String?) {
        Log.write("copied \(kind) to clipboard")
        copyToPasteboard(text)
        HistoryStore.shared.add(text, kind: kind, source: source)
        announce(kind: kind, text: text)

        if Settings.speakCaptures {
            speech.stopSpeaking(at: .immediate)
            speech.speak(AVSpeechUtterance(string: text))
        }
        if kind == .code, Settings.openQRLinks, let url = URL(string: text),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Open image or PDF (Extras)

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image or PDF to read"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let source = url.lastPathComponent

        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else {
                Toast.shared.show("Couldn't open that PDF", symbol: "doc")
                return
            }
            // A PDF with a real text layer doesn't need OCR at all.
            if let text = document.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                deliver(text, kind: Recognizer.isSingleURL(text) ? .link : .text, source: source)
                return
            }
            Task { @MainActor in await recognizePDF(document, source: source) }
            return
        }

        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Toast.shared.show("Couldn't read that image", symbol: "photo")
            return
        }
        Task { @MainActor in await recognize(cg, source: source) }
    }

    @MainActor
    private func recognizePDF(_ document: PDFDocument, source: String) async {
        let pageCount = min(document.pageCount, 100)
        Toast.shared.show("Reading \(pageCount) page\(pageCount == 1 ? "" : "s")…", symbol: "doc.text.magnifyingglass")
        var pages: [String] = []
        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let image = page.thumbnail(of: CGSize(width: bounds.width * 3, height: bounds.height * 3), for: .mediaBox)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let result = try? await Recognizer.recognize(cg) else { continue }
            pages.append(result.text)
        }
        guard !pages.isEmpty else {
            Toast.shared.show("No text found", symbol: "text.magnifyingglass")
            return
        }
        deliver(pages.joined(separator: "\n\n"), kind: .text, source: source)
    }

    private func copyFromHistory(_ capture: Capture) {
        copyToPasteboard(capture.text)
        HistoryStore.shared.touch(capture)
        announce(kind: capture.kind, text: capture.text)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func announce(kind: Capture.Kind, text: String) {
        guard Settings.showToast else { return }
        switch kind {
        case .text: Toast.shared.show("Copied", detail: text)
        case .link: Toast.shared.show("Link copied", detail: text, symbol: "link")
        case .code: Toast.shared.show("Code copied", detail: text, symbol: "qrcode")
        }
    }

    // MARK: - Permission

    /// CGPreflightScreenCaptureAccess can report "no" after access was granted, so fall back to
    /// asking ScreenCaptureKit itself, which is what the capture actually uses.
    private func hasScreenRecordingPermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            Log.write("SCShareableContent failed: \(error) (\((error as NSError).domain) \((error as NSError).code))")
            return false
        }
    }

    private func showPermissionAlert() {
        // Adds SnatchMac to the Screen Recording list (and prompts the first time).
        CGRequestScreenCaptureAccess()

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "SnatchMac needs Screen Recording access"
        alert.informativeText = "It only reads the area you drag over, at the moment you let go. Turn SnatchMac on in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen SnatchMac."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - URL scheme

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        switch url.host?.lowercased() {
        case "capture": startCapture()
        case "clipboard": readClipboard()
        case "history": toggleHistory()
        case "settings": openSettings()
        case "snapshot": snapshotWindows(url)
        default: break
        }
    }

    /// Debug aid: snatchmac://snapshot?dir=/path writes PNGs of our visible windows.
    /// Off unless `defaults write com.navneetbind.snatchmac debugSnapshots -bool YES`.
    private func snapshotWindows(_ url: URL) {
        guard UserDefaults.standard.bool(forKey: "debugSnapshots"),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let dir = query.first(where: { $0.name == "dir" })?.value else { return }
        switch query.first(where: { $0.name == "show" })?.value {
        case "history": historyPanel.show(from: statusItem.button)
        case "settings":
            openSettings()
            if let tab = query.first(where: { $0.name == "tab" })?.value.flatMap(Int.init),
               let tabs = SettingsWindowController.shared.window?.contentViewController as? NSTabViewController {
                tabs.selectedTabViewItemIndex = tab
            }
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.writeSnapshots(to: dir) }
    }

    private func writeSnapshots(to dir: String) {
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = "\(i)-\(type(of: window))-\(window.title.isEmpty ? "untitled" : window.title).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }
}
