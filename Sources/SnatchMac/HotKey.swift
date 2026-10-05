import Carbon.HIToolbox
import Foundation

/// Global shortcut via Carbon. Needs no Accessibility permission.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32
    private(set) var registered = false

    init(keyCode: Int, modifiers: Int, id: UInt32 = 1, handler: @escaping () -> Void) {
        self.id = id
        HotKey.handlers[id] = handler
        HotKey.installHandlerIfNeeded()
        let hkID = EventHotKeyID(signature: OSType(0x534E_4D43), id: id) // 'SNMC'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        registered = status == noErr
        if !registered { NSLog("SnatchMac: RegisterEventHotKey failed (\(status))") }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if let handler = HotKey.handlers[hk.id] {
                DispatchQueue.main.async { handler() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
