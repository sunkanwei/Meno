import CoreFoundation
import CoreGraphics
import Darwin
import Foundation

// Created on the main actor, then used exclusively by the scrolling event thread.
final class HIDScrollEventResolver: @unchecked Sendable {
    private static let scrollYField = UInt32((6 << 16) | 1)
    private static let unknownRetryInterval: TimeInterval = 1

    private struct CachedSource {
        let source: ScrollInputSource
        let retryAfter: TimeInterval?
    }

    private let topologyLock = NSLock()
    private let symbols: HIDEventSymbols?
    private var sourceCache: [UInt64: CachedSource] = [:]
    private var topologyGeneration = 0
    private var consumedTopologyGeneration = 0

    @MainActor
    init() {
        guard let symbols = HIDEventSymbols() else {
            self.symbols = nil
            return
        }
        self.symbols = symbols
        symbols.startObservation { [weak self] in
            self?.topologyDidChange()
        }
    }

    var isAvailable: Bool { symbols != nil }

    @MainActor
    func stop() {
        symbols?.stopObservation()
    }

    func context(for event: CGEvent) -> HIDScrollEventContext? {
        guard let symbols,
              let eventPointer = symbols.copyIOHIDEvent(
                  Unmanaged.passUnretained(event).toOpaque()
              ) else {
            return nil
        }

        let senderID = symbols.getSenderID(eventPointer)
        let source = resolveSource(senderID: senderID)
        return HIDScrollEventContext(eventPointer: eventPointer, source: source)
    }

    func embeddedVertical(in context: HIDScrollEventContext) -> Double {
        guard let symbols else { return 0 }
        return symbols.getFloatValue(
            context.eventPointer,
            Self.scrollYField
        )
    }

    func setEmbeddedVertical(_ value: Double, in context: HIDScrollEventContext) {
        guard let symbols else { return }
        symbols.setFloatValue(
            context.eventPointer,
            Self.scrollYField,
            value
        )
    }

    private func resolveSource(senderID: UInt64) -> ScrollInputSource {
        guard senderID != 0 else { return .unknown }
        refreshCacheForTopologyChanges()
        if let cached = sourceCache[senderID] {
            guard let retryAfter = cached.retryAfter else { return cached.source }
            if ProcessInfo.processInfo.systemUptime < retryAfter {
                return cached.source
            }
        }
        let now = ProcessInfo.processInfo.systemUptime

        guard let descriptor = symbols?.deviceDescriptor(senderID: senderID) else {
            cache(.unknown, senderID: senderID, now: now)
            return .unknown
        }
        let source = ScrollInputSourceClassifier.classify(descriptor)
        cache(source, senderID: senderID, now: now)
        return source
    }

    private func cache(
        _ source: ScrollInputSource,
        senderID: UInt64,
        now: TimeInterval
    ) {
        sourceCache[senderID] = CachedSource(
            source: source,
            retryAfter: source == .unknown ? now + Self.unknownRetryInterval : nil
        )
    }

    private func topologyDidChange() {
        topologyLock.lock()
        topologyGeneration &+= 1
        topologyLock.unlock()
    }

    private func refreshCacheForTopologyChanges() {
        topologyLock.lock()
        let generation = topologyGeneration
        topologyLock.unlock()
        guard generation != consumedTopologyGeneration else { return }

        sourceCache.removeAll(keepingCapacity: true)
        consumedTopologyGeneration = generation
    }
}

final class HIDScrollEventContext {
    fileprivate let eventPointer: UnsafeRawPointer
    let source: ScrollInputSource

    fileprivate init(eventPointer: UnsafeRawPointer, source: ScrollInputSource) {
        self.eventPointer = eventPointer
        self.source = source
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(eventPointer).release()
    }
}

private final class HIDEventSymbols {
    typealias ServiceClientBlock = @convention(block) (
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        UnsafeRawPointer?
    ) -> Void
    typealias CopyIOHIDEvent = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?
    typealias GetSenderID = @convention(c) (UnsafeRawPointer) -> UInt64
    typealias GetFloatValue = @convention(c) (UnsafeRawPointer, UInt32) -> Double
    typealias SetFloatValue = @convention(c) (UnsafeRawPointer, UInt32, Double) -> Void
    typealias CreateEventSystemClient = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
    typealias SetMatchingMultiple = @convention(c) (UnsafeRawPointer, CFArray) -> Void
    typealias RegisterDeviceMatchingBlock = @convention(c) (
        UnsafeRawPointer,
        ServiceClientBlock,
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?
    ) -> Void
    typealias UnregisterDeviceMatchingBlock = @convention(c) (UnsafeRawPointer) -> Void
    typealias ScheduleWithDispatchQueue = @convention(c) (UnsafeRawPointer, DispatchQueue) -> Void
    typealias CopyServices = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFArray>?
    typealias CopyService = @convention(c) (UnsafeRawPointer, UInt64) -> UnsafeRawPointer?
    typealias RegisterRemovalBlock = @convention(c) (
        UnsafeRawPointer,
        ServiceClientBlock,
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?
    ) -> Void
    typealias CopyServiceProperty = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeRawPointer?

