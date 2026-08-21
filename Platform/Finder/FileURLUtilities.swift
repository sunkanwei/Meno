import Foundation

extension URL {
    var isInTrashLocation: Bool {
        pathComponents.contains(".Trash") || pathComponents.contains(".Trashes")
    }
}

extension Array where Element == URL {
    func normalizedFileURLs() -> [URL] {
        Array(Set(filter(\.isFileURL).map(\.standardizedFileURL)))
            .sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
    }

    func allExist() -> Bool {
        allSatisfy { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
}
