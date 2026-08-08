import Foundation
import UniformTypeIdentifiers

/// A provider's metadata for one imported file, kept as it was written.
///
/// Carried out of the importer rather than written there: the importer runs
/// detached and knows nothing about which source claimed this import, and a
/// payload with no source is a payload nobody can explain later.
struct CapturedMetadata {
    var assetID: UUID
    /// Where the sidecar sat, relative to the export root — the only record of
    /// album membership, which Google expresses as directory placement.
    var originPath: String
    var payload: String
}

struct ImportResult {
    var batch: ImportBatch
    var importedAssets: [Asset]
    /// Provider metadata found beside the imported files. Empty for sources
    /// that carry none.
    var capturedMetadata: [CapturedMetadata] = []
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
    /// Copies the archive turned out to already have: assets the catalog
    /// already held, whose bytes this sweep found sitting on a managed target.
    ///
    /// A repeat sighting of content the app knows is not nothing. Where the
    /// file is matters as much as whether it is new, and the app only ever
    /// asked the first question — so a drive registered after the import that
    /// read its files could never be credited with the copy it was holding,
    /// and got sent a second one instead. Keyed by asset ID; the caller
    /// decides what to do about each, because only it can see what the catalog
    /// already records for that target.
    var adoptedReplicas: [UUID: TargetReplicaState] = [:]
    /// What each file read this pass looked like, for the next sweep to skip.
    var scanMemoEntries: [ScanMemoEntry] = []
}

/// Import pipeline: scan → hash → dedupe check → classify → stage → catalog.
/// Runs with zero targets connected; Local-resident files land in staging and
/// replication tasks are queued per registered drive for later.
enum ImportService {
    /// Directories a sweep never descends into: the app's own structures on a
    /// target, and its working areas.
    ///
    /// A source is somewhere the user keeps photos. The replica root is not —
    /// it holds the app's own copies, under names the app invented, and
    /// reading them back as if they were a source would credit the archive's
    /// own output to the user as content found in place. It matters as soon as
    /// a whole drive can be swept: the app's folder sits at the root of every
    /// target. Same list as `TakeoutScanner.excludedDirectoryNames`, for the
    /// same reason.
    static let excludedDirectoryNames: Set<String> = [
        ReplicationTarget.appFolderName,
        "Staging", "TakeoutWork", ".Trashes", ".Spotlight-V100",
    ]

