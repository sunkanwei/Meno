import Foundation

enum ScrollDirectionCompatibility {
    private static let supportedOSMajorVersions: Set<Int> = [26, 27]

    static func supports(majorVersion: Int) -> Bool {
        supportedOSMajorVersions.contains(majorVersion)
    }
}

enum ScrollInputSource: Equatable, Sendable {
    case builtInTrackpad
    case otherDevice
    case unknown
}

struct ScrollDeviceDescriptor: Equatable, Sendable {
    let isBuiltIn: Bool?
    let productName: String?
}

enum ScrollInputSourceClassifier {
    static func classify(_ descriptor: ScrollDeviceDescriptor) -> ScrollInputSource {
        let normalizedName = descriptor.productName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalizedName?.contains("trackpad") == true {
            if descriptor.isBuiltIn == true {
                return .builtInTrackpad
            }
            if descriptor.isBuiltIn == false {
                return .otherDevice
            }
            return .unknown
        }

        if descriptor.isBuiltIn == true {
            return .unknown
        }
        guard descriptor.isBuiltIn == false || normalizedName?.isEmpty == false else {
            return .unknown
        }
        return .otherDevice
    }
}

enum ScrollDirectionAction: Equatable, Sendable {
    case preserve
    case reverseVertical
}

enum ScrollDirectionPolicy {
    static func action(for source: ScrollInputSource) -> ScrollDirectionAction {
        switch source {
        case .builtInTrackpad, .unknown:
            return .preserve
        case .otherDevice:
            return .reverseVertical
        }
    }
}

enum ScrollingStatus: Equatable {
    case off
    case waitingForPermissions
    case running
    case failed(String)

    var detail: String {
        switch self {
        case .off:
            return "Meno 当前不调整滚轮方向。"
        case .waitingForPermissions:
            return "需要辅助功能和输入监听权限，才能区分并处理滚动事件。"
        case .running:
            return "内置触控板保持系统方向，其他滚轮设备反转垂直方向。"
        case let .failed(message):
            return message
        }
    }
}
