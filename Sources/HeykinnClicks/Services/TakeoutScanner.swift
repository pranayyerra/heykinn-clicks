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
        ReplicationTarget.appFolderName,
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
                // "Takeout" and its extraction-collision variants, or a folder
                // named after the zip it came out of.
                if isUnpackedTakeoutFolderName(name) {
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

    /// A folder that is an unpacked Takeout, by either of the two names one can
    /// end up with: the plain `Takeout` macOS writes when the zip is opened —
    /// including the names it picks when one is already there, "Takeout 2",
    /// "Takeout (1)", "takeout-3", "Takeout2" — or the zip's own name minus
    /// `.zip`, which is what a folder extracted deliberately per part is called.
    ///
    /// Anything else is a name a person chose, and a name a person chose is not
    /// evidence of anything. The rule used to be "starts with takeout, and the
    /// next character is not a letter", which swallowed `Takeout_Archive_2026`
    /// — a folder somebody made to keep their export *in*. That registered the
    /// container of a whole 254 GB archive as a single archive of its own:
    /// double-counted in every total, shown as an export belonging to no set,
    /// and reporting that it imported nothing, because everything in it had
    /// already been imported as the parts it is made of.
    static func isUnpackedTakeoutFolderName(_ name: String) -> Bool {
        nameLooksLikeTakeout(name) || TakeoutArchive.parseExportComponents(filename: name) != nil
    }

    /// Whether this one directory is an unpacked Google export, by name or by
    /// what it contains — the question `scan` answers as it walks, asked about
    /// a single directory somebody has just chosen.
    ///
    /// Both halves of the rule live here so the scanner and anything guarding
    /// against a Takeout arriving down the wrong path agree on what one is. A
    /// folder import that swallows an export is not a small mistake: the export
    /// machinery keeps thousands of replicas backed by a handful of files, and
    /// importing the tree loose throws that away and copies every photo
    /// individually instead.
    static func looksLikeTakeoutRoot(_ url: URL) -> Bool {
        if isUnpackedTakeoutFolderName(url.lastPathComponent) { return true }
        // Renamed roots are caught structurally, the same way `scan` catches
        // them: a "Google Photos" directory marks its parent as a root, and a
        // folder that *is* one is a root itself.
        if url.lastPathComponent.caseInsensitiveCompare("Google Photos") == .orderedSame { return true }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return children.contains { child in
            (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                && child.lastPathComponent.caseInsensitiveCompare("Google Photos") == .orderedSame
        }
    }

    /// The collision-variant half: after dropping the separators macOS uses,
    /// what follows "takeout" must be empty or a number.
    static func nameLooksLikeTakeout(_ name: String) -> Bool {
        let lowered = name.lowercased()
        guard lowered.hasPrefix("takeout") else { return false }
        let tail = lowered.dropFirst("takeout".count)
            .filter { !" -_()".contains($0) }
        return tail.isEmpty || tail.allSatisfy(\.isNumber)
    }

    /// Peeks at the zip's own listing and checks whether its entries are rooted
    /// at `Takeout/` — catches renamed Takeout downloads.
    ///
    /// This one was never affected by `unzip`'s name mangling, since it only
    /// compares an ASCII prefix. It reads the archive directly anyway: one less
    /// subprocess, and one less thing that only works on macOS.
    static func zipListingLooksLikeTakeout(_ url: URL) -> Bool {
        let entries = ZipTools.listEntries(inZip: url).prefix(20)
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
