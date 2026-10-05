import AppKit
import SwiftUI

/// Extras → "Hold ⌥ when releasing to edit before copying": the recognized text opens
/// here, and nothing reaches the clipboard until Copy.
@MainActor
final class EditorController: NSObject, NSWindowDelegate {
    static let shared = EditorController()

    private var window: NSPanel?
    private var previousApp: NSRunningApplication?

    func open(text: String, onCopy: @escaping (String) -> Void) {
        window?.close()
        previousApp = NSWorkspace.shared.frontmostApplication

        let model = EditorModel(text: text)
        let view = EditorView(model: model,
                              copy: { [weak self] in onCopy(model.text); self?.window?.close() },
                              cancel: { [weak self] in self?.window?.close() })
        let panel = NSPanel(contentViewController: NSHostingController(rootView: view))
        panel.styleMask = [.titled, .closable, .resizable]
        panel.title = "Edit Before Copying"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        window = panel

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        if previousApp?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp?.activate() }
        previousApp = nil
    }
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var text: String
    init(text: String) { self.text = text }
}

private struct EditorView: View {
    @ObservedObject var model: EditorModel
    let copy: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            TextEditor(text: $model.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .frame(minWidth: 480, minHeight: 220)

            HStack {
                Button("Join Lines") {
                    model.text = model.text
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                }
                Button("Clean Up") {
                    model.text = TextCleanup.merge(model.text.components(separatedBy: .newlines)).joined(separator: "\n")
                }
                .help("Rejoin hyphenated words and merge wrapped lines")
                Spacer()
                Text("\(model.text.count) characters")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Copy", action: copy)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }
}
