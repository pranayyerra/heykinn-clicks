import Foundation
import UniformTypeIdentifiers

struct ImportResult {
    var batch: ImportBatch
    var importedAssets: [Asset]
    var duplicateFilenames: [String]
    var failures: [(filename: String, error: String)]
    /// Replicas already satisfied by the import source itself — assets whose
    /// source file lives on a managed drive (e.g. inside a Takeout folder)
    /// count that file as the drive's replica instead of copying a duplicate
    /// onto the same disk. Keyed by asset ID.
    var archiveBackedReplicas: [UUID: DriveReplicaState] = [:]
}

/// Import pipeline: scan → hash → dedupe check → classify → stage → catalog.
/// Runs with zero drives connected; Local-resident files land in staging and
/// replication tasks are queued per registered drive for later.
enum ImportService {
    static func mediaFileURLs(under rootURLs: [URL]) -> [URL] {
        var files: [URL] = []
        for root in rootURLs {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                if MetadataExtractor.kind(forFileExtension: root.pathExtension) != .unknown {
                    files.append(root)
                }
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let item = enumerator?.nextObject() as? URL {
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                if MetadataExtractor.kind(forFileExtension: item.pathExtension) != .unknown {
                    files.append(item)
                }
            }
        }
        return files
    }

    /// Imports one batch. `existingAssets` is the current catalog snapshot used
    /// for exact-duplicate rejection; duplicates are reported, never merged.
    static func importFiles(
        _ fileURLs: [URL],
        sourceDescription: String,
        existingAssets: [Asset],
        policyRules: [PolicyRule],
        staging: StagingStore
    ) -> ImportResult {
        var batch = ImportBatch(
            id: UUID(),
            sourcePath: sourceDescription,
            startedAt: Date(),
            completedAt: nil,
            importedCount: 0,
            duplicateCount: 0,
            failedCount: 0
        )
        var imported: [Asset] = []
        var duplicates: [String] = []
        var failures: [(String, String)] = []
        var knownHashes = Set(existingAssets.map(\.contentHash))

        for fileURL in fileURLs {
            let filename = fileURL.lastPathComponent
            do {
                let hash = try HashingService.sha256(of: fileURL)
                if knownHashes.contains(hash) {
                    duplicates.append(filename)
                    continue
                }

                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fileSize = (attributes[.size] as? Int64) ?? 0
                let metadata = MetadataExtractor.extract(from: fileURL)
                let origin = PolicyEngine.classifyOrigin(
                    filename: filename,
                    folderHint: fileURL.deletingLastPathComponent().path
                )
                let decision = PolicyEngine.assignResidency(
                    kind: metadata.kind,
                    origin: origin,
                    fileSize: fileSize,
                    rules: policyRules
                )

                let assetID = UUID()
                var presence = DomainPresence.none
                var stagingPath: String?
                // Every import lands in staging first — even for cloud-destined
                // assets the file exists locally until the user completes the
                // cloud upload workflow. For Local residency, staging *is* the
                // authoritative first copy.
                stagingPath = try staging.stage(
                    fileAt: fileURL,
                    assetID: assetID,
                    fileExtension: fileURL.pathExtension.lowercased()
                )
                presence.local = true

                let now = Date()
                let asset = Asset(
                    id: assetID,
                    kind: metadata.kind,
                    originalFilename: filename,
                    importOrigin: origin,
                    captureDate: metadata.captureDate,
                    importDate: now,
                    updatedDate: now,
                    fileSize: fileSize,
                    pixelWidth: metadata.pixelWidth,
                    pixelHeight: metadata.pixelHeight,
                    contentHash: hash,
                    residency: decision.residency,
                    residencySource: decision.source,
                    presence: presence,
                    stagingRelativePath: stagingPath,
                    importBatchID: batch.id,
                    exifSummary: metadata.exifSummary
                )
                imported.append(asset)
                knownHashes.insert(hash)
            } catch {
                failures.append((filename, error.localizedDescription))
            }
        }

        batch.completedAt = Date()
        batch.importedCount = imported.count
        batch.duplicateCount = duplicates.count
        batch.failedCount = failures.count
        return ImportResult(
            batch: batch,
            importedAssets: imported,
            duplicateFilenames: duplicates,
            failures: failures.map { (filename: $0.0, error: $0.1) }
        )
    }
}
