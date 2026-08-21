import Foundation
import IOKit
import IOKit.pwr_mgt

final class PowerHelperLidMonitor: @unchecked Sendable {
    private static let clamshellStateChangeMessage: UInt32 = 0xE003_4100

    private let onStateChanged: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.sunkanwei.Meno.PowerHelper.lid")
    private var service: io_service_t = IO_OBJECT_NULL
    private var notificationPort: IONotificationPortRef?
    private var notification: io_object_t = IO_OBJECT_NULL

    init(onStateChanged: @escaping @Sendable () -> Void) {
        self.onStateChanged = onStateChanged
    }

    func start() -> Bool {
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

        IONotificationPortSetDispatchQueue(port, queue)
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

        self.service = service
        notificationPort = port
        self.notification = notification
        return true
    }

    func currentStateIsClosed() -> Bool? {
        guard service != IO_OBJECT_NULL else { return nil }
        return Self.readState(from: service)
    }

    static func currentStateDescription() -> String {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != IO_OBJECT_NULL else { return "unavailable" }
        defer { IOObjectRelease(service) }
        guard let isClosed = readState(from: service) else { return "unavailable" }
        return isClosed ? "closed" : "open"
    }

    private static func readState(from service: io_service_t) -> Bool? {
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            kAppleClamshellStateKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }
        return property as? Bool
    }

    private static let interestCallback: IOServiceInterestCallback = { reference, _, messageType, _ in
        guard messageType == clamshellStateChangeMessage,
              let reference else {
            return
        }
        let monitor = Unmanaged<PowerHelperLidMonitor>
            .fromOpaque(reference)
            .takeUnretainedValue()
        monitor.onStateChanged()
    }
}
