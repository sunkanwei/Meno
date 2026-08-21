import AppKit
import Foundation

@MainActor
final class DesktopIconLayoutController {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func capture(on display: DisplayRecord) async throws -> DesktopIconLayoutState {
    try await requireFinderAutomation()
    let desktopDirectory = try desktopDirectoryURL()
    let items = try await readDesktopItems(in: desktopDirectory)
    return try DesktopIconLayoutState.capture(
      items: items,
      on: display,
      createdAt: ISO8601DateFormatter().string(from: Date())
    )
  }

  func restore(
    _ state: DesktopIconLayoutState,
    on display: DisplayRecord
  ) async throws {
    try await requireFinderAutomation()
    let desktopDirectory = try desktopDirectoryURL()
    var targetItems = try validatedDesktopItems(
      try state.restoredItems(on: display),
      in: desktopDirectory
    ).filter { desktopItemExists(atPath: $0.path) }
    guard !targetItems.isEmpty else { return }

    var pendingItems = targetItems
    do {
      pendingItems = desktopItemsNeedingRestore(
        expected: targetItems,
        current: try await readDesktopItems(in: desktopDirectory)
      )
      if pendingItems.isEmpty {
        try await Task.sleep(for: .milliseconds(150))
        targetItems.removeAll { !desktopItemExists(atPath: $0.path) }
        guard !targetItems.isEmpty else { return }
        pendingItems = desktopItemsNeedingRestore(
          expected: targetItems,
          current: try await readDesktopItems(in: desktopDirectory)
        )
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // Reading current positions is only an optimization; the saved layout
      // remains the source of truth when Finder cannot provide a fresh view.
      pendingItems = targetItems
    }
    guard !pendingItems.isEmpty else { return }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))

    while clock.now < deadline {
      try Task.checkCancellation()
      targetItems.removeAll { !desktopItemExists(atPath: $0.path) }
      guard !targetItems.isEmpty else { return }
      pendingItems = pendingItems.filter { desktopItemExists(atPath: $0.path) }
      guard !pendingItems.isEmpty else { return }

      do {
        try await setDesktopPositions(pendingItems)
        try await Task.sleep(for: .milliseconds(100))
        targetItems.removeAll { !desktopItemExists(atPath: $0.path) }
        guard !targetItems.isEmpty else { return }
        pendingItems = desktopItemsNeedingRestore(
          expected: targetItems,
          current: try await readDesktopItems(in: desktopDirectory)
        )
        if pendingItems.isEmpty {
          try await Task.sleep(for: .milliseconds(150))
          targetItems.removeAll { !desktopItemExists(atPath: $0.path) }
          guard !targetItems.isEmpty else { return }
          pendingItems = desktopItemsNeedingRestore(
            expected: targetItems,
            current: try await readDesktopItems(in: desktopDirectory)
          )
          if pendingItems.isEmpty { return }
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // A failed read cannot prove which positions are stable. Retrying all
        // surviving targets avoids reporting an unverified layout as restored.
        pendingItems = targetItems
      }
      try await Task.sleep(for: .milliseconds(50))
    }

    try Task.checkCancellation()
    targetItems.removeAll { !desktopItemExists(atPath: $0.path) }
    guard !targetItems.isEmpty else { return }
    do {
      let current = try await readDesktopItems(in: desktopDirectory)
      pendingItems = desktopItemsNeedingRestore(expected: targetItems, current: current)
      if pendingItems.isEmpty { return }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // Keep the last verified mismatch set when Finder cannot provide a
      // final snapshot; an unverified layout must still fail below.
    }

    throw DisplayControlError.verification(
      "Finder 未能稳定恢复仍由 Mac 使用的屏幕上的 \(pendingItems.count) 个桌面图标位置"
    )
  }

  private func requireFinderAutomation() async throws {
    switch await FinderAutomationPermission.determine(askUserIfNeeded: false) {
    case .allowed:
      return
    case .notDetermined:
      throw DisplayControlError.preflight("尚未授予 Meno 控制 Finder 的自动化权限")
    case .denied:
      throw DisplayControlError.preflight("Meno 控制 Finder 的自动化权限已被拒绝")
    case .finderUnavailable:
      throw DisplayControlError.preflight("Finder 当前没有运行")
    case .checking, .unavailable:
      throw DisplayControlError.preflight("无法确认 Finder 自动化权限")
    }
  }

  private func desktopDirectoryURL() throws -> URL {
    guard let url = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first else {
      throw DisplayControlError.preflight("无法定位当前用户的桌面目录")
    }
    return url.standardizedFileURL
  }

