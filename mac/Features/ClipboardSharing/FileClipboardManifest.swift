import Darwin
import Foundation

struct FileClipboardSourceManifest: Sendable {
    let offer: FileClipboardOffer
    let sourceURLs: [URL]
}

struct FileClipboardReceiveLayout: Sendable {
    let rootURL: URL
    let itemURLs: [URL]
    let topLevelURLs: [URL]
}

enum FileClipboardManifestError: Error {
    case invalidSelection
    case unsupportedItem
    case sourceUnavailable
    case limitsExceeded
    case unsafeDestination
    case insufficientSpace
}

enum FileClipboardManifestBuilder {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isSymbolicLinkKey,
        .isDirectoryKey,
        .isRegularFileKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .isHiddenKey,
    ]

    static func build(from selectedURLs: [URL], transferID: UUID) throws -> FileClipboardSourceManifest {
        var uniqueURLs: [URL] = []
        var seen = Set<String>()
        for url in selectedURLs where url.isFileURL {
            let standardized = url.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                uniqueURLs.append(standardized)
            }
        }
        guard !uniqueURLs.isEmpty,
              uniqueURLs.count <= FileClipboardWire.maximumRootCount else {
            throw FileClipboardManifestError.invalidSelection
        }

        var entries: [FileClipboardEntry] = []
        var sourceURLs: [URL] = []
        var totalBytes: UInt64 = 0
        var encodedSize = 28

        func append(_ url: URL, parentIndex: UInt32?, depth: Int) throws {
            guard depth <= FileClipboardWire.maximumDepth,
                  entries.count < FileClipboardWire.maximumEntryCount else {
                throw FileClipboardManifestError.limitsExceeded
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: resourceKeys)
            } catch {
                throw FileClipboardManifestError.sourceUnavailable
            }
            guard values.isSymbolicLink != true else {
                throw FileClipboardManifestError.unsupportedItem
            }
            let isDirectory = values.isDirectory == true
            let isFile = values.isRegularFile == true
            guard isDirectory || isFile else {
                throw FileClipboardManifestError.unsupportedItem
            }

            let name = url.lastPathComponent
            let nameSize = Data(name.utf8).count
            guard FileClipboardWire.isValidName(name),
                  nameSize <= FileClipboardWire.maximumNameSize else {
                throw FileClipboardManifestError.limitsExceeded
            }
            encodedSize += 24 + nameSize
            guard encodedSize <= FileClipboardWire.maximumOfferSize else {
                throw FileClipboardManifestError.limitsExceeded
            }

            let modifiedMillis = milliseconds(values.contentModificationDate)
            let hidden = values.isHidden == true || name.hasPrefix(".")
            let flags = hidden ? FileClipboardEntry.hiddenFlag : 0
            let entryIndex = UInt32(entries.count)
            if isDirectory {
                entries.append(
                    FileClipboardEntry(
                        kind: .directory,
                        flags: flags,
                        parentIndex: parentIndex,
                        name: name,
                        size: 0,
                        modifiedMillis: modifiedMillis
                    )
                )
                sourceURLs.append(url)
                let children: [URL]
                do {
                    children = try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: Array(resourceKeys),
                        options: []
                    ).sorted { lhs, rhs in
                        lhs.lastPathComponent.utf8.lexicographicallyPrecedes(rhs.lastPathComponent.utf8)
                    }
                } catch {
                    throw FileClipboardManifestError.sourceUnavailable
                }
                for child in children {
                    try append(child, parentIndex: entryIndex, depth: depth + 1)
                }
            } else {
                guard let fileSize = values.fileSize, fileSize >= 0 else {
                    throw FileClipboardManifestError.sourceUnavailable
                }
                let size = UInt64(fileSize)
                let (sum, overflow) = totalBytes.addingReportingOverflow(size)
                guard !overflow,
                      sum <= FileClipboardWire.maximumLogicalBytes else {
                    throw FileClipboardManifestError.limitsExceeded
                }
                totalBytes = sum
                entries.append(
                    FileClipboardEntry(
                        kind: .regularFile,
                        flags: flags,
                        parentIndex: parentIndex,
                        name: name,
                        size: size,
                        modifiedMillis: modifiedMillis
                    )
                )
                sourceURLs.append(url)
            }
        }

        for url in uniqueURLs {
            try append(url, parentIndex: nil, depth: 1)
        }
        guard !entries.isEmpty else { throw FileClipboardManifestError.invalidSelection }
        return FileClipboardSourceManifest(
            offer: FileClipboardOffer(
                transferID: transferID,
                entries: entries,
                totalFileBytes: totalBytes
            ),
            sourceURLs: sourceURLs
        )
    }

    static func sourceStillMatches(_ sourceURL: URL, entry: FileClipboardEntry) -> Bool {
        let currentURL = URL(fileURLWithPath: sourceURL.path)
        guard let values = try? currentURL.resourceValues(forKeys: resourceKeys),
              values.isSymbolicLink != true else {
            return false
        }
        switch entry.kind {
        case .directory:
            guard values.isDirectory == true,
                  milliseconds(values.contentModificationDate) == entry.modifiedMillis else {
                return false
            }
        case .regularFile:
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize >= 0,
                  UInt64(fileSize) == entry.size,
                  milliseconds(values.contentModificationDate) == entry.modifiedMillis else {
                return false
            }
        }
        return true
    }

    private static func milliseconds(_ date: Date?) -> Int64 {
        guard let date else { return FileClipboardWire.unknownModifiedMillis }
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite,
              value >= Double(Int64.min + 1),
              value <= Double(Int64.max) else {
            return FileClipboardWire.unknownModifiedMillis
        }
        return Int64(value.rounded(.towardZero))
    }
}

