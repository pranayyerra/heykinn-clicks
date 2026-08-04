import Foundation

/// Finds Google Takeout exports under a root (typically a managed drive's
/// mount point or a user-chosen folder). Detects:
/// - zips named `takeout-*.zip` (Google's standard naming),
/// - any other zip whose listing is rooted at `Takeout/`,
/// - already-extracted `Takeout` folders.
enum TakeoutScanner {

    struct DiscoveredArchive: Hashable {
        var path: String
        var kind: TakeoutArchiveKind
        var sizeBytes: Int64
        var exportSetID: String?
        var partNumber: Int?
    }

    /// Directories never descended into: our own managed structures.
    private static let excludedDirectoryNames: Set<String> = [
        ReplicationTarget.appFolderName, ReplicationTarget.legacyReplicaRoot,
        CatalogBackupService.legacyDirectoryName,
        "Staging", "TakeoutWork", ".Trashes", ".Spotlight-V100",
    ]

    /// `knownFolderSizes` lets a re-scan reuse sizes recorded at discovery
    /// instead of re-walking every file: a Takeout folder can hold tens of
    /// thousands of files, and re-measuring them on every scan dominated scan
    /// time on external targets.
    static func scan(rootURL: URL, knownFolderSizes: [String: Int64] = [:]) -> [DiscoveredArchive] {
        var discovered: [DiscoveredArchive] = []
        var discoveredPaths = Set<String>()
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        func addFolder(_ url: URL) {
            guard discoveredPaths.insert(url.path).inserted else { return }
            // A folder named like its source zip minus ".zip"
            // (takeout-<session>-<part>) joins that zip's export set.
            let components = TakeoutArchive.parseExportComponents(filename: url.lastPathComponent)
            discovered.append(DiscoveredArchive(
                path: url.path,
                kind: .folder,
                sizeBytes: knownFolderSizes[url.path] ?? directorySize(of: url),
                exportSetID: components?.setID,
                partNumber: components?.part
            ))
        }

        while let item = enumerator?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            let name = item.lastPathComponent

            if values?.isDirectory == true {
                if excludedDirectoryNames.contains(name) {
                    enumerator?.skipDescendants()
                    continue
                }
                // "Takeout", plus extraction-collision variants: "Takeout 2",
                // "Takeout (1)", "Takeout-3", "Takeout2".
                if nameLooksLikeTakeout(name) {
                    addFolder(item)
                    enumerator?.skipDescendants()
                    continue
                }
                // Renamed roots are caught structurally: a "Google Photos"
                // directory marks its parent as a Takeout-style root. When it
                // sits directly at the scan root, the Google Photos folder
                // itself is the candidate (never the mount point).
                if name.caseInsensitiveCompare("Google Photos") == .orderedSame {
                    let parent = item.deletingLastPathComponent()
                    addFolder(parent.path == rootURL.path ? item : parent)
                    enumerator?.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true, item.pathExtension.lowercased() == "zip" else { continue }
            let size = Int64(values?.fileSize ?? 0)
            if name.lowercased().hasPrefix("takeout") || zipListingLooksLikeTakeout(item) {
                let components = TakeoutArchive.parseExportComponents(filename: name)
                discovered.append(DiscoveredArchive(
                    path: item.path,
                    kind: .zip,
                    sizeBytes: size,
                    exportSetID: components?.setID,
                    partNumber: components?.part
                ))
            }
        }
        return discovered.sorted { $0.path < $1.path }
    }

    /// "takeout" optionally followed by a non-letter suffix: matches
    /// "Takeout", "Takeout 2", "Takeout (1)", "takeout-3", "Takeout2" —
    /// but not "takeouts".
    static func nameLooksLikeTakeout(_ name: String) -> Bool {
        let lowered = name.lowercased()
        guard lowered.hasPrefix("takeout") else { return false }
        let rest = lowered.dropFirst("takeout".count)
        guard let first = rest.first else { return true }
        return !first.isLetter
    }

    /// Peeks at the zip's file listing (via `unzip -Z1`) and checks whether its
    /// entries are rooted at `Takeout/` — catches renamed Takeout downloads.
    static func zipListingLooksLikeTakeout(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let listing = String(data: data, encoding: .utf8) else {
            return false
        }
        let entries = listing.split(separator: "\n").prefix(20)
        return !entries.isEmpty && entries.allSatisfy { $0.lowercased().hasPrefix("takeout/") }
    }

    static func directorySize(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
