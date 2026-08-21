import Foundation

// Owns the timed shortcut-recognition test used by the settings page: while
// active it intercepts the next Soft KVM shortcut press and reports success
// instead of switching displays. Messages stay in the caller so presentation
// wording remains with the UI layer.
@MainActor
final class SoftKVMShortcutTestController {
    private var task: Task<Void, Never>?

    var onMessageChanged: ((String?) -> Void)?

    var isActive: Bool { task != nil }

    func begin(prompt: String, timeoutMessage: String) {
        cancel()
        onMessageChanged?(prompt)
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled else { return }
            task = nil
            onMessageChanged?(timeoutMessage)
        }
    }

    // Returns true when the press was consumed by the running test.
    func handleShortcutPressed(successMessage: String) -> Bool {
        guard task != nil else { return false }
        cancel()
        onMessageChanged?(successMessage)
        return true
    }

    func cancel() {
        task?.cancel()
        task = nil
        onMessageChanged?(nil)
    }
}
