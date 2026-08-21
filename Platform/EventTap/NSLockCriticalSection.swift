import Foundation

extension NSLock {
    func withCriticalSection<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}

final class EventTapOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false

    @discardableResult
    func perform(_ action: () -> Void) -> Bool {
        let shouldPerform = lock.withCriticalSection { () -> Bool in
            guard !consumed else { return false }
            consumed = true
            return true
        }
        if shouldPerform { action() }
        return shouldPerform
    }
}
