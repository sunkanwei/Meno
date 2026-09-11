import Foundation
import IOKit.hid

// HID report layout follows Mac Duo and Sam Henri Gold's LidAngleSensor.
// Mutable device state belongs exclusively to this queue.
final class LidFoldSensor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sunkanwei.Meno.lidAngle", qos: .userInitiated)
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var timer: DispatchSourceTimer?
    private let onReading: @MainActor @Sendable (Double?) -> Void

    init(onReading: @escaping @MainActor @Sendable (Double?) -> Void) {
        self.onReading = onReading
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                self?.poll()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() { queue.async { [self] in cleanUp() } }

    private var retryAt: TimeInterval = 0
    private var failedReadings = 0

    private func poll() {
        let now = ProcessInfo.processInfo.systemUptime
        if device == nil {
            guard now >= retryAt else { return }
            retryAt = now + 1
            connect()
        }
        guard let device else { deliver(nil); return }
        let angle = read(device)
        failedReadings = angle == nil ? failedReadings + 1 : 0
        deliver(angle)
        // A stale HID handle can survive wake. Re-discover it after one second
        // of failed reports, while keeping the polling timer alive.
        if failedReadings >= 30 {
            disconnect()
            retryAt = now + 1
        }
    }

    private func connect() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: 0x20,
                                                kIOHIDDeviceUsageKey: 0x8A] as CFDictionary)
        self.manager = manager
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            disconnect(); return
        }
        for candidate in devices {
            guard IOHIDDeviceOpen(candidate, 0) == kIOReturnSuccess else { continue }
            device = candidate
            return
        }
        disconnect()
    }

    private func read(_ device: IOHIDDevice) -> Double? {
        var bytes = [UInt8](repeating: 0, count: 8)
        var length = bytes.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &bytes, &length) == kIOReturnSuccess,
              length <= bytes.count else { return nil }
        return Self.decodeReport(bytes.prefix(max(0, length)))
    }

    static func decodeReport(_ bytes: ArraySlice<UInt8>) -> Double? {
        guard bytes.count >= 3, bytes.first == 1 else { return nil }
        let start = bytes.startIndex
        let angle = Int(bytes[start + 1]) | (Int(bytes[start + 2]) << 8)
        return (0...180).contains(angle) ? Double(angle) : nil
    }

    private func deliver(_ angle: Double?) {
        Task { @MainActor [onReading] in onReading(angle) }
    }

    private func cleanUp() {
        timer?.cancel(); timer = nil
        retryAt = 0
        disconnect()
    }

    private func disconnect() {
        failedReadings = 0
        if let device { IOHIDDeviceClose(device, 0) }
        if let manager { IOHIDManagerClose(manager, 0) }
        device = nil; manager = nil
    }
}
