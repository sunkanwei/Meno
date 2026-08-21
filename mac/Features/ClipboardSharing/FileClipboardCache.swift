import AppKit
import Foundation

private struct FileClipboardCacheMetadata: Codable {
    let transferID: UUID
    let logicalBytes: UInt64
    let entryCount: Int
    var completedAt: Date?
}

struct FileClipboardCacheEvictionCandidate: Equatable, Sendable {
    let path: String
    let logicalBytes: UInt64
    let entryCount: Int
    let completedAt: Date
    let isPinned: Bool
}

enum FileClipboardCacheEvictionPlanner {
    static func plan(
        completed: [FileClipboardCacheEvictionCandidate],
        hasUnaccountedRoots: Bool = false,
        incomingBytes: UInt64,
        incomingEntries: Int,
        byteQuota: UInt64,
        entryQuota: Int
    ) -> [String]? {
        guard !hasUnaccountedRoots,
              incomingEntries >= 0,
              entryQuota >= 0,
              incomingBytes <= byteQuota,
              incomingEntries <= entryQuota,
              completed.allSatisfy({ $0.entryCount >= 0 }) else { return nil }

        let completedBytes = completed.reduce(UInt64(0)) { total, candidate in
            let (sum, overflow) = total.addingReportingOverflow(candidate.logicalBytes)
            return overflow ? .max : sum
        }
        let completedEntries = completed.reduce(0) { total, candidate in
            let (sum, overflow) = total.addingReportingOverflow(candidate.entryCount)
            return overflow ? .max : sum
        }
        guard completedBytes != .max, completedEntries != .max else { return nil }

        var remainingBytes = completedBytes
        var remainingEntries = completedEntries
        let permittedBytes = byteQuota - incomingBytes
        let permittedEntries = entryQuota - incomingEntries
        guard remainingBytes > permittedBytes || remainingEntries > permittedEntries else {
            return []
        }

        var paths: [String] = []
        for candidate in completed
            .filter({ !$0.isPinned })
            .sorted(by: { $0.completedAt < $1.completedAt }) {
            paths.append(candidate.path)
            remainingBytes = remainingBytes >= candidate.logicalBytes
                ? remainingBytes - candidate.logicalBytes
                : 0
            remainingEntries = max(0, remainingEntries - candidate.entryCount)
            if remainingBytes <= permittedBytes, remainingEntries <= permittedEntries {
                return paths
            }
        }
        return nil
    }
}

enum FileClipboardDiskBudget {
    static func accepts(
        freeBytes: UInt64,
        incomingBytes: UInt64,
        minimumReserve: UInt64
    ) -> Bool {
        let (required, overflow) = incomingBytes.addingReportingOverflow(minimumReserve)
        return !overflow && freeBytes >= required
    }
}

enum FileClipboardCache {
    private struct CompletedRecord {
        let rootURL: URL
        let metadata: FileClipboardCacheMetadata
    }

    private struct Inventory {
        let completed: [CompletedRecord]
        let hasUnaccountedRoots: Bool
    }

    private static let cacheRetention: TimeInterval = 86_400
    private static let maximumCachedEntryCount = FileClipboardWire.maximumEntryCount
    private static let minimumFreeSpaceReserve: UInt64 = 1_024 * 1_024 * 1_024
    private static let metadataFileName = ".meno-transfer.plist"
    private static let stateLock = NSLock()
    private static let cleanupQueue = DispatchQueue(
        label: "com.sunkanwei.Meno.FileClipboardCache",
        qos: .utility
    )
    nonisolated(unsafe) private static var activeTransferID: UUID?
    nonisolated(unsafe) private static var protectedPaths = Set<String>()
    nonisolated(unsafe) private static var hasProtectedPathsSnapshot = false

    static func prepareIncomingTransfer(for offer: FileClipboardOffer) throws -> URL {
        guard offer.totalFileBytes <= FileClipboardWire.maximumLogicalBytes else {
            throw FileClipboardManifestError.insufficientSpace
        }
        return try stateLock.withCriticalSection {
            guard activeTransferID == nil else {
                throw FileClipboardManifestError.unsafeDestination
            }
            let cacheRoot = try rootURL()
            try FileManager.default.createDirectory(
                at: cacheRoot,
                withIntermediateDirectories: true
            )
            if hasProtectedPathsSnapshot {
                cleanupLocked(cacheRoot: cacheRoot, removeExpired: true)
            }
            try evictForQuotaLocked(
                cacheRoot: cacheRoot,
                incomingBytes: offer.totalFileBytes,
                incomingEntries: offer.entries.count
            )
            try ensureFreeSpaceLocked(for: offer.totalFileBytes, at: cacheRoot)

            let transferRoot = cacheRoot.appendingPathComponent(
                offer.transferID.uuidString.uppercased(),
                isDirectory: true
            )
            guard !FileManager.default.fileExists(atPath: transferRoot.path) else {
                throw FileClipboardManifestError.unsafeDestination
            }
            try FileManager.default.createDirectory(
                at: transferRoot,
                withIntermediateDirectories: false
            )
            do {
                try writeMetadata(
                    FileClipboardCacheMetadata(
                        transferID: offer.transferID,
                        logicalBytes: offer.totalFileBytes,
                        entryCount: offer.entries.count,
                        completedAt: nil
                    ),
                    at: transferRoot
                )
                activeTransferID = offer.transferID
                return transferRoot
            } catch {
                try? FileManager.default.removeItem(at: transferRoot)
                throw error
            }
        }
    }

