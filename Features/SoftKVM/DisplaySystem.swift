import Foundation

enum DisplayControlError: Error, CustomStringConvertible, LocalizedError, Sendable {
  case betterDisplayRunning
  case busy
  case preflight(String)
  case state(String)
  case ddc(String)
  case privateAPI(String)
  case verification(String)
  case staleOperation
  case rollback(String)

  var description: String {
    switch self {
    case .betterDisplayRunning:
      return "BetterDisplay 正在运行，已拒绝修改显示器。"
    case .busy:
      return "另一个显示切换操作正在进行。"
    case .preflight(let message):
      return "预检失败：\(message)"
    case .state(let message):
      return "恢复状态错误：\(message)"
    case .ddc(let message):
      return "DDC 失败：\(message)"
    case .privateAPI(let message):
      return "显示器接口失败：\(message)"
    case .verification(let message):
      return "切换后验证失败：\(message)"
    case .staleOperation:
      return "切换事务已经失效。"
    case .rollback(let message):
      return "操作失败且回滚未完成：\(message)"
    }
  }

  var errorDescription: String? {
    description
  }
}

struct DisplaySwitchInspection: Sendable {
  let report: ProbeReport
  let topologyPlan: SoftKVMTopologyPlan?
  let hasTransaction: Bool
  let hasSoftDisconnectState: Bool
  let hasWindowMigrationState: Bool
  let hasDesktopIconLayoutState: Bool

  var hasRecoveryState: Bool {
    hasTransaction
      || hasSoftDisconnectState
      || hasWindowMigrationState
      || hasDesktopIconLayoutState
  }
}
