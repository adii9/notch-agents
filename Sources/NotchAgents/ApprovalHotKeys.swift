import Carbon.HIToolbox

/// ⌥⌘Y allows and ⌥⌘N denies the permission card on the island, from any app.
/// The keys are only registered while a card is waiting, so they're never taken from other apps otherwise.
/// Carbon hot keys need no Accessibility permission and don't reach the app in front.
@MainActor
final class ApprovalHotKeys {
    static let allowLabel = "⌥⌘Y"
    static let denyLabel = "⌥⌘N"

    private let onPress: (_ allow: Bool) -> Void
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    init(onPress: @escaping (_ allow: Bool) -> Void) {
        self.onPress = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<ApprovalHotKeys>.fromOpaque(userData!).takeUnretainedValue()
            MainActor.assumeIsolated { me.onPress(id.id == 1) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    var isEnabled: Bool { !refs.isEmpty }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        if on {
            for (id, key) in [(UInt32(1), kVK_ANSI_Y), (UInt32(2), kVK_ANSI_N)] {
                var ref: EventHotKeyRef?
                let hkID = EventHotKeyID(signature: OSType(0x4E414750) /* NAGP */, id: id)
                if RegisterEventHotKey(UInt32(key), UInt32(cmdKey | optionKey), hkID,
                                       GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                    refs.append(ref)
                }
            }
        } else {
            refs.forEach { UnregisterEventHotKey($0) }
            refs.removeAll()
        }
    }
}