    static func markCompleted(
        offer: FileClipboardOffer,
        layout: FileClipboardReceiveLayout
    ) throws {
        try stateLock.withCriticalSection {
            guard activeTransferID == offer.transferID,
                  isManagedTransferRoot(layout.rootURL, under: try rootURL()),
                  let metadata = readMetadata(at: layout.rootURL),
                  metadata.transferID == offer.transferID,
                  metadata.logicalBytes == offer.totalFileBytes,
                  metadata.entryCount == offer.entries.count else {
                throw FileClipboardManifestError.unsafeDestination
            }
            try writeMetadata(
                FileClipboardCacheMetadata(
                    transferID: metadata.transferID,
                    logicalBytes: metadata.logicalBytes,
                    entryCount: metadata.entryCount,
                    completedAt: Date()
                ),
                at: layout.rootURL
            )
            activeTransferID = nil
        }
    }

    static func createDestinationSkeleton(
        offer: FileClipboardOffer,
        layout: FileClipboardReceiveLayout
    ) throws {
        for (index, entry) in offer.entries.enumerated() {
            let url = layout.itemURLs[index]
            if entry.kind == .directory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else if !FileManager.default.createFile(atPath: url.path, contents: nil) {
                throw FileClipboardManifestError.unsafeDestination
            }
        }
    }

    static func applyMetadata(offer: FileClipboardOffer, layout: FileClipboardReceiveLayout) throws {
        for index in offer.entries.indices where offer.entries[index].kind == .regularFile {
            try applyMetadata(entry: offer.entries[index], to: layout.itemURLs[index])
        }
        for index in offer.entries.indices.reversed() where offer.entries[index].kind == .directory {
            try applyMetadata(entry: offer.entries[index], to: layout.itemURLs[index])
        }
    }

    static func safelyRemoveTransferRoot(_ url: URL) {
        stateLock.withCriticalSection {
            guard let root = try? rootURL(), isManagedTransferRoot(url, under: root) else { return }
            if activeTransferID?.uuidString.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame {
                activeTransferID = nil
            }
            try? FileManager.default.removeItem(at: url.standardizedFileURL)
        }
    }

    static func cleanupExpired() {
        Task { @MainActor in
            refreshProtectedPathsAndCleanup()
        }
    }

    @MainActor
    static func refreshProtectedPathsAndCleanup() {
        let objects = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let paths = Set(objects.map { $0.standardizedFileURL.path })
        stateLock.withCriticalSection {
            protectedPaths = paths
            hasProtectedPathsSnapshot = true
        }
        cleanupQueue.async {
            stateLock.withCriticalSection {
                guard let root = try? rootURL() else { return }
                cleanupLocked(cacheRoot: root, removeExpired: true)
            }
        }
    }

