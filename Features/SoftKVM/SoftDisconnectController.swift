import Foundation

actor SoftDisconnectController {
  private let displayController: DisplayHardwareController
  private let stateStore: DisplayStateStore
  private var activeOperationID: UUID?

  init(
    displayController: DisplayHardwareController,
    stateStore: DisplayStateStore
  ) {
    self.displayController = displayController
    self.stateStore = stateStore
  }

  func disconnectPhilips() async throws {
    let operationID = try beginOperation()
    defer { endOperation(operationID) }
    try await displayController.requireBetterDisplayStopped()
    let report = await displayController.snapshot()
    guard report.passed else {
      let failures = report.checks.filter { !$0.passed }.map(\.name).joined(separator: ", ")
      throw DisplayControlError.preflight("三屏基线未通过：\(failures)")
    }
    guard try await stateStore.softDisconnectState() == nil else {
      throw DisplayControlError.state("已有未完成快照，请先恢复到 Mac")
    }
    guard let baseline = SoftKVMMacBaseline.resolve(report.displays) else {
      throw DisplayControlError.preflight("Philips、ViewSonic 或三屏排列无法唯一识别")
    }
    try await displayController.requireSafePhilips(baseline.philips)
    try await displayController.requireProtectedViewSonic(baseline.viewSonic)

    let state = SoftDisconnectState(
      schemaVersion: 1,
      createdAt: ISO8601DateFormatter().string(from: Date()),
      philips: baseline.philips,
      topologyPlan: baseline.topologyPlan
    )
    try await stateStore.save(softDisconnectState: state)
    do {
      try validate(operationID)
      try await displayController.setPhilipsEnabled(
        runtimeID: baseline.philips.runtimeID,
        enabled: false
      )
      let windowsReport = try await waitForTopology(
        expectedActiveCount: 2,
        targetID: baseline.philips.runtimeID,
        targetShouldBeActive: false,
        operationID: operationID
      )
      try await restoreRemainingMacDisplayPlacement(
        state: state,
        report: windowsReport,
        operationID: operationID
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      do {
        let current = await displayController.snapshot()
        if current.displays.first(where: {
          $0.runtimeID == baseline.philips.runtimeID
        })?.isActive == false {
          try await displayController.setPhilipsEnabled(
            runtimeID: baseline.philips.runtimeID,
            enabled: true
          )
          _ = try await waitForTopology(
            expectedActiveCount: 3,
            targetID: baseline.philips.runtimeID,
            targetShouldBeActive: true,
            operationID: operationID
          )
        }
        try await stateStore.clearSoftDisconnectState()
      } catch let rollbackError {
        throw DisplayControlError.rollback(
          "原错误：\(error)；回滚错误：\(rollbackError)；恢复快照已保留"
        )
      }
      throw error
    }
  }

  func stabilizeWindowsTopology() async throws {
    let operationID = try beginOperation()
    defer { endOperation(operationID) }
    guard let savedState = try await stateStore.softDisconnectState() else { return }
    let report = await displayController.snapshot()
    guard report.topology == .windows,
      let windowsTopology = SoftKVMWindowsTopology.resolve(report.displays)
    else {
      return
    }
    let topologyPlan = try savedState.resolvedTopologyPlan(
      currentMainDisplay: windowsTopology.mainDisplay
    )
    let state = savedState.topologyPlan == nil
      ? savedState.withTopologyPlan(topologyPlan)
      : savedState
    if savedState.topologyPlan == nil {
      try await stateStore.save(softDisconnectState: state)
    }
    try await restoreRemainingMacDisplayPlacement(
      state: state,
      report: report,
      operationID: operationID
    )
  }

  func reconnectPhilips() async throws {
    let operationID = try beginOperation()
    defer { endOperation(operationID) }
    try await displayController.requireBetterDisplayStopped()
    guard let state = try await stateStore.softDisconnectState() else {
      let report = await displayController.snapshot()
      if report.passed {
        return
      }
      throw DisplayControlError.state("没有恢复快照，且当前不是完整三屏状态")
    }

    let report = await displayController.snapshot()
    guard let candidate = report.displays.single(where: {
      $0.role == .philips && displayController.identityMatches($0, state.philips)
    }) else {
      throw DisplayControlError.state("全量列表中找不到快照对应的 Philips 硬件身份")
    }
    try await displayController.requireSafePhilips(candidate)
    if candidate.isActive {
      guard report.topology == .mac,
        report.passed,
        let baseline = SoftKVMMacBaseline.resolve(report.displays),
        displayController.identityMatches(baseline.philips, state.philips)
      else {
        throw DisplayControlError.verification("Philips 已活动，但当前三屏基线不完整")
      }
      if let expectedPlan = state.topologyPlan,
        baseline.topologyPlan != expectedPlan
      {
        throw DisplayControlError.verification("恢复后的三屏左右顺序与切换前快照不一致")
      }
      try await stateStore.clearSoftDisconnectState()
      return
    }
    guard let windowsTopology = SoftKVMWindowsTopology.resolve(report.displays) else {
      throw DisplayControlError.verification("恢复前的 Windows 两屏拓扑不完整")
    }
    let expectedPlan = try state.resolvedTopologyPlan(
      currentMainDisplay: windowsTopology.mainDisplay
    )

    do {
      try validate(operationID)
      try await displayController.setPhilipsEnabled(runtimeID: candidate.runtimeID, enabled: true)
      let finalReport = try await waitForTopology(
        expectedActiveCount: 3,
        targetID: candidate.runtimeID,
        targetShouldBeActive: true,
        operationID: operationID
      )
      guard finalReport.passed,
        SoftKVMMacBaseline.resolve(finalReport.displays)?.topologyPlan == expectedPlan
      else {
        throw DisplayControlError.verification("恢复后三屏完整基线或左右顺序未通过")
      }
      try await stateStore.clearSoftDisconnectState()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      do {
        let current = await displayController.snapshot()
        if current.displays.first(where: { $0.runtimeID == candidate.runtimeID })?.isActive == true {
          try await displayController.setPhilipsEnabled(runtimeID: candidate.runtimeID, enabled: false)
          let windowsReport = try await waitForTopology(
            expectedActiveCount: 2,
            targetID: candidate.runtimeID,
            targetShouldBeActive: false,
            operationID: operationID
          )
          try await restoreRemainingMacDisplayPlacement(
            state: state.withTopologyPlan(expectedPlan),
            report: windowsReport,
            operationID: operationID
          )
        }
      } catch let rollbackError {
        throw DisplayControlError.rollback(
          "原错误：\(error)；回滚到 Windows 状态失败：\(rollbackError)；恢复快照已保留"
        )
      }
      throw error
    }
  }

  private func waitForTopology(
    expectedActiveCount: Int,
    targetID: UInt32,
    targetShouldBeActive: Bool,
    operationID: UUID
  ) async throws -> ProbeReport {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    var consecutiveMatches = 0
    var latest = await displayController.snapshot()
    while clock.now < deadline {
      try validate(operationID)
      latest = await displayController.snapshot()
      guard let viewSonic = latest.displays.first(where: { $0.role == .viewSonic }) else {
        throw DisplayControlError.verification("切换期间 ViewSonic 无法识别")
      }
      try await displayController.requireProtectedViewSonic(viewSonic)
      guard let target = latest.displays.first(where: { $0.runtimeID == targetID }) else {
        throw DisplayControlError.verification("切换期间全量列表丢失 Philips ID \(targetID)")
      }
      try await displayController.requireSafePhilips(target)
      guard latest.displays.contains(where: { $0.role == .builtIn && $0.isActive }) else {
        throw DisplayControlError.verification("切换期间内屏不再活动")
      }
      let activeCount = latest.displays.filter(\.isActive).count
      let expectedTopology: DisplayTopologyState = targetShouldBeActive ? .mac : .windows
      if target.isActive == targetShouldBeActive,
        activeCount == expectedActiveCount,
        latest.topology == expectedTopology
      {
        consecutiveMatches += 1
        if consecutiveMatches >= 3 {
          return latest
        }
      } else {
        consecutiveMatches = 0
      }
      try await Task.sleep(for: .milliseconds(150))
    }
    let activeIDs = latest.displays.filter(\.isActive).map(\.runtimeID)
    throw DisplayControlError.verification(
      "10 秒内没有稳定到目标拓扑；当前活动 ID：\(activeIDs)"
    )
  }

  private func restoreRemainingMacDisplayPlacement(
    state: SoftDisconnectState,
    report: ProbeReport,
    operationID: UUID
  ) async throws {
    try validate(operationID)
    guard let windowsTopology = SoftKVMWindowsTopology.resolve(report.displays) else {
      throw DisplayControlError.verification("Windows 状态下无法唯一识别两块 Mac 显示器")
    }
    try await displayController.requireProtectedViewSonic(windowsTopology.viewSonic)
    let topologyPlan = try state.resolvedTopologyPlan(
      currentMainDisplay: windowsTopology.mainDisplay
    )
    let targetOriginX = topologyPlan.originXForLocalDisplay(
      mainOriginX: windowsTopology.mainDisplay.originX,
      mainWidth: windowsTopology.mainDisplay.width,
      localWidth: windowsTopology.localDisplay.width
    )
    guard windowsTopology.localDisplay.originX != targetOriginX else { return }
    try await displayController.setDisplayOrigin(
      runtimeID: windowsTopology.localDisplay.runtimeID,
      x: targetOriginX,
      y: windowsTopology.localDisplay.originY
    )
    _ = try await waitForRemainingMacDisplayPlacement(
      topologyPlan: topologyPlan,
      operationID: operationID
    )
  }

  private func waitForRemainingMacDisplayPlacement(
    topologyPlan: SoftKVMTopologyPlan,
    operationID: UUID
  ) async throws -> ProbeReport {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    var consecutiveMatches = 0
    var latest = await displayController.snapshot()
    while clock.now < deadline {
      try validate(operationID)
      latest = await displayController.snapshot()
      if latest.topology == .windows,
        let topology = SoftKVMWindowsTopology.resolve(latest.displays),
        topology.localDisplaySide == topologyPlan.localDisplaySide
      {
        consecutiveMatches += 1
        if consecutiveMatches >= 3 { return latest }
      } else {
        consecutiveMatches = 0
      }
      try await Task.sleep(for: .milliseconds(150))
    }
    throw DisplayControlError.verification(
      "5 秒内没有恢复内屏与 ViewSonic 的物理左右顺序"
    )
  }

  private func beginOperation() throws -> UUID {
    guard activeOperationID == nil else {
      throw DisplayControlError.busy
    }
    let operationID = UUID()
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
    activeOperationID = nil
  }
}