    let copyIOHIDEvent: CopyIOHIDEvent
    let getSenderID: GetSenderID
    let getFloatValue: GetFloatValue
    let setFloatValue: SetFloatValue
    private let setMatchingMultiple: SetMatchingMultiple
    private let registerDeviceMatchingBlock: RegisterDeviceMatchingBlock
    private let unregisterDeviceMatchingBlock: UnregisterDeviceMatchingBlock
    private let scheduleWithDispatchQueue: ScheduleWithDispatchQueue
    private let unscheduleFromDispatchQueue: ScheduleWithDispatchQueue
    private let copyServices: CopyServices
    private let copyService: CopyService
    private let registerRemovalBlock: RegisterRemovalBlock
    private let copyServiceProperty: CopyServiceProperty

    private let coreGraphicsHandle: UnsafeMutableRawPointer
    private let ioKitHandle: UnsafeMutableRawPointer
    private let eventSystemClient: UnsafeRawPointer
    private var deviceMatchingBlock: ServiceClientBlock?
    private var serviceRemovalBlock: ServiceClientBlock?
    private var topologyChanged: (() -> Void)?
    private var observedServices = Set<UInt>()
    private var observing = false

    @MainActor
    init?() {
        guard let coreGraphicsHandle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_NOW | RTLD_LOCAL
        ) else {
            return nil
        }
        guard let ioKitHandle = dlopen(
            "/System/Library/Frameworks/IOKit.framework/IOKit",
            RTLD_NOW | RTLD_LOCAL
        ) else {
            dlclose(coreGraphicsHandle)
            return nil
        }
        guard let copyIOHIDEvent: CopyIOHIDEvent = Self.load(
            "CGEventCopyIOHIDEvent",
            from: coreGraphicsHandle
        ), let getSenderID: GetSenderID = Self.load(
            "IOHIDEventGetSenderID",
            from: ioKitHandle
        ), let getFloatValue: GetFloatValue = Self.load(
            "IOHIDEventGetFloatValue",
            from: ioKitHandle
        ), let setFloatValue: SetFloatValue = Self.load(
            "IOHIDEventSetFloatValue",
            from: ioKitHandle
        ), let createEventSystemClient: CreateEventSystemClient = Self.load(
            "IOHIDEventSystemClientCreate",
            from: ioKitHandle
        ), let setMatchingMultiple: SetMatchingMultiple = Self.load(
            "IOHIDEventSystemClientSetMatchingMultiple",
            from: ioKitHandle
        ), let registerDeviceMatchingBlock: RegisterDeviceMatchingBlock = Self.load(
            "IOHIDEventSystemClientRegisterDeviceMatchingBlock",
            from: ioKitHandle
        ), let unregisterDeviceMatchingBlock: UnregisterDeviceMatchingBlock = Self.load(
            "IOHIDEventSystemClientUnregisterDeviceMatchingBlock",
            from: ioKitHandle
        ), let scheduleWithDispatchQueue: ScheduleWithDispatchQueue = Self.load(
            "IOHIDEventSystemClientScheduleWithDispatchQueue",
            from: ioKitHandle
        ), let unscheduleFromDispatchQueue: ScheduleWithDispatchQueue = Self.load(
            "IOHIDEventSystemClientUnscheduleFromDispatchQueue",
            from: ioKitHandle
        ), let copyServices: CopyServices = Self.load(
            "IOHIDEventSystemClientCopyServices",
            from: ioKitHandle
        ), let copyService: CopyService = Self.load(
            "IOHIDEventSystemClientCopyServiceForRegistryID",
            from: ioKitHandle
        ), let registerRemovalBlock: RegisterRemovalBlock = Self.load(
            "IOHIDServiceClientRegisterRemovalBlock",
            from: ioKitHandle
        ), let copyServiceProperty: CopyServiceProperty = Self.load(
            "IOHIDServiceClientCopyProperty",
            from: ioKitHandle
        ), let eventSystemClient = createEventSystemClient(nil) else {
            dlclose(ioKitHandle)
            dlclose(coreGraphicsHandle)
            return nil
        }

