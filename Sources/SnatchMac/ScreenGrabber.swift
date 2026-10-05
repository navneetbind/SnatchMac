import AppKit
import ScreenCaptureKit

enum ScreenGrabber {
    enum Failure: LocalizedError {
        case displayNotFound
        var errorDescription: String? { "Couldn't find that display" }
    }

    /// `rect` is in the overlay window's coordinates (points, bottom-left origin),
    /// and the overlay window covers `screen.frame` exactly.
    static func capture(rect: CGRect, on screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        Log.write("shareable content: \(content.displays.count) displays, \(content.applications.count) apps")
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = screen.deviceDescription[key] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw Failure.displayNotFound }

        // Leave our own overlay out of the shot, in case it hasn't left the compositor yet.
        let pid = ProcessInfo.processInfo.processIdentifier
        let me = content.applications.filter { $0.processID == pid }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        // ScreenCaptureKit wants display-local points with a top-left origin.
        config.sourceRect = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY,
                                   width: rect.width, height: rect.height)
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best

        Log.write("screenshot sourceRect=\(config.sourceRect) px=\(config.width)x\(config.height) display=\(display.displayID) \(display.width)x\(display.height)")
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
