import Foundation

@MainActor
func makeFullSwitchController() -> FullSwitchController {
  let stateStore = DisplayStateStore()
  let displayController = DisplayHardwareController()
  let softController = SoftDisconnectController(
    displayController: displayController,
    stateStore: stateStore
  )
  let windowController = WindowMigrationController(
    displayController: displayController,
    stateStore: stateStore
  )
  let desktopIconController = DesktopIconLayoutController()
  return FullSwitchController(
    displayController: displayController,
    ddcController: PhilipsDDCController(),
    softController: softController,
    windowController: windowController,
    desktopIconController: desktopIconController,
    stateStore: stateStore
  )
}

actor FullSwitchController {
  private let displayController: DisplayHardwareController
  private let ddcController: PhilipsDDCController
  private let softController: SoftDisconnectController
  private let windowController: WindowMigrationController
  private let desktopIconController: DesktopIconLayoutController
  private let stateStore: DisplayStateStore

  private var activeOperationID: UUID?
  private var operationLease: DisplayOperationLease?

  init(
    displayController: DisplayHardwareController,
    ddcController: PhilipsDDCController,
    softController: SoftDisconnectController,
    windowController: WindowMigrationController,
    desktopIconController: DesktopIconLayoutController,
    stateStore: DisplayStateStore
  ) {
    self.displayController = displayController
    self.ddcController = ddcController
    self.softController = softController
    self.windowController = windowController
    self.desktopIconController = desktopIconController
    self.stateStore = stateStore
  }

  func prepareState() async throws {
    try await stateStore.importLegacyStateIfNeeded()
  }

  func stabilizeWindowsTopology() async throws {
    try await softController.stabilizeWindowsTopology()
  }

  func inspect() async throws -> DisplaySwitchInspection {
    let report = await displayController.snapshot()
    async let transaction = stateStore.transaction()
    async let softDisconnect = stateStore.softDisconnectState()
    async let windowMigration = stateStore.windowMigrationState()
    async let desktopIconLayout = stateStore.desktopIconLayoutState()
    let state = try await softDisconnect
    return try await DisplaySwitchInspection(
      report: report,
      topologyPlan: topologyPlan(report: report, state: state),
      hasTransaction: transaction != nil,
      hasSoftDisconnectState: state != nil,
      hasWindowMigrationState: windowMigration != nil,
      hasDesktopIconLayoutState: desktopIconLayout != nil
    )
  }

  private func topologyPlan(
    report: ProbeReport,
    state: SoftDisconnectState?
  ) throws -> SoftKVMTopologyPlan? {
    switch report.topology {
    case .mac:
      return SoftKVMMacBaseline.resolve(report.displays)?.topologyPlan
    case .windows:
      guard let state,
        let topology = SoftKVMWindowsTopology.resolve(report.displays)
      else {
        return nil
      }
      return try state.resolvedTopologyPlan(
        currentMainDisplay: topology.mainDisplay
      )
    case .unknown:
      return nil
    }
  }

  func toWindows() async throws {
    let operationID = try beginOperation()
    defer { endOperation(operationID) }
    try await displayController.requireBetterDisplayStopped()
    guard try await stateStore.transaction() == nil,
      try await stateStore.desktopIconLayoutState() == nil
    else {
      throw DisplayControlError.state("存在未完成切换，请先执行 recover")
    }
    try await toWindowsLocked(operationID: operationID)
  }

  func toMac() async throws {
    let operationID = try beginOperation()
    defer { endOperation(operationID) }
    try await displayController.requireBetterDisplayStopped()
    let transaction = try await stateStore.transaction()
    let desktopIconLayout = try await stateStore.desktopIconLayoutState()
    if transaction != nil || desktopIconLayout != nil {
      try await recoverLocked(operationID: operationID)
      return
    }
    try await toMacLocked(operationID: operationID)
  }

  func recover() async throws {
    let operationID = try beginOperation()
    defer { endOperation(operationID) }
    try await displayController.requireBetterDisplayStopped()
    try await recoverLocked(operationID: operationID)
  }

  private func toWindowsLocked(operationID: UUID) async throws {
    try validate(operationID)
    let initial = await displayController.snapshot()
    if initial.topology == .windows {
      guard try await stateStore.softDisconnectState() != nil else {
        throw DisplayControlError.state("Philips 已软断开，但缺少恢复快照；请恢复到 Mac")
      }
      return
    }
    guard initial.topology == .mac,
      initial.passed,
      let baseline = SoftKVMMacBaseline.resolve(initial.displays)
    else {
      throw DisplayControlError.preflight("完整三屏基线未通过")
    }
    guard try await stateStore.softDisconnectState() == nil else {
      throw DisplayControlError.state("三屏状态下存在旧的软断开快照，请先执行 recover")
    }
    guard try await stateStore.windowMigrationState() == nil else {
      throw DisplayControlError.state("三屏状态下存在旧的窗口搬运快照，请先执行 recover")
    }
    try await displayController.requireAccessibility()
    try await displayController.requireProtectedViewSonic(baseline.viewSonic)

    var transaction = try await beginTransactionProtectingDesktopIcons(
      display: baseline.viewSonic,
      operationID: operationID,
      target: .windows
    )
    do {
      try validate(operationID)
      try await windowController.movePhilipsWindowsToMainDisplay(
        requireWindow: false
      )
      try validate(operationID)
      transaction.phase = .windowsMoved
      try await stateStore.save(transaction: transaction)

      try await ddcController.setInput(PhilipsDDCController.displayPortInput)
      try validate(operationID)
      transaction.phase = .inputChanged
      try await stateStore.save(transaction: transaction)
      _ = try await waitForMacBaseline(operationID: operationID)
      try validate(operationID)
      try await windowController.requireNoVisiblePhilipsWindows()

      try await softController.disconnectPhilips()
      try validate(operationID)
      transaction.phase = .philipsDisconnected
      try await stateStore.save(transaction: transaction)
      let final = await displayController.snapshot()
      guard final.topology == .windows else {
        throw DisplayControlError.verification("软断开后未进入 Windows 两屏终态")
      }
      try await restoreDesktopIconsIfNeeded(report: final)
      transaction.phase = .desktopIconsRestored
      try await stateStore.save(transaction: transaction)
      try await stateStore.clearTransaction()
      try await stateStore.clearDesktopIconLayoutState()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      do {
        try await rollbackToMac(operationID: operationID)
        try await stateStore.clearTransaction()
      } catch let rollbackError {
        throw DisplayControlError.rollback(
          "原错误：\(error)；回滚错误：\(rollbackError)；事务已保留"
        )
      }
      throw error
    }
  }

  private func toMacLocked(operationID: UUID) async throws {
    try validate(operationID)
    let initial = await displayController.snapshot()
    if initial.topology == .mac {
      try await ddcController.setInput(PhilipsDDCController.hdmi2Input)
      var final = try await waitForMacBaseline(operationID: operationID)
      if try await stateStore.softDisconnectState() != nil {
        try await softController.reconnectPhilips()
        final = try await waitForMacBaseline(operationID: operationID)
      }
      try await restoreDesktopIconsIfNeeded(report: final)
      try await windowController.restoreWindowsIfNeeded()
      try await stateStore.clearTransaction()
      try await stateStore.clearDesktopIconLayoutState()
      return
    }
    guard try await stateStore.softDisconnectState() != nil else {
      throw DisplayControlError.state("没有 Philips 软断开恢复快照")
    }
    guard let windowsPair = SoftKVMWindowsDisplayPair.resolve(initial.displays) else {
      throw DisplayControlError.preflight("当前不是可恢复的 Windows 两屏状态")
    }
    try await displayController.requireProtectedViewSonic(windowsPair.viewSonic)

    var transaction: SwitchTransactionState
    if try await stateStore.desktopIconLayoutState() == nil {
      transaction = try await beginTransactionProtectingDesktopIcons(
        display: windowsPair.viewSonic,
        operationID: operationID,
        target: .mac
      )
    } else {
      transaction = makeTransaction(
        operationID: operationID,
        target: .mac,
        phase: .desktopIconsCaptured
      )
      try await stateStore.save(transaction: transaction)
    }
    do {
      try await softController.reconnectPhilips()
      try validate(operationID)
      transaction.phase = .philipsReconnected
      try await stateStore.save(transaction: transaction)
      try await ddcController.setInput(PhilipsDDCController.hdmi2Input)
      let final = try await waitForMacBaseline(operationID: operationID)
      try await restoreDesktopIconsIfNeeded(report: final)
      transaction.phase = .desktopIconsRestored
      try await stateStore.save(transaction: transaction)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      do {
        try await rollbackToWindows(operationID: operationID)
        try await stateStore.clearTransaction()
      } catch let rollbackError {
        throw DisplayControlError.rollback(
          "原错误：\(error)；回滚错误：\(rollbackError)；事务已保留"
        )
      }
      throw error
    }

    do {
      try await windowController.restoreWindowsIfNeeded()
      transaction.phase = .windowsRestored
      try await stateStore.save(transaction: transaction)
      try await stateStore.clearTransaction()
      try await stateStore.clearDesktopIconLayoutState()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw DisplayControlError.verification(
        "Philips 已恢复为 Mac 显示器，但窗口原位恢复未完成：\(error)；请恢复到 Mac"
      )
    }
  }

  private func recoverLocked(operationID: UUID) async throws {
    try validate(operationID)
    let report = await displayController.snapshot()
    switch report.topology {
    case .mac:
      try await ddcController.setInput(PhilipsDDCController.hdmi2Input)
      var final = try await waitForMacBaseline(operationID: operationID)
      if try await stateStore.softDisconnectState() != nil {
        try await softController.reconnectPhilips()
        final = try await waitForMacBaseline(operationID: operationID)
      }
      try await restoreDesktopIconsIfNeeded(report: final)
      try await windowController.restoreWindowsIfNeeded()
      try await stateStore.clearTransaction()
      try await stateStore.clearDesktopIconLayoutState()
    case .windows:
      try await toMacLocked(operationID: operationID)
    case .unknown:
      guard try await stateStore.softDisconnectState() != nil,
        SoftKVMWindowsDisplayPair.resolve(report.displays) != nil
      else {
        throw DisplayControlError.state("当前拓扑未知，不能猜测恢复操作")
      }
      try await toMacLocked(operationID: operationID)
    }
  }

  private func rollbackToMac(operationID: UUID) async throws {
    try validate(operationID)
    if try await stateStore.softDisconnectState() != nil {
      try await softController.reconnectPhilips()
    }
    try await ddcController.setInput(PhilipsDDCController.hdmi2Input)
    let final = try await waitForMacBaseline(operationID: operationID)
    try await restoreDesktopIconsIfNeeded(report: final)
    try await windowController.restoreWindowsIfNeeded()
    try await stateStore.clearDesktopIconLayoutState()
  }

  private func rollbackToWindows(operationID: UUID) async throws {
    try validate(operationID)
    var ddcError: Error?
    let report = await displayController.snapshot()
    switch report.topology {
    case .mac:
      do {
        try await ddcController.setInput(PhilipsDDCController.displayPortInput)
        _ = try await waitForMacBaseline(operationID: operationID)
      } catch {
        ddcError = error
      }
      if try await stateStore.softDisconnectState() == nil {
        try await softController.disconnectPhilips()
      }
    case .windows:
      break
    case .unknown:
      throw DisplayControlError.verification("回滚时拓扑已经未知")
    }
    let final = await displayController.snapshot()
    guard final.topology == .windows else {
      throw DisplayControlError.verification("回滚后没有恢复 Windows 两屏终态")
    }
    try await restoreDesktopIconsIfNeeded(report: final)
    try await stateStore.clearDesktopIconLayoutState()
    if let ddcError {
      throw ddcError
    }
  }

  private func beginTransactionProtectingDesktopIcons(
    display: DisplayRecord,
    operationID: UUID,
    target: SwitchTarget
  ) async throws -> SwitchTransactionState {
    let desktopIconLayout = try await desktopIconController.capture(on: display)
    let transaction = makeTransaction(
      operationID: operationID,
      target: target,
      phase: .desktopIconsCaptured
    )
    do {
      try await stateStore.save(desktopIconLayoutState: desktopIconLayout)
      try await stateStore.save(transaction: transaction)
      return transaction
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      do {
        try await stateStore.clearDesktopIconLayoutState()
      } catch let cleanupError {
        throw DisplayControlError.rollback(
          "无法建立切换事务：\(error)；图标快照清理失败：\(cleanupError)"
        )
      }
      throw error
    }
  }

  private func restoreDesktopIconsIfNeeded(report: ProbeReport) async throws {
    guard let state = try await stateStore.desktopIconLayoutState() else { return }
    let matches = report.displays.filter { $0.role == .viewSonic && $0.isActive }
    guard matches.count == 1 else {
      throw DisplayControlError.verification("恢复桌面图标时无法唯一识别 ViewSonic")
    }
    let viewSonic = matches[0]
    try await displayController.requireProtectedViewSonic(viewSonic)
    try await desktopIconController.restore(state, on: viewSonic)
  }

  private func waitForMacBaseline(
    operationID: UUID,
    timeout: Duration = .seconds(8)
  ) async throws -> ProbeReport {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var consecutiveMatches = 0
    var latest = await displayController.snapshot()
    while clock.now < deadline {
      try validate(operationID)
      latest = await displayController.snapshot()
      if latest.topology == .mac, latest.passed {
        consecutiveMatches += 1
        if consecutiveMatches >= 3 {
          return latest
        }
      } else {
        consecutiveMatches = 0
      }
      try await Task.sleep(for: .milliseconds(150))
    }
    let failures = latest.checks.filter { !$0.passed }.map(\.name).joined(separator: ", ")
    throw DisplayControlError.verification(
      "8 秒内没有稳定到完整 Mac 三屏基线：\(failures)"
    )
  }

  private func beginOperation() throws -> UUID {
    guard activeOperationID == nil else {
      throw DisplayControlError.busy
    }
    let lease = try DisplayOperationLease()
    let operationID = UUID()
    operationLease = lease
    activeOperationID = operationID
    return operationID
  }

  private func validate(_ operationID: UUID) throws {
    try Task.checkCancellation()
    guard activeOperationID == operationID else {
      throw DisplayControlError.staleOperation
    }
  }

  private func endOperation(_ operationID: UUID) {
    guard activeOperationID == operationID else {
      return
    }
    operationLease = nil
    activeOperationID = nil
  }

  private func makeTransaction(
    operationID: UUID,
    target: SwitchTarget,
    phase: SwitchPhase
  ) -> SwitchTransactionState {
    SwitchTransactionState(
      schemaVersion: 1,
      createdAt: ISO8601DateFormatter().string(from: Date()),
      operationID: operationID,
      target: target,
      phase: phase
    )
  }

}
