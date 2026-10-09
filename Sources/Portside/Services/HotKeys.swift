import Carbon.HIToolbox
import Foundation

// System-wide shortcuts through Carbon's RegisterEventHotKey: it needs no
// Accessibility permission and only ever sees the registered combinations.
@MainActor
enum HotKeys {
    enum Action: UInt32 {
        case togglePanel = 1
        case reopenLastClosed = 2
    }

    private static let signature: OSType = 0x5054_5344 // "PTSD"
    private static var handlers: [Action: () -> Void] = [:]
    private static var references: [EventHotKeyRef] = []
    private static var eventHandler: EventHandlerRef?

    static var isEnabled: Bool {
        get { Defaults.bool("globalShortcuts", default: false) }
        set {
            UserDefaults.standard.set(newValue, forKey: "globalShortcuts")
            newValue ? register() : unregister()
        }
    }

    static func install(_ actions: [Action: () -> Void]) {
        handlers = actions
        if isEnabled { register() }
    }

    private static func register() {
        unregister()
        installEventHandler()
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        for (action, key) in [(Action.togglePanel, kVK_ANSI_P), (.reopenLastClosed, kVK_ANSI_T)] {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: action.rawValue)
            if RegisterEventHotKey(UInt32(key), modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr,
               let reference {
                references.append(reference)
            }
        }
    }

    private static func unregister() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
    }

    private static func installEventHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let raw = id.id
            Task { @MainActor in
                if let action = Action(rawValue: raw) { HotKeys.handlers[action]?() }
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
