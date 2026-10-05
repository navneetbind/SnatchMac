import AppKit

struct Capture: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, link, code }

    var id = UUID()
    var text: String
    var kind: Kind
    var date: Date
    var source: String?
    var pinned = false

    var title: String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? text
    }

    var symbol: String {
        switch kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .code: "qrcode"
        }
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    /// Pinned first, then newest first.
    @Published private(set) var items: [Capture] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnatchMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    var folderURL: URL { fileURL.deletingLastPathComponent() }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Capture].self, from: data) {
            items = saved
        }
    }

    func add(_ text: String, kind: Capture.Kind, source: String?) {
        guard Settings.saveHistory else { return }
        var capture = Capture(text: text, kind: kind, date: Date(), source: source)
        if let existing = items.firstIndex(where: { $0.text == text }) {
            capture.pinned = items[existing].pinned
            items.remove(at: existing)
        }
        items.append(capture)
        commit()
    }

    /// Re-copying an item moves it back to the top, like Maccy.
    func touch(_ capture: Capture) {
        guard let i = items.firstIndex(where: { $0.id == capture.id }) else { return }
        items[i].date = Date()
        commit()
    }

    func togglePin(_ capture: Capture) {
        guard let i = items.firstIndex(where: { $0.id == capture.id }) else { return }
        items[i].pinned.toggle()
        commit()
    }

    func delete(_ capture: Capture) {
        items.removeAll { $0.id == capture.id }
        commit()
    }

    /// Clears unpinned items.
    func clear() {
        items.removeAll { !$0.pinned }
        commit()
    }

    func clearAll() {
        items.removeAll()
        commit()
    }

    func trim() { commit() }

    private func commit() {
        let pinned = items.filter(\.pinned).sorted { $0.date > $1.date }
        let rest = items.filter { !$0.pinned }.sorted { $0.date > $1.date }.prefix(Settings.historySize)
        items = pinned + rest
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