    private static func ensureFreeSpaceLocked(for bytes: UInt64, at root: URL) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        guard let freeNumber = attributes[.systemFreeSize] as? NSNumber,
              FileClipboardDiskBudget.accepts(
                freeBytes: freeNumber.uint64Value,
                incomingBytes: bytes,
                minimumReserve: minimumFreeSpaceReserve
              ) else {
            throw FileClipboardManifestError.insufficientSpace
        }
    }

    private static func evictForQuotaLocked(
        cacheRoot: URL,
        incomingBytes: UInt64,
        incomingEntries: Int
    ) throws {
        let inventory = inventory(in: cacheRoot)
        guard let paths = FileClipboardCacheEvictionPlanner.plan(
            completed: inventory.completed.map {
                FileClipboardCacheEvictionCandidate(
                    path: $0.rootURL.standardizedFileURL.path,
                    logicalBytes: $0.metadata.logicalBytes,
                    entryCount: $0.metadata.entryCount,
                    completedAt: $0.metadata.completedAt ?? .distantPast,
                    isPinned: isProtected($0.rootURL)
                )
            },
            hasUnaccountedRoots: inventory.hasUnaccountedRoots,
            incomingBytes: incomingBytes,
            incomingEntries: incomingEntries,
            byteQuota: FileClipboardWire.maximumLogicalBytes,
            entryQuota: maximumCachedEntryCount
        ), paths.isEmpty || hasProtectedPathsSnapshot else {
            throw FileClipboardManifestError.insufficientSpace
        }
        for path in paths {
            do {
                try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
            } catch {
                throw FileClipboardManifestError.insufficientSpace
            }
        }
    }

    private static func cleanupLocked(cacheRoot: URL, removeExpired: Bool) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return }

        let now = Date()
        for child in children {
            guard isManagedTransferRoot(child, under: cacheRoot),
                  let transferID = UUID(uuidString: child.lastPathComponent),
                  transferID != activeTransferID else { continue }
            guard let metadata = validMetadata(at: child, transferID: transferID),
                  let completedAt = metadata.completedAt else {
                if !isProtected(child) {
                    try? FileManager.default.removeItem(at: child)
                }
                continue
            }
            if removeExpired,
               now.timeIntervalSince(completedAt) >= cacheRetention,
               !isProtected(child) {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

    private static func inventory(in cacheRoot: URL) -> Inventory {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return Inventory(completed: [], hasUnaccountedRoots: true) }
        var completed: [CompletedRecord] = []
        var hasUnaccountedRoots = false
        for child in children {
            guard isManagedTransferRoot(child, under: cacheRoot),
                  let transferID = UUID(uuidString: child.lastPathComponent),
                  transferID != activeTransferID else { continue }
            guard let metadata = validMetadata(at: child, transferID: transferID),
                  metadata.completedAt != nil else {
                hasUnaccountedRoots = true
                continue
            }
            completed.append(CompletedRecord(
                rootURL: child.standardizedFileURL,
                metadata: metadata
            ))
        }
        return Inventory(
            completed: completed,
            hasUnaccountedRoots: hasUnaccountedRoots
        )
    }

    private static func validMetadata(
        at root: URL,
        transferID: UUID
    ) -> FileClipboardCacheMetadata? {
        guard let metadata = readMetadata(at: root),
              metadata.transferID == transferID,
              metadata.logicalBytes <= FileClipboardWire.maximumLogicalBytes,
              (1...FileClipboardWire.maximumEntryCount).contains(metadata.entryCount) else {
            return nil
        }
        return metadata
    }

    private static func isProtected(_ root: URL) -> Bool {
        let path = root.standardizedFileURL.path
        return protectedPaths.contains { $0 == path || $0.hasPrefix(path + "/") }
    }

    private static func isManagedTransferRoot(_ url: URL, under root: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent().path == root.standardizedFileURL.path,
              UUID(uuidString: standardized.lastPathComponent) != nil,
              let values = try? standardized.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func metadataURL(for root: URL) -> URL {
        root.appendingPathComponent(metadataFileName, isDirectory: false)
    }

    private static func readMetadata(at root: URL) -> FileClipboardCacheMetadata? {
        let url = metadataURL(for: root)
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true,
        let data = try? Data(contentsOf: url), data.count <= 16 * 1_024 else { return nil }
        return try? PropertyListDecoder().decode(FileClipboardCacheMetadata.self, from: data)
    }

    private static func writeMetadata(
        _ metadata: FileClipboardCacheMetadata,
        at root: URL
    ) throws {
        let data = try PropertyListEncoder().encode(metadata)
        guard data.count <= 16 * 1_024 else {
            throw FileClipboardManifestError.unsafeDestination
        }
        try data.write(to: metadataURL(for: root), options: .atomic)
    }

    private static func applyMetadata(entry: FileClipboardEntry, to url: URL) throws {
        if entry.modifiedMillis != FileClipboardWire.unknownModifiedMillis {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(
                    timeIntervalSince1970: Double(entry.modifiedMillis) / 1_000
                )],
                ofItemAtPath: url.path
            )
        }
        if entry.isHidden && !url.lastPathComponent.hasPrefix(".") {
            var values = URLResourceValues()
            values.isHidden = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        }
    }

    static func rootURL() throws -> URL {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw FileClipboardManifestError.unsafeDestination
        }
        let base = caches.standardizedFileURL
        let root = base
            .appendingPathComponent("com.sunkanwei.Meno", isDirectory: true)
            .appendingPathComponent("FileClipboard", isDirectory: true)
            .standardizedFileURL
        let expected = base.resolvingSymlinksInPath()
            .appendingPathComponent("com.sunkanwei.Meno", isDirectory: true)
            .appendingPathComponent("FileClipboard", isDirectory: true)
        guard root.resolvingSymlinksInPath().path == expected.path else {
            throw FileClipboardManifestError.unsafeDestination
        }
        return root
    }
}
