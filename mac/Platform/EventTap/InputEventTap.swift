@preconcurrency import CoreGraphics
import Foundation
import OSLog

enum InputEventTapState: Sendable {
    case disabled(String)
    case needsRestart(String)
}

final class InputEventTap: @unchecked Sendable {
    typealias EventHandler = @Sendable (CGEventType, CGEvent) -> Bool
    typealias StateHandler = @MainActor @Sendable (InputEventTapState) -> Void

    private static let healthCheckInterval: TimeInterval = 5
    private static let logger = Logger(
        subsystem: "com.sunkanwei.Meno",
        category: "CrossScreenMouse"
    )

    private let tapLocation: CGEventTapLocation
    private let threadName: String
    private let listenerName: String
    private let eventHandler: EventHandler
    private let stateHandler: StateHandler
    private let stateLock = NSLock()
    private var eventRunLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: Timer?
    private var healthy = false
    private var stopping = false
    private var invalidationReported = false
    private var generation: UInt64 = 0
    private var threadActive = false
    private var threadFinished: DispatchSemaphore?
    private var requestedMask: CGEventMask = 0

    init(
        tapLocation: CGEventTapLocation,
        threadName: String,
        listenerName: String,
        eventHandler: @escaping EventHandler,
        stateHandler: @escaping StateHandler
    ) {
        self.tapLocation = tapLocation
        self.threadName = threadName
        self.listenerName = listenerName
        self.eventHandler = eventHandler
        self.stateHandler = stateHandler
    }

    @MainActor
    var isRunning: Bool {
        stateLock.withCriticalSection { healthy }
    }

    @MainActor
    func start(mask: CGEventMask) -> Bool {
        stop()
        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let generation = stateLock.withCriticalSection { () -> UInt64? in
            guard !threadActive else { return nil }
            self.generation &+= 1
            stopping = false
            healthy = false
            threadActive = true
            threadFinished = finished
            requestedMask = mask
            return self.generation
        }
        guard let generation else { return false }
        let thread = Thread { [self] in
            runEventLoop(ready: ready, generation: generation)
            stateLock.withCriticalSection {
                eventRunLoop = nil
                threadActive = false
                threadFinished = nil
                healthy = false
            }
            finished.signal()
        }
        thread.name = threadName
        thread.qualityOfService = .userInteractive
        thread.start()
        guard ready.wait(timeout: .now() + 1) == .success else {
            invalidateTimedOutStart(generation: generation)
            return false
        }
        return isRunning
    }

    func stop() {
        let state = stateLock.withCriticalSection { () -> (CFRunLoop?, DispatchSemaphore?) in
            generation &+= 1
            stopping = true
            healthy = false
            return (eventRunLoop, threadFinished)
        }
        if let runLoop = state.0 {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
                tearDownOnEventThread()
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        }
        _ = state.1?.wait(timeout: .now() + 1)
    }

