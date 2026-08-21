@MainActor
extension AppModel {
    func wakeWindows(onFailure: @escaping (String) -> Void) {
        do {
            try WakeOnLANSender.sendMagicPacket(to: .windows)
        } catch {
            onFailure(error.localizedDescription)
        }
    }
}