enum FileClipboardDestinationMapper {
    static func makeLayout(for offer: FileClipboardOffer, rootURL: URL) throws -> FileClipboardReceiveLayout {
        let standardizedRoot = rootURL.standardizedFileURL
        let nameLimit = maximumNameBytes(at: standardizedRoot)
        var itemURLs: [URL] = []
        itemURLs.reserveCapacity(offer.entries.count)
        var topLevelURLs: [URL] = []
        var usedNames: [UInt32: Set<String>] = [:]
        var nextSuffixes: [UInt32: [String: Int]] = [:]

        for (index, entry) in offer.entries.enumerated() {
            let parentURL: URL
            let parentKey: UInt32
            if let parentIndex = entry.parentIndex {
                guard Int(parentIndex) < itemURLs.count else {
                    throw FileClipboardManifestError.unsafeDestination
                }
                parentURL = itemURLs[Int(parentIndex)]
                parentKey = parentIndex
            } else {
                parentURL = standardizedRoot
                parentKey = UInt32.max
            }

            let mappedName = uniqueName(
                entry.name,
                maximumBytes: nameLimit,
                usedKeys: &usedNames[parentKey, default: []],
                nextSuffixes: &nextSuffixes[parentKey, default: [:]]
            )
            let destination = parentURL.appendingPathComponent(mappedName, isDirectory: entry.kind == .directory)
            guard destination.standardizedFileURL.path.hasPrefix(standardizedRoot.path + "/") else {
                throw FileClipboardManifestError.unsafeDestination
            }
            itemURLs.append(destination)
            if entry.parentIndex == nil {
                topLevelURLs.append(destination)
            }
            if entry.kind == .directory {
                usedNames[UInt32(index)] = []
                nextSuffixes[UInt32(index)] = [:]
            }
        }
        return FileClipboardReceiveLayout(
            rootURL: standardizedRoot,
            itemURLs: itemURLs,
            topLevelURLs: topLevelURLs
        )
    }

    private static func maximumNameBytes(at rootURL: URL) -> Int {
        let value = rootURL.path.withCString { pathconf($0, _PC_NAME_MAX) }
        return value > 0 ? Int(value) : 255
    }

    private static func uniqueName(
        _ original: String,
        maximumBytes: Int,
        usedKeys: inout Set<String>,
        nextSuffixes: inout [String: Int]
    ) -> String {
        let baseKey = collisionKey(fittedName(original, suffix: "", maximumBytes: maximumBytes))
        var number = nextSuffixes[baseKey, default: 1]
        while number < Int.max {
            let suffix = number == 1 ? "" : " (\(number))"
            let candidate = fittedName(original, suffix: suffix, maximumBytes: maximumBytes)
            if usedKeys.insert(collisionKey(candidate)).inserted {
                nextSuffixes[baseKey] = number + 1
                return candidate
            }
            number += 1
        }
        preconditionFailure("Unable to allocate a unique destination name")
    }

    private static func fittedName(_ original: String, suffix: String, maximumBytes: Int) -> String {
        let nsName = original as NSString
        let pathExtension = nsName.pathExtension
        let isSimpleDotFile = original.hasPrefix(".") && !original.dropFirst().contains(".")
        let extensionPart = pathExtension.isEmpty || isSimpleDotFile ? "" : ".\(pathExtension)"
        let base = extensionPart.isEmpty ? original : nsName.deletingPathExtension
        let reserved = Data((suffix + extensionPart).utf8).count
        let available = max(1, maximumBytes - reserved)
        let fittedBase = truncateUTF8(base, maximumBytes: available)
        var result = fittedBase + suffix + extensionPart
        if Data(result.utf8).count > maximumBytes {
            result = truncateUTF8(fittedBase + suffix, maximumBytes: maximumBytes)
        }
        return result.isEmpty ? "_" : result
    }

    private static func truncateUTF8(_ value: String, maximumBytes: Int) -> String {
        var result = ""
        var count = 0
        for character in value {
            let text = String(character)
            let size = Data(text.utf8).count
            guard count + size <= maximumBytes else { break }
            result.append(character)
            count += size
        }
        return result
    }

    private static func collisionKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