  private func validatedDesktopItems(
    _ items: [FinderDesktopItemPosition],
    in desktopDirectory: URL
  ) throws -> [FinderDesktopItemPosition] {
    var seenPaths = Set<String>()
    return try items.map { item in
      let itemURL = URL(fileURLWithPath: item.path).standardizedFileURL
      let path = itemURL.path(percentEncoded: false)
      guard path == item.path,
        itemURL.deletingLastPathComponent() == desktopDirectory,
        seenPaths.insert(path).inserted
      else {
        throw DisplayControlError.state("桌面图标快照包含不属于当前桌面的项目")
      }
      return item
    }
  }

  private func desktopItemExists(atPath path: String) -> Bool {
    (try? fileManager.attributesOfItem(atPath: path)) != nil
  }

  private func readDesktopItems(
    in desktopDirectory: URL
  ) async throws -> [FinderDesktopItemPosition] {
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      return try Self.readDesktopItemsSynchronously(in: desktopDirectory)
    }
    return try await withTaskCancellationHandler {
      let items = try await task.value
      try Task.checkCancellation()
      return items
    } onCancel: {
      task.cancel()
    }
  }

  nonisolated private static func readDesktopItemsSynchronously(
    in desktopDirectory: URL
  ) throws -> [FinderDesktopItemPosition] {
    let scriptSource = """
    tell application "Finder"
      return {URL, name, desktop position} of every item of desktop
    end tell
    """
    let result = try execute(scriptSource, failure: "Finder 未能读取桌面图标位置")
    var items: [FinderDesktopItemPosition] = []
    var seenPaths = Set<String>()
    guard result.descriptorType == typeAEList,
      result.numberOfItems == 3,
      let urls = result.atIndex(1), urls.descriptorType == typeAEList,
      let names = result.atIndex(2), names.descriptorType == typeAEList,
      let positions = result.atIndex(3), positions.descriptorType == typeAEList,
      urls.numberOfItems == names.numberOfItems,
      names.numberOfItems == positions.numberOfItems
    else {
      throw DisplayControlError.verification("Finder 返回了无效的桌面项目列表")
    }
    guard names.numberOfItems > 0 else { return [] }
    for index in 1...names.numberOfItems {
      guard let filename = names.atIndex(index)?.stringValue,
        let position = positions.atIndex(index), position.numberOfItems == 2,
        let x = position.atIndex(1)?.int32Value,
        let y = position.atIndex(2)?.int32Value
      else {
        throw DisplayControlError.verification("Finder 返回了无法解析的桌面图标位置")
      }
      let reportedURL = urls.atIndex(index)?.stringValue.flatMap(URL.init(string:))
      guard let itemURL = FinderDesktopItemURLResolver.resolve(
        reportedURL: reportedURL,
        filename: filename,
        desktopURL: desktopDirectory
      ) else {
        continue
      }
      let path = itemURL.path(percentEncoded: false)
      guard seenPaths.insert(path).inserted else {
        throw DisplayControlError.verification("Finder 返回了重复的桌面项目路径")
      }
      items.append(FinderDesktopItemPosition(path: path, x: Int(x), y: Int(y)))
    }
    return items
  }

  private func setDesktopPositions(_ items: [FinderDesktopItemPosition]) async throws {
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      try Self.setDesktopPositionsSynchronously(items)
    }
    try await withTaskCancellationHandler {
      try await task.value
      try Task.checkCancellation()
    } onCancel: {
      task.cancel()
    }
  }

  nonisolated private static func setDesktopPositionsSynchronously(
    _ items: [FinderDesktopItemPosition]
  ) throws {
    let assignments = items.map {
      let fileURL = URL(fileURLWithPath: $0.path, isDirectory: false)
      return "set desktop position of item "
        + "(\(appleScriptString(fileURL.lastPathComponent))) of desktop "
        + "to {\($0.x), \($0.y)}"
    }.joined(separator: "\n")
    let scriptSource = """
    ignoring application responses
      tell application "Finder"
        \(assignments)
      end tell
    end ignoring
    return true
    """
    _ = try execute(
      scriptSource,
      failure: "Finder 未能恢复桌面图标位置"
    )
  }

  nonisolated private static func execute(
    _ source: String,
    failure: String
  ) throws -> NSAppleEventDescriptor {
    guard let script = NSAppleScript(source: source) else {
      throw DisplayControlError.verification("\(failure)：无法准备命令")
    }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    guard error == nil else {
      throw DisplayControlError.verification(failure)
    }
    return result
  }

  nonisolated private static func appleScriptString(_ value: String) -> String {
    "\"" + value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\r", with: "\" & return & \"")
      .replacingOccurrences(of: "\n", with: "\" & linefeed & \"")
      .replacingOccurrences(of: "\t", with: "\" & tab & \"") + "\""
  }
}