        self.coreGraphicsHandle = coreGraphicsHandle
        self.ioKitHandle = ioKitHandle
        self.copyIOHIDEvent = copyIOHIDEvent
        self.getSenderID = getSenderID
        self.getFloatValue = getFloatValue
        self.setFloatValue = setFloatValue
        self.setMatchingMultiple = setMatchingMultiple
        self.registerDeviceMatchingBlock = registerDeviceMatchingBlock
        self.unregisterDeviceMatchingBlock = unregisterDeviceMatchingBlock
        self.scheduleWithDispatchQueue = scheduleWithDispatchQueue
        self.unscheduleFromDispatchQueue = unscheduleFromDispatchQueue
        self.copyServices = copyServices
        self.copyService = copyService
        self.registerRemovalBlock = registerRemovalBlock
        self.copyServiceProperty = copyServiceProperty
        self.eventSystemClient = eventSystemClient
    }

    deinit {
        stopObservationIfNeeded()
        Unmanaged<AnyObject>.fromOpaque(eventSystemClient).release()
        dlclose(coreGraphicsHandle)
        dlclose(ioKitHandle)
    }

    @MainActor
    func startObservation(onTopologyChanged: @escaping () -> Void) {
        guard !observing else { return }

        topologyChanged = onTopologyChanged
        let removalBlock: ServiceClientBlock = { [weak self] _, _, service in
            guard let self, self.observing, let service else { return }
            self.observedServices.remove(UInt(bitPattern: service))
            self.topologyChanged?()
        }
        let matchingBlock: ServiceClientBlock = { [weak self] _, _, service in
            guard let self, self.observing, let service else { return }
            self.observeRemoval(of: service)
            self.topologyChanged?()
        }
        serviceRemovalBlock = removalBlock
        deviceMatchingBlock = matchingBlock

        let matches = [
            ["DeviceUsagePage": 1, "DeviceUsage": 2],
            ["DeviceUsagePage": 1, "DeviceUsage": 1]
        ] as CFArray
        setMatchingMultiple(eventSystemClient, matches)
        registerDeviceMatchingBlock(
            eventSystemClient,
            matchingBlock,
            nil,
            nil
        )
        observing = true
        scheduleWithDispatchQueue(eventSystemClient, DispatchQueue.main)
        observeCurrentServices()
        topologyChanged?()
    }

    @MainActor
    func stopObservation() {
        stopObservationIfNeeded()
    }

    func deviceDescriptor(senderID: UInt64) -> ScrollDeviceDescriptor? {
        guard let service = copyService(eventSystemClient, senderID) else {
            return nil
        }
        defer { Unmanaged<AnyObject>.fromOpaque(service).release() }

        return ScrollDeviceDescriptor(
            isBuiltIn: serviceProperty("Built-In", service: service),
            productName: serviceProperty("Product", service: service)
        )
    }

    @MainActor
    private func observeCurrentServices() {
        guard let services = copyServices(eventSystemClient)?.takeRetainedValue() else { return }
        for index in 0..<CFArrayGetCount(services) {
            guard let service = CFArrayGetValueAtIndex(services, index) else { continue }
            observeRemoval(of: service)
        }
    }

    @MainActor
    private func observeRemoval(of service: UnsafeRawPointer) {
        guard observedServices.insert(UInt(bitPattern: service)).inserted,
              let serviceRemovalBlock else {
            return
        }
        registerRemovalBlock(
            service,
            serviceRemovalBlock,
            nil,
            nil
        )
    }

    private func stopObservationIfNeeded() {
        guard observing else { return }
        observing = false
        unregisterDeviceMatchingBlock(eventSystemClient)
        unscheduleFromDispatchQueue(eventSystemClient, DispatchQueue.main)
        observedServices.removeAll(keepingCapacity: false)
        deviceMatchingBlock = nil
        serviceRemovalBlock = nil
        topologyChanged?()
        topologyChanged = nil
    }

    private func serviceProperty<Value>(
        _ key: String,
        service: UnsafeRawPointer
    ) -> Value? {
        let keyObject = key as CFString
        let keyPointer = Unmanaged.passUnretained(keyObject).toOpaque()
        guard let valuePointer = copyServiceProperty(service, keyPointer) else {
            return nil
        }
        let value = Unmanaged<AnyObject>.fromOpaque(valuePointer).takeRetainedValue()
        return value as? Value
    }

    private static func load<Function>(
        _ name: String,
        from handle: UnsafeMutableRawPointer
    ) -> Function? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }
}
