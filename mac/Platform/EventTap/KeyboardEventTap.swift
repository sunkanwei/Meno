@preconcurrency import CoreGraphics

@MainActor
final class KeyboardEventTap {
    typealias EventHandler = (CGEventType, CGEvent) -> CGEvent?

    private let eventHandler: EventHandler
    private let disabledHandler: (_ recovered: Bool) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(
        eventHandler: @escaping EventHandler,
        disabledHandler: @escaping (_ recovered: Bool) -> Void
    ) {
        self.eventHandler = eventHandler
        self.disabledHandler = disabledHandler
    }

    var isRunning: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    func start(for processIdentifier: Int32) -> Bool {
        stop()

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let eventTap = CGEvent.tapCreateForPid(
            pid: processIdentifier,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: userInfo
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        self.eventTap = eventTap
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        if !CGEvent.tapIsEnabled(tap: eventTap) {
            stop()
            return false
        }
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            guard let eventTap else {
                disabledHandler(false)
                return Unmanaged.passUnretained(event)
            }

            CGEvent.tapEnable(tap: eventTap, enable: true)
            let recovered = CGEvent.tapIsEnabled(tap: eventTap)
            disabledHandler(recovered)
            if !recovered {
                DispatchQueue.main.async { [weak self] in self?.stop() }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let result = eventHandler(type, event) else { return nil }
        return Unmanaged.passUnretained(result)
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<KeyboardEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        return MainActor.assumeIsolated {
            owner.handle(type: type, event: event)
        }
    }
}
