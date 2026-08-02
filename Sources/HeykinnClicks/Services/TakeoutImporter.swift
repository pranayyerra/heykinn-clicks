import Foundation

/// Imports media from a Google Takeout export (zip or extracted folder),
/// pairing each file with its JSON sidecar for capture time, GPS, and
/// description. The archive itself is never modified or deleted.
///
/// Residency semantics: Takeout media is Google-cloud content whose bytes are
/// now held locally. Assets are imported as Local residents; if the originals
/// still exist in Google Photos, the caller creates a GoogleCloud → Local
/// migration job so the multi-domain overlap is tracked and legal until the
/// user confirms deletion on the Google side.
enum TakeoutImporter {

    struct Workspace {
        /// Directory whose tree contains the Takeout media.
        var mediaRoot: URL
        /// Extraction directory to delete afterwards; nil when importing from
        /// an extracted folder in place (never delete the user's copy).
        var cleanupURL: URL?
    }

    enum TakeoutError: Error, LocalizedError {
        case archiveMissing(String)
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .archiveMissing(let path):
                return "Takeout archive not accessible at \(path) — is the drive connected?"
            case .extractionFailed(let message):
                return "Takeout extraction failed: \(message)"
            }
        }
    }

    // MARK: - Workspace

    /// For a zip: extracts into `workArea` (via ditto, which handles zip64 and
    /// unicode names). For a folder: uses it in place, read-only.
    static func prepareWorkspace(for archive: TakeoutArchive, workArea: URL) throws -> Workspace {
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw TakeoutError.archiveMissing(archive.path)
        }
        switch archive.kind {
        case .folder:
            return Workspace(mediaRoot: archive.url, cleanupURL: nil)
        case .zip:
            let destination = workArea.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            do {
                let workers = ParallelZipExtraction.recommendedWorkerCount(destination: destination)
                try ParallelZipExtraction.extract(zipURL: archive.url, into: destination, workers: workers)
            } catch {
                do {
                    try TakeoutExtractor.dittoExtract(zipURL: archive.url, into: destination)
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    throw TakeoutError.extractionFailed(error.localizedDescription)
                }
            }
            return Workspace(mediaRoot: destination, cleanupURL: destination)
        }
    }

    static func cleanup(_ workspace: Workspace) {
        if let cleanupURL = workspace.cleanupURL {
            try? FileManager.default.removeItem(at: cleanupURL)
        }
    }

    // MARK: - Import

    /// Media files inside a prepared workspace, in a stable order. Callers can
    /// import these in chunks so results land in the catalog (and the Library)
    /// while a large part is still being processed.
    static func mediaFileURLs(in workspace: Workspace) -> [URL] {
        ImportService.mediaFileURLs(under: [workspace.mediaRoot]).sorted { $0.path < $1.path }
    }

    /// `batchID` lets a multi-part export set share one import batch across
    /// all its parts. When `replicaContext` is set (the workspace lives on a
    /// managed drive, i.e. an extracted folder — never a Mac temp workspace),
    /// each imported file is recorded as that drive's replica in place: the
    /// drive already holds the bytes, so no duplicate copy is queued for it.
    /// `fileURLs` imports an explicit subset (a chunk); omit it to import
    /// everything in the workspace.
    static func importMedia(
        from workspace: Workspace,
        archiveName: String,
        existingAssets: [Asset],
        staging: StagingStore,
        assumeStillInGoogle: Bool,
        batchID: UUID = UUID(),
        replicaContext: (driveID: UUID, mountPath: String)? = nil,
        fileURLs: [URL]? = nil
    ) -> ImportResult {
        var batch = ImportBatch(
            id: batchID,
            sourcePath: "Takeout: \(archiveName)",
            startedAt: Date(),
            completedAt: nil,
            importedCount: 0,
            duplicateCount: 0,
            failedCount: 0
        )
        var imported: [Asset] = []
        var duplicates: [String] = []
        var failures: [(String, String)] = []
        var archiveBacked: [UUID: DriveReplicaState] = [:]
        var knownHashes = Set(existingAssets.map(\.contentHash))

        for fileURL in fileURLs ?? mediaFileURLs(in: workspace) {
            let filename = fileURL.lastPathComponent
            do {
                let hash = try HashingService.sha256(of: fileURL)
                if knownHashes.contains(hash) {
                    duplicates.append(filename)
                    continue
                }

                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fileSize = (attributes[.size] as? Int64) ?? 0
                var metadata = MetadataExtractor.extract(from: fileURL)
                let sidecar = findSidecar(for: fileURL)

                // The sidecar's photoTakenTime is Google's authoritative record;
                // it wins over (often stripped) EXIF in Takeout exports.
                if let taken = sidecar?.takenDate {
                    metadata.captureDate = taken
                }
                if let description = sidecar?.description, !description.isEmpty {
                    metadata.exifSummary["GoogleDescription"] = description
                }
                if metadata.exifSummary["GPS"] == nil,
                   let latitude = sidecar?.geoData?.latitude,
                   let longitude = sidecar?.geoData?.longitude,
                   latitude != 0 || longitude != 0 {
                    metadata.exifSummary["GPS"] = String(format: "%.5f, %.5f", latitude, longitude)
                }

                let assetID = UUID()
                var presence = DomainPresence.localOnly
                // A Takeout export proves the content WAS in Google at export
                // time, never that it still is. Cloud presence is only recorded
                // when the user explicitly states it, and is marked as their
                // assertion — not as something the app verified.
                presence.googleCloud = assumeStillInGoogle
                let now = Date()

                // When the source file already lives on a managed drive, that
                // file IS the drive's replica: staging a second copy on the
                // Mac would duplicate the whole archive onto the boot disk for
                // no benefit. Only content with no drive-resident copy is
                // staged.
                var stagingPath: String?
                if let context = replicaContext, fileURL.path.hasPrefix(context.mountPath + "/") {
                    // The hash above was computed from this very file, so the
                    // replica is genuinely verified as of now.
                    let volumeRelative = String(fileURL.path.dropFirst(context.mountPath.count + 1))
                    archiveBacked[assetID] = DriveReplicaState(
                        assetID: assetID,
                        driveID: context.driveID,
                        state: .present,
                        relativePath: ReplicationService.volumeBackedPrefix + volumeRelative,
                        lastVerifiedAt: now
                    )
                } else {
                    stagingPath = try staging.stage(
                        fileAt: fileURL,
                        assetID: assetID,
                        fileExtension: fileURL.pathExtension.lowercased()
                    )
                }
                imported.append(Asset(
                    id: assetID,
                    kind: metadata.kind,
                    originalFilename: filename,
                    importOrigin: .googleTakeout,
                    captureDate: metadata.captureDate,
                    importDate: now,
                    updatedDate: now,
                    fileSize: fileSize,
                    pixelWidth: metadata.pixelWidth,
                    pixelHeight: metadata.pixelHeight,
                    contentHash: hash,
                    residency: .local,
                    residencySource: .importDefault,
                    presence: presence,
                    stagingRelativePath: stagingPath,
                    importBatchID: batch.id,
                    exifSummary: metadata.exifSummary,
                    cloudPresenceEvidence: assumeStillInGoogle ? .userAsserted : .none,
                    cloudPresenceCheckedAt: nil
                ))
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
            archiveBackedReplicas: archiveBacked
        )
    }

    // MARK: - Sidecar pairing

    /// Google's sidecar naming varies across export vintages:
    /// `IMG.jpg.json`, `IMG.jpg.supplemental-metadata.json` (possibly
    /// truncated), or `IMG.json`. Tries exact candidates first, then a prefix
    /// match for the truncated supplemental-metadata form.
    static func findSidecar(for mediaURL: URL) -> TakeoutSidecar? {
        let directory = mediaURL.deletingLastPathComponent()
        let filename = mediaURL.lastPathComponent
        let stem = mediaURL.deletingPathExtension().lastPathComponent

        var candidates = [
            "\(filename).json",
            "\(filename).supplemental-metadata.json",
            "\(stem).json",
        ]
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let truncatedPrefix = "\(filename).suppl"
            candidates.append(contentsOf: contents.filter {
                $0.hasPrefix(truncatedPrefix) && $0.hasSuffix(".json")
            })
        }

        for candidate in candidates {
            let url = directory.appendingPathComponent(candidate)
            guard let data = try? Data(contentsOf: url) else { continue }
            if let sidecar = try? JSONDecoder().decode(TakeoutSidecar.self, from: data) {
                return sidecar
            }
        }
        return nil
    }
}
