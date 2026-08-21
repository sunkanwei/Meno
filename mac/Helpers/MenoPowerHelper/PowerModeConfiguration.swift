import Darwin
import Foundation

struct ConsoleUser: Sendable {
    let uid: uid_t
    let name: String
    let home: String
}

struct PowerModeConfiguration {
    let mode: String

    static func current() -> PowerModeConfiguration? {
        guard let consoleUser = consoleUser(),
              let data = readConfiguration(for: consoleUser) else {
            return nil
        }
        return decode(data)
    }

    static func decode(_ data: Data) -> PowerModeConfiguration? {
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ),
              let dictionary = propertyList as? [String: Any],
              let mode = dictionary[ClosedLidShutdownContract.modeKey] as? String else {
            return nil
        }
        return PowerModeConfiguration(mode: mode)
    }

    var requestsShutdown: Bool {
        mode == ClosedLidShutdownContract.shutdownModeValue
    }

    static func consoleUser() -> ConsoleUser? {
        var attributes: stat = stat()
        guard lstat("/dev/console", &attributes) == 0,
              attributes.st_uid != 0,
              let passwordEntry = getpwuid(attributes.st_uid),
              let userName = passwordEntry.pointee.pw_name,
              let homeDirectory = passwordEntry.pointee.pw_dir else {
            return nil
        }
        return ConsoleUser(
            uid: attributes.st_uid,
            name: String(cString: userName),
            home: String(cString: homeDirectory)
        )
    }

    private static func readConfiguration(for consoleUser: ConsoleUser) -> Data? {
        let path = URL(fileURLWithPath: consoleUser.home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Meno", isDirectory: true)
            .appendingPathComponent(ClosedLidShutdownContract.modeFileName)
            .path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var attributes: stat = stat()
        guard fstat(descriptor, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_uid == consoleUser.uid,
              attributes.st_size > 0,
              attributes.st_size <= 4096 else {
            return nil
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try? handle.readToEnd()
    }
}
