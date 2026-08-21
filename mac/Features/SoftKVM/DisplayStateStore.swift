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

  static func legacy(fileManager: FileManager = .default) -> URL {
    fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/DisplaySwitch", isDirectory: true)
  }
}

final class DisplayOperationLease: @unchecked Sendable {
  private var descriptors: [Int32] = []

  init(fileManager: FileManager = .default) throws {
    do {
      for directory in [
        SoftKVMStatePaths.legacy(fileManager: fileManager),
        SoftKVMStatePaths.current(fileManager: fileManager)
      ] {
        try fileManager.createDirectory(
          at: directory,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let lockURL = directory.appendingPathComponent("operation.lock")
        let descriptor = lockURL.path.withCString {
          Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
          throw DisplayControlError.state(
            "无法打开操作锁：\(String(cString: strerror(errno)))"
          )
        }
        do {
          try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockURL.path)
        } catch {
          Darwin.close(descriptor)
          throw error
        }
        var fileLock = flock()
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &fileLock) != -1 else {
          let lockError = errno
          Darwin.close(descriptor)
          if lockError == EACCES || lockError == EAGAIN {
            throw DisplayControlError.busy
          }
          throw DisplayControlError.state(
            "无法锁定操作文件：\(String(cString: strerror(lockError)))"
          )
        }
        descriptors.append(descriptor)
      }
    } catch {
      descriptors.forEach { Darwin.close($0) }
      descriptors.removeAll()
      if let controlError = error as? DisplayControlError {
        throw controlError
      }
      throw DisplayControlError.state("无法创建状态目录：\(error.localizedDescription)")
    }
  }

  deinit {
    descriptors.forEach { Darwin.close($0) }
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

  func importLegacyStateIfNeeded() throws {
    let legacyDirectory = SoftKVMStatePaths.legacy(fileManager: fileManager)
    let legacyNames = [FileName.softDisconnect, FileName.transaction, FileName.windows]
    let legacyFiles = legacyNames.filter {
      fileManager.fileExists(atPath: legacyDirectory.appendingPathComponent($0).path)
    }
    guard !legacyFiles.isEmpty else { return }

    let currentFiles = (legacyNames + [FileName.desktopIcons]).filter {
      fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
    }
    guard currentFiles.isEmpty else {
      throw DisplayControlError.state("Meno 与旧 DisplaySwitch 同时存在恢复状态，不能猜测合并")
    }

    let operationLease = try DisplayOperationLease(fileManager: fileManager)
    defer { _ = operationLease }
    for name in legacyFiles {
      let source = legacyDirectory.appendingPathComponent(name)
      try validateStateFile(at: source, name: name)
    }
    try prepareDirectory()

    var moved: [String] = []
    do {
      for name in legacyFiles {
        let source = legacyDirectory.appendingPathComponent(name)
        let destination = directory.appendingPathComponent(name)
        try fileManager.moveItem(at: source, to: destination)
        moved.append(name)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
      }
    } catch {
      let migrationError = error
      var rollbackFailures: [String] = []
      for name in moved.reversed() {
        let source = directory.appendingPathComponent(name)
        let destination = legacyDirectory.appendingPathComponent(name)
        do {
          try fileManager.moveItem(at: source, to: destination)
        } catch {
          rollbackFailures.append("\(name)：\(error.localizedDescription)")
        }
      }
      if !rollbackFailures.isEmpty {
        let rollbackDescription = rollbackFailures.joined(separator: "；")
        throw DisplayControlError.state(
          "迁移旧 DisplaySwitch 恢复状态失败：\(migrationError.localizedDescription)；且部分文件未能移回原位：\(rollbackDescription)"
        )
      }
      throw DisplayControlError.state(
        "迁移旧 DisplaySwitch 恢复状态失败：\(migrationError.localizedDescription)"
      )
    }
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

  private func validateStateFile(at url: URL, name: String) throws {
    let data = try Data(contentsOf: url)
    switch name {
    case FileName.softDisconnect:
      guard try JSONDecoder().decode(SoftDisconnectState.self, from: data).schemaVersion == 1 else {
        throw DisplayControlError.state("旧软断开快照版本不受支持")
      }
    case FileName.transaction:
      guard try JSONDecoder().decode(SwitchTransactionState.self, from: data).schemaVersion == 1 else {
        throw DisplayControlError.state("旧切换事务版本不受支持")
      }
    case FileName.windows:
      guard try JSONDecoder().decode(WindowMigrationState.self, from: data).schemaVersion == 1 else {
        throw DisplayControlError.state("旧窗口快照版本不受支持")
      }
    default:
      throw DisplayControlError.state("不认识的旧状态文件：\(name)")
    }
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
