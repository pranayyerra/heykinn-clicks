import Foundation

/// The Mac-side staging/cache area for Local-resident assets. Files land here
/// at import and remain until replicated (and beyond, as a cache) — so imports
/// work with zero targets connected.
struct StagingStore {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    static func defaultStore() -> StagingStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return StagingStore(rootURL: support.appendingPathComponent("HeykinnClicks/Staging", isDirectory: true))
    }

    /// Copies a source file into staging under a stable, asset-derived name.
    /// Returns the staging-relative path. Content-addressed-ish layout keeps
    /// directories small: Staging/ab/<assetID>.<ext>
    func stage(fileAt sourceURL: URL, assetID: UUID, fileExtension: String) throws -> String {
        let bucket = String(assetID.uuidString.prefix(2)).lowercased()
        let name = fileExtension.isEmpty ? assetID.uuidString : "\(assetID.uuidString).\(fileExtension)"
        let relativePath = "\(bucket)/\(name)"
        let destination = url(forRelativePath: relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return relativePath
    }

    func url(forRelativePath relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    func exists(relativePath: String?) -> Bool {
        guard let relativePath else { return false }
        return FileManager.default.fileExists(atPath: url(forRelativePath: relativePath).path)
    }

    func remove(relativePath: String) throws {
        let target = url(forRelativePath: relativePath)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        // The file is gone; its bucket usually is too. Staging buckets are the
        // same two-hex-character layout as replica buckets and were left behind
        // by the same oversight — a reclaimed staging area kept up to 256 empty
        // directories, which is what the user sees when they open the folder.
        pruneEmptyBucket(target.deletingLastPathComponent())
    }

    /// Removes a staging bucket directory that has nothing left in it.
    ///
    /// The same narrow contract as `ReplicationService.pruneEmptyBucket`:
    /// refuses anything that is not *strictly inside* the staging root, so a
    /// caller passing the wrong directory cannot reach a path the user owns,
    /// and never removes the root itself — `stage` recreates buckets on demand
    /// but relies on the root being there.
    ///
    /// Failure is silent. An empty directory left behind is untidy; nothing
    /// about the archive is wrong because of it.
    private func pruneEmptyBucket(_ directory: URL) {
        let root = rootURL.standardizedFileURL.path
        let target = directory.standardizedFileURL.path
        guard target != root, target.hasPrefix(root + "/") else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: []
        ) else { return }
        guard contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes every empty bucket under the staging root.
    ///
    /// The sweep for buckets earlier versions left behind, which `remove`
    /// alone never revisits. Bounded by the number of buckets (256), not by
    /// the number of files staged.
    @discardableResult
    func pruneEmptyBuckets() -> Int {
        guard let buckets = try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return 0 }
        var removed = 0
        for bucket in buckets {
            let isDirectory = (try? bucket.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            guard isDirectory == true else { continue }
            let before = FileManager.default.fileExists(atPath: bucket.path)
            pruneEmptyBucket(bucket)
            if before, !FileManager.default.fileExists(atPath: bucket.path) { removed += 1 }
        }
        return removed
    }

    var totalBytes: Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
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
