import Foundation

struct ClosedLidShutdownConfiguration {
    private let fileManager = FileManager.default

    func write(mode: ClosedLidMode) throws {
        let directory = try applicationSupportDirectory()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let data = try PropertyListSerialization.data(
            fromPropertyList: [ClosedLidShutdownContract.modeKey: mode.rawValue],
            format: .binary,
            options: 0
        )
        try data.write(
            to: directory.appendingPathComponent(ClosedLidShutdownContract.modeFileName),
            options: .atomic
        )
        notifyHelper()
    }

    private func applicationSupportDirectory() throws -> URL {
        guard let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return baseURL.appendingPathComponent("Meno", isDirectory: true)
    }

    private func notifyHelper() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(ClosedLidShutdownContract.modeChangedNotification as CFString),
            nil,
            nil,
            true
        )
    }
}
