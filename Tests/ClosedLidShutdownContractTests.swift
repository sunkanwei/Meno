import Foundation
import XCTest

final class ClosedLidShutdownContractTests: XCTestCase {
    func testCompatibilityIsRestrictedToVerifiedMajorVersions() {
        XCTAssertTrue(ClosedLidShutdownContract.supports(majorVersion: 26))
        XCTAssertTrue(ClosedLidShutdownContract.supports(majorVersion: 27))
        XCTAssertFalse(ClosedLidShutdownContract.supports(majorVersion: 25))
        XCTAssertFalse(ClosedLidShutdownContract.supports(majorVersion: 28))
    }

    func testLaunchDaemonValidationAcceptsOnlyExactConfiguration() {
        let expected = ClosedLidShutdownContract.launchDaemonPropertyList
        XCTAssertTrue(ClosedLidShutdownValidation.launchDaemonPropertyListIsValid(expected))

        var wrongProgram = expected
        wrongProgram["ProgramArguments"] = ["/tmp/untrusted-helper"]
        XCTAssertFalse(
            ClosedLidShutdownValidation.launchDaemonPropertyListIsValid(wrongProgram)
        )

        var extraPrivilege = expected
        extraPrivilege["UserName"] = "root"
        XCTAssertFalse(
            ClosedLidShutdownValidation.launchDaemonPropertyListIsValid(extraPrivilege)
        )

        var unconditionalKeepAlive = expected
        unconditionalKeepAlive["KeepAlive"] = true
        XCTAssertFalse(
            ClosedLidShutdownValidation.launchDaemonPropertyListIsValid(unconditionalKeepAlive)
        )

        var restartAfterOrdinaryFailure = expected
        restartAfterOrdinaryFailure["KeepAlive"] = ["SuccessfulExit": false]
        XCTAssertFalse(
            ClosedLidShutdownValidation.launchDaemonPropertyListIsValid(
                restartAfterOrdinaryFailure
            )
        )

        var extraRestartCondition = expected
        extraRestartCondition["KeepAlive"] = [
            "Crashed": true,
            "SuccessfulExit": false
        ]
        XCTAssertFalse(
            ClosedLidShutdownValidation.launchDaemonPropertyListIsValid(
                extraRestartCondition
            )
        )
    }

    func testRegularFileValidationRejectsSymbolicLinks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("helper")
        let link = directory.appendingPathComponent("helper-link")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("test".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        XCTAssertTrue(
            ClosedLidShutdownValidation.isRegularFileWithoutFollowingLinks(at: file.path)
        )
        XCTAssertFalse(
            ClosedLidShutdownValidation.isRegularFileWithoutFollowingLinks(at: link.path)
        )
    }

    func testPowerModeConfigurationRejectsMalformedPropertyLists() throws {
        let validData = try PropertyListSerialization.data(
            fromPropertyList: [ClosedLidShutdownContract.modeKey: "shutdown"],
            format: .binary,
            options: 0
        )
        XCTAssertEqual(PowerModeConfiguration.decode(validData)?.mode, "shutdown")

        let wrongTypeData = try PropertyListSerialization.data(
            fromPropertyList: [ClosedLidShutdownContract.modeKey: 1],
            format: .binary,
            options: 0
        )
        XCTAssertNil(PowerModeConfiguration.decode(wrongTypeData))
        XCTAssertNil(PowerModeConfiguration.decode(Data("not a plist".utf8)))
    }
}
