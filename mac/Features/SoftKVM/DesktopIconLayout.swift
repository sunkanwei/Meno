import Foundation

struct FinderDesktopItemPosition: Equatable, Sendable {
  let path: String
  let x: Int
  let y: Int
}

func desktopItemsNeedingRestore(
  expected: [FinderDesktopItemPosition],
  current: [FinderDesktopItemPosition],
  tolerance: Int = 2
) -> [FinderDesktopItemPosition] {
  let positionsByPath = Dictionary(
    current.map { ($0.path, $0) },
    uniquingKeysWith: { first, _ in first }
  )
  return expected.filter { expectedItem in
    guard let currentItem = positionsByPath[expectedItem.path] else { return true }
    return abs(currentItem.x - expectedItem.x) > tolerance
      || abs(currentItem.y - expectedItem.y) > tolerance
  }
}

struct DesktopIconLayoutEntry: Codable, Equatable, Sendable {
  let path: String
  let offsetX: Int
  let offsetY: Int
}

struct DesktopIconLayoutState: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let createdAt: String
  let displayUUID: String
  let displayWidth: Int
  let displayHeight: Int
  let entries: [DesktopIconLayoutEntry]

  static func capture(
    items: [FinderDesktopItemPosition],
    on display: DisplayRecord,
    createdAt: String
  ) throws -> DesktopIconLayoutState {
    let displayUUID = try validatedViewSonicUUID(display)
    var seenPaths = Set<String>()
    var entries: [DesktopIconLayoutEntry] = []

    for item in items where contains(item, on: display) {
      guard item.path.hasPrefix("/"), seenPaths.insert(item.path).inserted else {
        throw DisplayControlError.preflight("Finder 返回了无效或重复的桌面项目路径")
      }
      entries.append(DesktopIconLayoutEntry(
        path: item.path,
        offsetX: item.x - display.originX,
        offsetY: item.y - display.originY
      ))
    }

    return DesktopIconLayoutState(
      schemaVersion: 1,
      createdAt: createdAt,
      displayUUID: displayUUID,
      displayWidth: display.width,
      displayHeight: display.height,
      entries: entries.sorted { $0.path < $1.path }
    )
  }

  func restoredItems(on display: DisplayRecord) throws -> [FinderDesktopItemPosition] {
    let currentUUID = try Self.validatedViewSonicUUID(display)
    guard schemaVersion == 1 else {
      throw DisplayControlError.state("不支持的桌面图标快照版本：\(schemaVersion)")
    }
    guard displayUUID.caseInsensitiveCompare(currentUUID) == .orderedSame,
      display.width == displayWidth,
      display.height == displayHeight
    else {
      throw DisplayControlError.verification("ViewSonic 身份或桌面尺寸与图标快照不一致")
    }

    var seenPaths = Set<String>()
    return try entries.map { entry in
      guard entry.path.hasPrefix("/"), seenPaths.insert(entry.path).inserted,
        (0..<displayWidth).contains(entry.offsetX),
        (0..<displayHeight).contains(entry.offsetY)
      else {
        throw DisplayControlError.state("桌面图标快照包含无效项目")
      }
      return FinderDesktopItemPosition(
        path: entry.path,
        x: display.originX + entry.offsetX,
        y: display.originY + entry.offsetY
      )
    }
  }

  private static func validatedViewSonicUUID(_ display: DisplayRecord) throws -> String {
    guard display.role == .viewSonic,
      display.isActive,
      display.width > 0,
      display.height > 0,
      let uuid = display.uuid,
      uuid.caseInsensitiveCompare(FixedDisplayConfiguration.viewSonicUUID) == .orderedSame
    else {
      throw DisplayControlError.verification("无法确认用于保护桌面图标的 ViewSonic 显示器")
    }
    return uuid.uppercased()
  }

  private static func contains(
    _ item: FinderDesktopItemPosition,
    on display: DisplayRecord
  ) -> Bool {
    let relativeX = Int64(item.x) - Int64(display.originX)
    let relativeY = Int64(item.y) - Int64(display.originY)
    return relativeX >= 0
      && relativeX < Int64(display.width)
      && relativeY >= 0
      && relativeY < Int64(display.height)
  }
}
