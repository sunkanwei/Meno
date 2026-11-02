import Darwin
import Foundation

enum SwitchTarget: String, Codable, Sendable {
  case mac
  case windows
}

enum SwitchPhase: String, Codable, Sendable {
  case preparing
  case desktopIconsCaptured
  case windowsMoved
  // Persisted transactions may still carry this phase during recovery.
  case inputChanged
  case philipsDisconnected
  case philipsReconnected
  case desktopIconsRestored
  case windowsRestored
}

struct SwitchTransactionState: Codable, Sendable {
  let schemaVersion: Int
  let createdAt: String
  let operationID: UUID?
  let target: SwitchTarget?
  var phase: SwitchPhase?
}

struct WindowMigrationEntry: Codable, Sendable {
  let applicationName: String
  let bundleIdentifier: String?
  let processID: Int32
  let applicationLaunchTimestamp: Double?
  let windowIndex: Int
  let windowIdentifier: String?
  let title: String
  let role: String?
  let subrole: String?
  let originalFrame: WindowFrameRecord
  let movedFrame: WindowFrameRecord
}

struct WindowMigrationState: Codable, Sendable {
  let schemaVersion: Int
  let createdAt: String
  let entries: [WindowMigrationEntry]
}

enum SoftKVMStatePaths {
  static func current(fileManager: FileManager = .default) -> URL {
    fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Meno/SoftKVM", isDirectory: true)
  }
}

final class DisplayOperationLease: @unchecked Sendable {
  private let descriptor: Int32

  init(fileManager: FileManager = .default, directory: URL? = nil) throws {
    let directory = directory ?? SoftKVMStatePaths.current(fileManager: fileManager)
    do {
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    } catch {
      throw DisplayControlError.state("无法创建状态目录：\(error.localizedDescription)")
    }
    let lockURL = directory.appendingPathComponent("operation.lock")
    let descriptor = lockURL.path.withCString {
      Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else {
      throw DisplayControlError.state("无法打开操作锁：\(String(cString: strerror(errno)))")
    }
    do {
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockURL.path)
      var fileLock = flock()
      fileLock.l_type = Int16(F_WRLCK)
      fileLock.l_whence = Int16(SEEK_SET)
      guard Darwin.fcntl(descriptor, F_SETLK, &fileLock) != -1 else {
        let lockError = errno
        if lockError == EACCES || lockError == EAGAIN {
          throw DisplayControlError.busy
        }
        throw DisplayControlError.state(
          "无法锁定操作文件：\(String(cString: strerror(lockError)))"
        )
      }
    } catch {
      Darwin.close(descriptor)
      if let controlError = error as? DisplayControlError { throw controlError }
      throw DisplayControlError.state("无法设置操作锁权限：\(error.localizedDescription)")
    }
    self.descriptor = descriptor
  }

  deinit {
    Darwin.close(descriptor)
  }
}

actor DisplayStateStore {
  private enum FileName {
    static let softDisconnect = "soft-disconnect-state.json"
    static let transaction = "switch-transaction.json"
    static let windows = "window-migration-state.json"
    static let desktopIcons = "desktop-icon-layout-state.json"
  }

  private let fileManager: FileManager
  private let directory: URL

  init(fileManager: FileManager = .default, directory: URL? = nil) {
    self.fileManager = fileManager
    self.directory = directory ?? SoftKVMStatePaths.current(fileManager: fileManager)
  }

  func softDisconnectState() throws -> SoftDisconnectState? {
    try load(SoftDisconnectState.self, name: FileName.softDisconnect)
  }

  func save(softDisconnectState: SoftDisconnectState) throws {
    try save(softDisconnectState, name: FileName.softDisconnect)
  }

  func clearSoftDisconnectState() throws {
    try clear(name: FileName.softDisconnect)
  }

  func transaction() throws -> SwitchTransactionState? {
    try load(SwitchTransactionState.self, name: FileName.transaction)
  }

  func save(transaction: SwitchTransactionState) throws {
    try save(transaction, name: FileName.transaction)
  }

  func clearTransaction() throws {
    try clear(name: FileName.transaction)
  }

  func windowMigrationState() throws -> WindowMigrationState? {
    try load(WindowMigrationState.self, name: FileName.windows)
  }

  func save(windowMigrationState: WindowMigrationState) throws {
    try save(windowMigrationState, name: FileName.windows)
  }

  func clearWindowMigrationState() throws {
    try clear(name: FileName.windows)
  }

  func desktopIconLayoutState() throws -> DesktopIconLayoutState? {
    try load(DesktopIconLayoutState.self, name: FileName.desktopIcons)
  }

  func save(desktopIconLayoutState: DesktopIconLayoutState) throws {
    try save(desktopIconLayoutState, name: FileName.desktopIcons)
  }

  func clearDesktopIconLayoutState() throws {
    try clear(name: FileName.desktopIcons)
  }

  private func load<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
    let url = directory.appendingPathComponent(name)
    guard fileManager.fileExists(atPath: url.path) else {
      return nil
    }
    do {
      let value = try JSONDecoder().decode(type, from: Data(contentsOf: url))
      if let value = value as? SoftDisconnectState, value.schemaVersion != 1 {
        throw DisplayControlError.state("不支持的软断开快照版本：\(value.schemaVersion)")
      }
      if let value = value as? SwitchTransactionState, value.schemaVersion != 1 {
        throw DisplayControlError.state("不支持的切换事务版本：\(value.schemaVersion)")
      }
      if let value = value as? WindowMigrationState, value.schemaVersion != 1 {
        throw DisplayControlError.state("不支持的窗口搬运快照版本：\(value.schemaVersion)")
      }
      if let value = value as? DesktopIconLayoutState, value.schemaVersion != 1 {
        throw DisplayControlError.state("不支持的桌面图标快照版本：\(value.schemaVersion)")
      }
      return value
    } catch let error as DisplayControlError {
      throw error
    } catch {
      throw DisplayControlError.state("无法读取 \(name)：\(error.localizedDescription)")
    }
  }

  private func save<T: Encodable>(_ value: T, name: String) throws {
    do {
      try prepareDirectory()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let url = directory.appendingPathComponent(name)
      try encoder.encode(value).write(
        to: url,
        options: .atomic
      )
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      throw DisplayControlError.state("无法保存 \(name)：\(error.localizedDescription)")
    }
  }

  private func prepareDirectory() throws {
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  private func clear(name: String) throws {
    let url = directory.appendingPathComponent(name)
    guard fileManager.fileExists(atPath: url.path) else {
      return
    }
    do {
      try fileManager.removeItem(at: url)
    } catch {
      throw DisplayControlError.state("无法清除 \(name)：\(error.localizedDescription)")
    }
  }
}
