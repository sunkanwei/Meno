import Foundation
import IOKit.pwr_mgt

@MainActor
final class IdleSleepAssertion {
    private var assertionID = IOPMAssertionID(kIOPMNullAssertionID)

    var isHeld: Bool {
        assertionID != kIOPMNullAssertionID
    }

    func acquire() -> Bool {
        guard !isHeld else { return true }

        var newAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Meno closed-lid background operation" as CFString,
            &newAssertionID
        )
        guard result == kIOReturnSuccess else { return false }
        assertionID = newAssertionID
        return true
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(kIOPMNullAssertionID)
    }
}
