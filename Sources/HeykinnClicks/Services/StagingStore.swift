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
