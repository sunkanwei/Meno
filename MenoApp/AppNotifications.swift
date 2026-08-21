import AppKit
import OSLog
@preconcurrency import UserNotifications

enum AppNotificationAuthorization: Equatable, Sendable {
    case checking
    case notDetermined
    case allowed
    case denied
    case bannersDisabled
    case unavailable

    var canShowBanner: Bool {
        self == .allowed
    }

    var needsSystemSettings: Bool {
        switch self {
        case .denied, .bannersDisabled, .unavailable:
            return true
        case .checking, .notDetermined, .allowed:
            return false
        }
    }
}

final class AppNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    // Preserve the original key so existing notification preferences survive this service rename.
    private let enabledKey = "FinderShortcutsNotificationsEnabled"
    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter
    private let logger = Logger(
        subsystem: "com.sunkanwei.Meno",
        category: "Notifications"
    )

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.center = .current()
        super.init()
        center.delegate = self
    }

    var isEnabled: Bool {
        defaults.bool(forKey: enabledKey)
    }

    func setEnabled(
        _ enabled: Bool,
        completion: @escaping @Sendable (AppNotificationAuthorization) -> Void
    ) {
        defaults.set(enabled, forKey: enabledKey)
        guard enabled else {
            refreshAuthorizationState(completion: completion)
            return
        }

        center.getNotificationSettings { [self] settings in
            guard settings.authorizationStatus == .notDetermined else {
                completion(Self.authorizationState(from: settings))
                return
            }

            center.requestAuthorization(options: [.alert, .sound]) { [self] _, requestError in
                center.getNotificationSettings { settings in
                    let state = Self.authorizationState(from: settings)
                    if requestError != nil, state == .notDetermined {
                        completion(.unavailable)
                    } else {
                        completion(state)
                    }
                }
            }
        }
    }

    func refreshAuthorizationState(
        completion: @escaping @Sendable (AppNotificationAuthorization) -> Void
    ) {
        center.getNotificationSettings { settings in
            completion(Self.authorizationState(from: settings))
        }
    }

    func openSystemSettings() {
        guard let notificationsURL = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else {
            return
        }
        NSWorkspace.shared.open(notificationsURL)
    }

    func sendTest(completion: @escaping @Sendable (Bool) -> Void) {
        guard isEnabled else {
            completion(false)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Meno"
        content.body = "测试通知已交由系统显示。"
        content.sound = .default
        submit(content, completion: completion)
    }

    func sendWindowsOnline() {
        guard isEnabled else {
            logger.info("Windows online notification skipped by user setting")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Windows 已启动"
        content.body = "Meno Windows 已上线并连接。"
        content.sound = .default
        submit(content) { [logger] submitted in
            logger.info("Windows online notification submitted: \(submitted)")
        }
    }

    func sendSoftKVMShortcutAcknowledgement(message: String) {
        guard isEnabled else {
            logger.info("Soft KVM shortcut notification skipped by user setting")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "软 KVM 快捷键已收到"
        content.body = message
        content.sound = .default
        submit(
            content,
            identifier: "com.sunkanwei.Meno.soft-kvm-shortcut"
        ) { [logger] submitted in
            logger.info("Soft KVM shortcut notification submitted: \(submitted)")
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func submit(
        _ content: UNNotificationContent,
        identifier: String = UUID().uuidString,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        center.getNotificationSettings { [center] settings in
            if Self.authorizationState(from: settings).canShowBanner {
                center.add(
                    UNNotificationRequest(
                        identifier: identifier,
                        content: content,
                        trigger: nil
                    )
                ) { error in
                    completion?(error == nil)
                }
            } else {
                completion?(false)
            }
        }
    }

    private static func authorizationState(
        from settings: UNNotificationSettings
    ) -> AppNotificationAuthorization {
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            guard settings.alertSetting == .enabled,
                  settings.alertStyle != .none else {
                return .bannersDisabled
            }
            return .allowed
        @unknown default:
            return .unavailable
        }
    }
}