    /// `skippingExports` leaves Google exports found inside the tree alone.
    /// A folder sweep sets it: an export is brought in by machinery that keeps
    /// it whole, and reading one loose would turn a handful of files into tens
    /// of thousands of separate replicas. The Takeout importer does not — the
    /// tree it is pointed at *is* an export, and skipping it would import
    /// nothing at all.
    static func mediaFileURLs(under rootURLs: [URL], skippingExports: Bool = false) -> [URL] {
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
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let item = enumerator?.nextObject() as? URL {
                let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                if values?.isDirectory == true {
                    if excludedDirectoryNames.contains(item.lastPathComponent) {
                        enumerator?.skipDescendants()
                        continue
                    }
                    if skippingExports, TakeoutScanner.looksLikeTakeoutRoot(item) {
                        enumerator?.skipDescendants()
                    }
                    continue
                }
                guard values?.isRegularFile == true else { continue }
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
        batchOrigin: ImportOrigin = .localFolder,
        existingAssets: [Asset],
        policyRules: [PolicyRule],
        staging: StagingStore,
        placement: TargetPlacement = TargetPlacement(),
        scanMemo: [String: ScanMemoEntry] = [:]
    ) async -> ImportResult {
        var cloudPlacements: [ResidencyDomain: [UUID]] = [:]
        var capturedMetadata: [CapturedMetadata] = []
        let sweptAt = Date()
        var batch = ImportBatch(
            id: UUID(),
            sourcePath: sourceDescription,
            startedAt: Date(),
            completedAt: nil,
            importedCount: 0,
            duplicateCount: 0,
            failedCount: 0,
            origin: batchOrigin
        )
        var imported: [Asset] = []
        var duplicates: [String] = []
        var failures: [(String, String)] = []
        var archiveBacked: [UUID: TargetReplicaState] = [:]
        var adopted: [UUID: TargetReplicaState] = [:]
        // The asset, not just its hash: a file whose content the catalog
        // already knows still has a location worth recording, and that needs
        // the identity of the asset it duplicates.
        var knownByHash = Dictionary(
            existingAssets.map { ($0.contentHash, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // What can be answered without opening the file.
        //
        // Only for content the catalog already holds: a `stat` says a file has
        // not changed, which is enough to trust a hash the app worked out
        // itself, and nowhere near enough to admit something new to the
        // archive on. So a remembered hash that matches nothing known still
        // gets read in full.
        var recalledHashes: [URL: String] = [:]
        var needsReading: [URL] = []
        for url in fileURLs {
            if let entry = scanMemo[url.path],
               knownByHash[entry.contentHash] != nil,
               let observation = ReplicaStatGate.observe(url),
               entry.matches(observation) {
                recalledHashes[url] = entry.contentHash
            } else {
                needsReading.append(url)
            }
        }

        let scanned = TakeoutImporter.scanFilesInParallel(needsReading)
        let movieDates = await TakeoutImporter.movieCreationDates(for: scanned)
        let scannedByURL = Dictionary(scanned.map { ($0.fileURL, $0) }, uniquingKeysWith: { first, _ in first })
        var memoEntries: [ScanMemoEntry] = []

        // Walked in the order the sweep found them, whether or not each file
        // had to be read, so which of two identical files wins does not depend
        // on what happened to be remembered.
        for fileURL in fileURLs {
            let filename = fileURL.lastPathComponent

            if let hash = recalledHashes[fileURL], let existing = knownByHash[hash] {
                duplicates.append(filename)
                if let replica = placement.archiveBackedReplica(for: existing.id, at: fileURL) {
                    adopted[existing.id] = replica
                }
                if var entry = scanMemo[fileURL.path] {
                    entry.seenAt = sweptAt
                    memoEntries.append(entry)
                }
                continue
            }

            guard let scan = scannedByURL[fileURL] else { continue }
            do {
                let hash: String
                let fileSize: Int64
                var metadata: ExtractedMetadata
                let sidecarPayload: String?
                switch scan.outcome {
                case .failure(let message):
                    failures.append((filename, message))
                    continue
                case .success(let scannedHash, let scannedSize, let scannedMetadata, _, let scannedPayload):
                    hash = scannedHash
                    fileSize = scannedSize
                    metadata = scannedMetadata
                    sidecarPayload = scannedPayload
                }
                // Written whichever way this file goes from here. A duplicate
                // is precisely the case the next sweep wants to skip, and it
                // is the one a re-import is mostly made of.
                if let observation = ReplicaStatGate.observe(fileURL) {
                    memoEntries.append(ScanMemoEntry(
                        path: fileURL.path,
                        size: observation.size,
                        modifiedAt: observation.modifiedAt,
                        contentHash: hash,
                        seenAt: sweptAt
                    ))
                }
                if let existing = knownByHash[hash] {
                    duplicates.append(filename)
                    // Nothing new arrives, but something may still be learned:
                    // if these bytes are sitting on a managed target, that
                    // file is the target's copy and the app can stop planning
                    // to send it one. Emitted unconditionally — only the
                    // caller can see what the catalog already records here.
                    if let replica = placement.archiveBackedReplica(for: existing.id, at: fileURL) {
                        adopted[existing.id] = replica
                    }
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
                if let replica = placement.archiveBackedReplica(for: assetID, at: fileURL, now: now) {
                    archiveBacked[assetID] = replica
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
                if let sidecarPayload, !sidecarPayload.isEmpty {
                    capturedMetadata.append(CapturedMetadata(
                        assetID: assetID,
                        originPath: fileURL.lastPathComponent,
                        payload: sidecarPayload
                    ))
                }
                if let target = decision.pendingCloudTarget {
                    cloudPlacements[target, default: []].append(assetID)
                }
                knownByHash[hash] = asset
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
            capturedMetadata: capturedMetadata,
            duplicateFilenames: duplicates,
            failures: failures.map { (filename: $0.0, error: $0.1) },
            archiveBackedReplicas: archiveBacked,
            cloudPlacements: cloudPlacements,
            adoptedReplicas: adopted,
            scanMemoEntries: memoEntries
        )
    }
}
