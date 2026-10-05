import AppKit

struct Selection {
    let screen: NSScreen
    /// In the overlay window's coordinates (points, bottom-left origin).
    let rect: CGRect
    /// The app that was frontmost when the capture started.
    let sourceApp: String?
    /// ⌥ was held when the drag ended (Extras → edit before copying).
    let optionHeld: Bool
}

/// Full-screen crosshair overlay on every display.
final class SelectionController {
    private var windows: [OverlayWindow] = []
    private var completion: (Selection?) -> Void = { _ in }
    private var previousApp: NSRunningApplication?

    var isActive: Bool { !windows.isEmpty }

    func begin(completion: @escaping (Selection?) -> Void) {
        guard !isActive else { return }
        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication

        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onDone = { [weak self] rect, flags in self?.finish(screen: screen, rect: rect, flags: flags) }
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
        }

        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        let keyWindow = windows.first { $0.frame.contains(mouse) } ?? windows.first
        keyWindow?.makeKey()
        keyWindow?.makeFirstResponder(keyWindow?.contentView)
        NSCursor.crosshair.set()
    }

    private func finish(screen: NSScreen, rect: CGRect?, flags: NSEvent.ModifierFlags) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        // Hand focus back so ⌘V lands where the user was.
        let source = previousApp?.localizedName
        previousApp?.activate()
        previousApp = nil
        let done = completion
        completion = { _ in }
        done(rect.map { Selection(screen: screen, rect: $0, sourceApp: source, optionHeld: flags.contains(.option)) })
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
    var onDone: (CGRect?, NSEvent.ModifierFlags) -> Void = { _, _ in }
    private var start: NSPoint?
    private var current: NSPoint?
    /// Space held mid-drag moves the whole box instead of resizing it (Extras).
    private var moving = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    private func clamp(_ p: NSPoint) -> NSPoint {
        NSPoint(x: min(max(p.x, 0), bounds.maxX), y: min(max(p.y, 0), bounds.maxY))
    }

    override func mouseDown(with event: NSEvent) {
        start = clamp(convert(event.locationInWindow, from: nil))
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamp(convert(event.locationInWindow, from: nil))
        if moving, let start, let current, let rect = selection {
            // Shift both corners by the mouse delta, keeping the box on screen.
            let dx = min(max(point.x - current.x, -rect.minX), bounds.maxX - rect.maxX)
            let dy = min(max(point.y - current.y, -rect.minY), bounds.maxY - rect.maxY)
            self.start = NSPoint(x: start.x + dx, y: start.y + dy)
            self.current = NSPoint(x: current.x + dx, y: current.y + dy)
        } else {
            current = point
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if !moving { current = clamp(convert(event.locationInWindow, from: nil)) }
        guard let rect = selection, rect.width >= 4, rect.height >= 4 else {
            // A plain click without a drag cancels.
            onDone(nil, [])
            return
        }
        onDone(rect.integral, event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onDone(nil, [])                                         // Esc
        case 49 where Settings.spaceToMove && start != nil: moving = true // Space
        default: break
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { moving = false }
    }

    override func rightMouseDown(with event: NSEvent) { onDone(nil, []) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.22).setFill()
        bounds.fill()

        guard let rect = selection, rect.width > 0, rect.height > 0 else { return }
        NSColor.clear.setFill()
        rect.fill(using: .copy)

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        drawSizeLabel(for: rect)
    }

    private func drawSizeLabel(for rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let pad = CGSize(width: 6, height: 3)
        var box = CGRect(x: rect.maxX - size.width - pad.width * 2,
                         y: rect.minY - size.height - pad.height * 2 - 6,
                         width: size.width + pad.width * 2,
                         height: size.height + pad.height * 2)
        if box.minY < 0 { box.origin.y = rect.minY + 6 }
        if box.minX < 0 { box.origin.x = rect.minX }
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: box.minX + pad.width, y: box.minY + pad.height), withAttributes: attrs)
    }
}
