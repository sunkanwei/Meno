import Foundation
import IOKit
import IOKit.pwr_mgt

final class LidStateMonitor: @unchecked Sendable {
    // Swift cannot import the nested IOKit macro from IOPM.h directly.
    private static let clamshellStateChangeMessage: UInt32 = 0xE003_4100

    private let onStateChanged: @Sendable () -> Void
    private var rootDomainService: io_service_t = IO_OBJECT_NULL
    private var notificationPort: IONotificationPortRef?
    private var notification: io_object_t = IO_OBJECT_NULL

    init(onStateChanged: @escaping @Sendable () -> Void) {
        self.onStateChanged = onStateChanged
    }

    @MainActor
    var isRunning: Bool {
        rootDomainService != IO_OBJECT_NULL && notificationPort != nil
    }

    @MainActor
    func start() -> Bool {
        stop()

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != IO_OBJECT_NULL,
              let port = IONotificationPortCreate(kIOMainPortDefault) else {
            if service != IO_OBJECT_NULL {
                IOObjectRelease(service)
            }
            return false
        }

        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        var notification = io_object_t(IO_OBJECT_NULL)
        let result = IOServiceAddInterestNotification(
            port,
            service,
            kIOGeneralInterest,
            Self.interestCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            &notification
        )
        guard result == kIOReturnSuccess else {
            IONotificationPortSetDispatchQueue(port, nil)
            IONotificationPortDestroy(port)
            IOObjectRelease(service)
            return false
        }

        rootDomainService = service
        notificationPort = port
        self.notification = notification
        return true
    }

    @MainActor
    func stop() {
        if notification != IO_OBJECT_NULL {
            IOObjectRelease(notification)
            notification = IO_OBJECT_NULL
        }
        if let notificationPort {
            IONotificationPortSetDispatchQueue(notificationPort, nil)
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        if rootDomainService != IO_OBJECT_NULL {
            IOObjectRelease(rootDomainService)
            rootDomainService = IO_OBJECT_NULL
        }
    }

    @MainActor
    func currentState() -> MenoLidState {
        guard rootDomainService != IO_OBJECT_NULL,
              let property = IORegistryEntryCreateCFProperty(
                  rootDomainService,
                  kAppleClamshellStateKey as CFString,
                  kCFAllocatorDefault,
                  0
              )?.takeRetainedValue(),
              let isClosed = property as? Bool else {
            return .unavailable
        }
        return isClosed ? .closed : .open
    }

    private static let interestCallback: IOServiceInterestCallback = { reference, _, messageType, _ in
        guard messageType == clamshellStateChangeMessage,
              let reference else {
            return
        }
        let monitor = Unmanaged<LidStateMonitor>
            .fromOpaque(reference)
            .takeUnretainedValue()
        monitor.onStateChanged()
    }
}