    func performCursorTransition(_ transition: @escaping @Sendable () -> Void) {
        let runLoop = stateLock.withCriticalSection { () -> CFRunLoop? in
            guard !stopping else { return nil }
            return eventRunLoop
        }
        guard let runLoop else {
            transition()
            return
        }
        let completed = DispatchSemaphore(value: 0)
        let oneShot = EventTapOneShot()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            oneShot.perform(transition)
            completed.signal()
        }
        CFRunLoopWakeUp(runLoop)
        if completed.wait(timeout: .now() + 0.1) == .timedOut {
            oneShot.perform(transition)
        }
    }

    private func runEventLoop(ready: DispatchSemaphore, generation: UInt64) {
        autoreleasepool {
            let runLoop = CFRunLoopGetCurrent()
            let mayStart = stateLock.withCriticalSection { () -> Bool in
                guard self.generation == generation, !stopping else { return false }
                eventRunLoop = runLoop
                return true
            }
            guard mayStart else {
                ready.signal()
                return
            }
            let eventMask = stateLock.withCriticalSection { requestedMask }
            let userInfo = Unmanaged.passUnretained(self).toOpaque()
            guard let eventTap = CGEvent.tapCreate(
                tap: tapLocation,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: Self.callback,
                userInfo: userInfo
            ) else {
                finishFailedStart(ready: ready)
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            self.eventTap = eventTap
            runLoopSource = source
            CFRunLoopAddSource(runLoop, source, .commonModes)

            let timer = Timer(timeInterval: Self.healthCheckInterval, repeats: true) {
                [weak self] _ in self?.checkHealthOnEventThread()
            }
            timer.tolerance = 1
            healthTimer = timer
            RunLoop.current.add(timer, forMode: .common)

            CGEvent.tapEnable(tap: eventTap, enable: true)
            let started = CFMachPortIsValid(eventTap) && CGEvent.tapIsEnabled(tap: eventTap)
            stateLock.withCriticalSection {
                healthy = started && self.generation == generation && !stopping
            }
            if !started || !stateLock.withCriticalSection({
                self.generation == generation && !stopping
            }) {
                tearDownOnEventThread()
                stateLock.withCriticalSection { eventRunLoop = nil }
                ready.signal()
                return
            }
            ready.signal()
            CFRunLoopRun()
        }
    }

    private func invalidateTimedOutStart(generation: UInt64) {
        let runLoop = stateLock.withCriticalSection { () -> CFRunLoop? in
            guard self.generation == generation else { return nil }
            self.generation &+= 1
            stopping = true
            healthy = false
            return eventRunLoop
        }
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            tearDownOnEventThread()
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func finishFailedStart(ready: DispatchSemaphore) {
        stateLock.withCriticalSection {
            healthy = false
            eventRunLoop = nil
        }
        ready.signal()
    }

    private func tearDownOnEventThread() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        invalidationReported = false
        stateLock.withCriticalSection { healthy = false }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        autoreleasepool {
            switch type {
            case .tapDisabledByTimeout:
                _ = eventHandler(type, event)
                recoverDisabledTap(reason: "系统因处理超时停用了\(listenerName)")
                return Unmanaged.passUnretained(event)
            case .tapDisabledByUserInput:
                _ = eventHandler(type, event)
                recoverDisabledTap(reason: "系统因输入状态停用了\(listenerName)")
                return Unmanaged.passUnretained(event)
            default:
                return eventHandler(type, event) ? nil : Unmanaged.passUnretained(event)
            }
        }
    }

    private func recoverDisabledTap(reason: String) {
        notify(.disabled(reason))
        guard let eventTap, CFMachPortIsValid(eventTap) else {
            reportRestartNeeded(reason)
            return
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        let recovered = CGEvent.tapIsEnabled(tap: eventTap)
        let active = recordHealth(recovered)
        guard active || !recovered else { return }
        if !recovered {
            reportRestartNeeded(reason)
        }
    }

    private func checkHealthOnEventThread() {
        guard let eventTap, CFMachPortIsValid(eventTap) else {
            reportRestartNeeded("\(listenerName)端口已经失效")
            return
        }
        guard !CGEvent.tapIsEnabled(tap: eventTap) else {
            _ = recordHealth(true)
            return
        }
        recoverDisabledTap(reason: "健康检查发现\(listenerName)被停用")
    }

    private func reportRestartNeeded(_ reason: String) {
        let shouldReport = stateLock.withCriticalSection { () -> Bool in
            healthy = false
            guard !stopping, !invalidationReported else { return false }
            invalidationReported = true
            return true
        }
        guard shouldReport else { return }
        Self.logger.error("\(reason, privacy: .public)，需要重建监听")
        notify(.needsRestart(reason))
    }

    private func notify(_ state: InputEventTapState) {
        let notificationGeneration = stateLock.withCriticalSection { () -> UInt64? in
            guard !stopping, eventRunLoop != nil else { return nil }
            return generation
        }
        guard let notificationGeneration else { return }
        Task { @MainActor [weak self, stateHandler] in
            guard self?.shouldDeliverNotification(generation: notificationGeneration) == true else {
                return
            }
            stateHandler(state)
        }
    }

    private func recordHealth(_ value: Bool) -> Bool {
        stateLock.withCriticalSection {
            let active = value && !stopping && eventRunLoop != nil
            healthy = active
            return active
        }
    }

    private func shouldDeliverNotification(generation: UInt64) -> Bool {
        stateLock.withCriticalSection {
            self.generation == generation && !stopping && eventRunLoop != nil
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<InputEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        return owner.handle(type: type, event: event)
    }
}
