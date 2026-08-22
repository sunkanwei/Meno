import Foundation

extension NSLock {
    func withCriticalSection<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
