import Foundation

enum PreviewError: LocalizedError {
    case invalidEncoding
    case rendererResourceUnavailable
    case localResourceDenied

    var errorDescription: String? {
        switch self {
        case .invalidEncoding: "Markdown 文件不是有效的 UTF-8 文本。"
        case .rendererResourceUnavailable: "Markdown 渲染资源不可用。"
        case .localResourceDenied: "Markdown 引用的本地资源不允许读取。"
        }
    }
}
