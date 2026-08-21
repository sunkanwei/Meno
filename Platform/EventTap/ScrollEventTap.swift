@preconcurrency import CoreGraphics
import Foundation
import OSLog

enum ScrollEventTapState: Sendable {
    case recovered(String)
    case needsRestart(String)
}

final class ScrollEventTap: @unchecked Sendable {
    typealias EventHandler = @Sendable (CGEvent) -> Void
    typealias StateHandler = @MainActor @Sendable (ScrollEventTapState) -> Void

    private static let healthCheckInterval: TimeInterval = 5
    private static let logger = Logger(subsystem: "com.sunkanwei.Meno", category: "Scrolling")

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

    init(
        eventHandler: @escaping EventHandler,
        stateHandler: @escaping StateHandler
    ) {
        self.eventHandler = eventHandler
        self.stateHandler = stateHandler
    }

    @MainActor
    var isRunning: Bool {
        stateLock.withCriticalSection { healthy }
    }

    @MainActor
    func start() -> Bool {
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
        thread.name = "com.sunkanwei.Meno.scrolling-events"
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

            let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            let userInfo = Unmanaged.passUnretained(self).toOpaque()
            guard let eventTap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .tailAppendEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
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

            let timer = Timer(
                timeInterval: Self.healthCheckInterval,
                repeats: true
            ) { [weak self] _ in
                self?.checkHealthOnEventThread()
            }
            timer.tolerance = 1
            healthTimer = timer
            RunLoop.current.add(timer, forMode: .common)

            CGEvent.tapEnable(tap: eventTap, enable: true)
            let started = CFMachPortIsValid(eventTap) && CGEvent.tapIsEnabled(tap: eventTap)
            stateLock.withCriticalSection {
                healthy = started && self.generation == generation && !stopping
            }
            ready.signal()

            guard started,
                  stateLock.withCriticalSection({ self.generation == generation && !stopping }) else {
                tearDownOnEventThread()
                stateLock.withCriticalSection {
                    eventRunLoop = nil
                }
                return
            }

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
                recoverDisabledTap(reason: "系统因处理超时停用了滚轮监听")
            case .tapDisabledByUserInput:
                recoverDisabledTap(reason: "系统因用户输入状态停用了滚轮监听")
            default:
                eventHandler(event)
            }
            return Unmanaged.passUnretained(event)
        }
    }

    private func recoverDisabledTap(reason: String) {
        guard let eventTap, CFMachPortIsValid(eventTap) else {
            reportRestartNeeded(reason)
            return
        }

        CGEvent.tapEnable(tap: eventTap, enable: true)
        let recovered = CGEvent.tapIsEnabled(tap: eventTap)
        let active = recordHealth(recovered)
        guard active || !recovered else { return }
        if active {
            Self.logger.error("\(reason, privacy: .public)，已自动恢复")
            notify(.recovered(reason))
        } else {
            reportRestartNeeded(reason)
        }
    }

    private func checkHealthOnEventThread() {
        guard let eventTap, CFMachPortIsValid(eventTap) else {
            reportRestartNeeded("滚轮监听端口已经失效")
            return
        }
        guard !CGEvent.tapIsEnabled(tap: eventTap) else {
            _ = recordHealth(true)
            return
        }

        CGEvent.tapEnable(tap: eventTap, enable: true)
        let recovered = CGEvent.tapIsEnabled(tap: eventTap)
        let active = recordHealth(recovered)
        guard active || !recovered else { return }
        if active {
            let reason = "健康检查发现滚轮监听被静默停用"
            Self.logger.error("\(reason, privacy: .public)，已自动恢复")
            notify(.recovered(reason))
        } else {
            reportRestartNeeded("健康检查无法重新启用滚轮监听")
        }
    }

    private func reportRestartNeeded(_ reason: String) {
        let shouldReport = stateLock.withCriticalSection { () -> Bool in
            healthy = false
            guard !stopping, !invalidationReported else { return false }
            invalidationReported = true
            return true
        }
        guard shouldReport else { return }

        Self.logger.error("\(reason, privacy: .public)，准备重建监听")
        notify(.needsRestart(reason))
    }

    private func notify(_ state: ScrollEventTapState) {
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
        let owner = Unmanaged<ScrollEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        return owner.handle(type: type, event: event)
    }
}
