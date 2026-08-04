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
    var archiveBackedReplicas: [UUID: TargetReplicaState] = [:]
    /// Assets whose winning rule targets a cloud domain. A rule cannot put
    /// content in a cloud — the caller opens a pending migration job per
    /// domain instead of writing an unsatisfiable residency.
    var cloudPlacements: [ResidencyDomain: [UUID]] = [:]
}

/// Import pipeline: scan → hash → dedupe check → classify → stage → catalog.
/// Runs with zero targets connected; Local-resident files land in staging and
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
    /// Shares the Takeout importer's machinery deliberately: parallel
    /// scanning, the full capture-date precedence chain, and archive-backed
    /// replicas. Anything learned about reading media should benefit every
    /// import path, not only Takeout.
    static func importFiles(
        _ fileURLs: [URL],
        sourceDescription: String,
        existingAssets: [Asset],
        policyRules: [PolicyRule],
        staging: StagingStore,
        replicaContext: (targetID: UUID, mountPath: String)? = nil
    ) async -> ImportResult {
        var cloudPlacements: [ResidencyDomain: [UUID]] = [:]
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
        var archiveBacked: [UUID: TargetReplicaState] = [:]
        var knownHashes = Set(existingAssets.map(\.contentHash))

        let scanned = TakeoutImporter.scanFilesInParallel(fileURLs)
        let movieDates = await TakeoutImporter.movieCreationDates(for: scanned)

        for scan in scanned {
            let fileURL = scan.fileURL
            let filename = fileURL.lastPathComponent
            do {
                let hash: String
                let fileSize: Int64
                var metadata: ExtractedMetadata
                switch scan.outcome {
                case .failure(let message):
                    failures.append((filename, message))
                    continue
                case .success(let scannedHash, let scannedSize, let scannedMetadata):
                    hash = scannedHash
                    fileSize = scannedSize
                    metadata = scannedMetadata
                }
                if knownHashes.contains(hash) {
                    duplicates.append(filename)
                    continue
                }

                // The scan already ran the full precedence chain (file, then
                // sidecar, then filename, then folder year). Only the movie
                // container date is left, because it needs an async read.
                if metadata.captureDate == nil, let movieDate = movieDates[fileURL] {
                    metadata.captureDate = movieDate
                    metadata.captureDateSource = .fileMetadata
                }

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
                presence.local = true
                let now = Date()

                // A file already sitting on a managed drive is that drive's
                // replica; staging a second copy would duplicate the source
                // onto the Mac for no benefit.
                var stagingPath: String?
                if let context = replicaContext, fileURL.path.hasPrefix(context.mountPath + "/") {
                    archiveBacked[assetID] = TargetReplicaState(
                        assetID: assetID,
                        targetID: context.targetID,
                        state: .present,
                        relativePath: ReplicationService.volumeBackedPrefix
                            + String(fileURL.path.dropFirst(context.mountPath.count + 1)),
                        lastVerifiedAt: now
                    )
                } else {
                    stagingPath = try staging.stage(
                        fileAt: fileURL,
                        assetID: assetID,
                        fileExtension: fileURL.pathExtension.lowercased()
                    )
                }
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
                    exifSummary: metadata.exifSummary,
                    captureDateSource: metadata.captureDateSource
                )
                imported.append(asset)
                if let target = decision.pendingCloudTarget {
                    cloudPlacements[target, default: []].append(assetID)
                }
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
            failures: failures.map { (filename: $0.0, error: $0.1) },
            archiveBackedReplicas: archiveBacked,
            cloudPlacements: cloudPlacements
        )
    }
}
