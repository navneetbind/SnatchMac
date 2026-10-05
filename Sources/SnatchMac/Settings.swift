import Carbon.HIToolbox
import Foundation

struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int // Carbon modifier mask
    var display: String

    static let defaultCapture = Shortcut(keyCode: kVK_ANSI_2, modifiers: cmdKey | shiftKey, display: "⇧⌘2")
}

enum PopupPosition: String, CaseIterable, Identifiable {
    case statusItem, cursor, center
    var id: String { rawValue }
    var title: String {
        switch self {
        case .statusItem: "Menu bar icon"
        case .cursor: "Cursor"
        case .center: "Screen center"
        }
    }
}

extension Notification.Name {
    static let shortcutsChanged = Notification.Name("SnatchMac.shortcutsChanged")
    /// userInfo["active"]: Bool. Global hotkeys are paused while a recorder listens.
    static let shortcutRecording = Notification.Name("SnatchMac.shortcutRecording")
}

enum Settings {
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            "keepLineBreaks": true,
            "fastMode": false,
            "languageCorrection": true,
            "recognitionLanguage": "auto",
            "detectCodes": true,
            "openQRLinks": false,
            "saveHistory": true,
            "historySize": 200,
            "showToast": true,
            "popupPosition": PopupPosition.statusItem.rawValue,
            "showMetadata": false,
            "visibleItems": 10,
            // Extras, all off until switched on in Settings → Extras.
            "spaceToMove": false,
            "cleanupText": false,
            "editBeforeCopy": false,
            "showFilterTabs": false,
            "showOpenFile": false,
            "speakCaptures": false,
        ])
    }

    static var keepLineBreaks: Bool { d.bool(forKey: "keepLineBreaks") }
    static var fastMode: Bool { d.bool(forKey: "fastMode") }
    static var languageCorrection: Bool { d.bool(forKey: "languageCorrection") }
    static var recognitionLanguage: String { d.string(forKey: "recognitionLanguage") ?? "auto" }
    static var detectCodes: Bool { d.bool(forKey: "detectCodes") }
    static var openQRLinks: Bool { d.bool(forKey: "openQRLinks") }
    static var saveHistory: Bool { d.bool(forKey: "saveHistory") }
    static var historySize: Int { max(1, d.integer(forKey: "historySize")) }
    static var showToast: Bool { d.bool(forKey: "showToast") }
    static var popupPosition: PopupPosition {
        PopupPosition(rawValue: d.string(forKey: "popupPosition") ?? "") ?? .statusItem
    }

    static var spaceToMove: Bool { d.bool(forKey: "spaceToMove") }
    static var cleanupText: Bool { d.bool(forKey: "cleanupText") }
    static var editBeforeCopy: Bool { d.bool(forKey: "editBeforeCopy") }
    static var showFilterTabs: Bool { d.bool(forKey: "showFilterTabs") }
    static var showOpenFile: Bool { d.bool(forKey: "showOpenFile") }
    static var speakCaptures: Bool { d.bool(forKey: "speakCaptures") }

    static var captureShortcut: Shortcut? {
        get { shortcut(forKey: "captureShortcut", default: .defaultCapture) }
        set { setShortcut(newValue, forKey: "captureShortcut") }
    }

    static var historyShortcut: Shortcut? {
        get { shortcut(forKey: "historyShortcut", default: nil) }
        set { setShortcut(newValue, forKey: "historyShortcut") }
    }

    /// Optional second shortcut that captures with all lines joined into one.
    static var singleLineShortcut: Shortcut? {
        get { shortcut(forKey: "singleLineShortcut", default: nil) }
        set { setShortcut(newValue, forKey: "singleLineShortcut") }
    }

    // A missing key means "use the default"; empty data means "explicitly cleared".
    private static func shortcut(forKey key: String, default value: Shortcut?) -> Shortcut? {
        guard let data = d.data(forKey: key) else { return value }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    private static func setShortcut(_ shortcut: Shortcut?, forKey key: String) {
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        d.set(data, forKey: key)
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }

    static func resetAll() {
        if let domain = Bundle.main.bundleIdentifier { d.removePersistentDomain(forName: domain) }
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }
}
