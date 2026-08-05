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
    /// all its parts. When `placement` is non-empty (the workspace lives on a
    /// managed drive, i.e. an extracted folder — never a Mac temp workspace),
    /// each imported file is recorded as that drive's replica in place: the
    /// drive already holds the bytes, so no duplicate copy is queued for it.
    /// `fileURLs` imports an explicit subset (a chunk); omit it to import
    /// everything in the workspace.
    static func importMedia(
        from workspace: Workspace,
        archiveName: String,
        existingAssets: [Asset] = [],
        /// Prebuilt dedupe set. Chunked imports pass this and maintain it
        /// incrementally: rebuilding it from every asset on each chunk makes
        /// import cost grow with the square of the library size.
        knownContentHashes: Set<String>? = nil,
        staging: StagingStore,
        policyRules: [PolicyRule] = [],
        batchID: UUID = UUID(),
        placement: TargetPlacement = TargetPlacement(),
        fileURLs: [URL]? = nil
    ) async -> ImportResult {
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
        var archiveBacked: [UUID: TargetReplicaState] = [:]
        var cloudPlacements: [ResidencyDomain: [UUID]] = [:]
        var knownHashes = knownContentHashes ?? Set(existingAssets.map(\.contentHash))

        // Phase 1 (parallel): hash + read metadata/sidecar for every file.
        // This is the expensive part and it is per-file independent, so it
        // fans out across cores. Phase 2 stays serial to keep duplicate
        // resolution deterministic — the first file in path order wins.
        let targets = fileURLs ?? mediaFileURLs(in: workspace)
        let scanned = scanFilesInParallel(targets)

        // Movies keep their capture time in container metadata, which needs an
        // async read, so it happens here rather than in the parallel scan.
        // Without this every video imports with no date at all.
        let movieDates = await movieCreationDates(for: scanned)

        for scan in scanned {
            let fileURL = scan.fileURL
            let filename = fileURL.lastPathComponent
            do {
                switch scan.outcome {
                case .failure(let message):
                    failures.append((filename, message))
                    continue
                case .success(let hash, let fileSize, var metadata):
                    if metadata.captureDate == nil, let movieDate = movieDates[fileURL] {
                        metadata.captureDate = movieDate
                        metadata.captureDateSource = .fileMetadata
                    } else if metadata.captureDate == nil {
                        // Nothing in the file: fall back down the chain.
                        let fallback = CaptureDateResolver.resolve(
                            fileURL: fileURL, metadataDate: nil, sidecarDate: nil, sidecarSource: nil
                        )
                        metadata.captureDate = fallback.date
                        metadata.captureDateSource = fallback.source
                    }
                    if knownHashes.contains(hash) {
                        duplicates.append(filename)
                        continue
                    }
                let assetID = UUID()
                // A Takeout export proves the content WAS in Google at export
                // time, never that it still is, and the app has no account to
                // ask. So an import records what hashing proves — local
                // presence — and claims nothing about the cloud.
                let presence = DomainPresence.localOnly
                let now = Date()

                // The primary import path consults the same rules as every
                // other; WhatsApp media travelling through a Takeout keeps its
                // real origin. A rule naming a cloud is an intent, not a
                // residency — it becomes a pending migration, never a label.
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

                // When the source file already lives on a managed drive, that
                // file IS the drive's replica: staging a second copy on the
                // Mac would duplicate the whole archive onto the boot disk for
                // no benefit. Only content with no drive-resident copy is
                // staged.
                var stagingPath: String?
                // The hash above was computed from this very file, so a
                // replica recorded here is genuinely verified as of now.
                if let replica = placement.archiveBackedReplica(for: assetID, at: fileURL, now: now) {
                    archiveBacked[assetID] = replica
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
                    cloudPresenceEvidence: .none,
                    cloudPresenceCheckedAt: nil,
                    captureDateSource: metadata.captureDateSource
                ))
                if let target = decision.pendingCloudTarget {
                    cloudPlacements[target, default: []].append(assetID)
                }
                knownHashes.insert(hash)
                }
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

    // MARK: - Parallel scan phase

    /// Per-file work that is independent of every other file: hashing the
    /// bytes, reading EXIF, and pairing the Google sidecar.
    struct FileScan {
        enum Outcome {
            case success(hash: String, fileSize: Int64, metadata: ExtractedMetadata)
            case failure(String)
        }
        var fileURL: URL
        var outcome: Outcome
    }

    /// Concurrency for the scan phase. Hashing is CPU work overlapped with
    /// reads, so cores set the ceiling; a spinning/USB source is kept low
    /// because parallel reads there cause seek-thrashing.
    static func recommendedScanConcurrency(for sourceURL: URL) -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        switch ParallelZipExtraction.isSolidState(volumeContaining: sourceURL) {
        case .some(true): return max(2, min(cores, 8))
        case .some(false): return 2
        case .none: return max(2, min(cores, 4))
        }
    }

    /// Hashes and reads metadata for many files concurrently, preserving the
    /// input order in the result so downstream duplicate resolution stays
    /// deterministic.
    static func scanFilesInParallel(_ fileURLs: [URL], concurrency: Int? = nil) -> [FileScan] {
        guard !fileURLs.isEmpty else { return [] }
        // List each directory once up front. Sidecar lookup previously listed
        // the containing directory per file, which is quadratic inside an
        // album folder (these run to ~950 entries) and hit the drive for every
        // single media file.
        var listings: [String: [String]] = [:]
        for directory in Set(fileURLs.map { $0.deletingLastPathComponent().path }) {
            listings[directory] = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        }

        let width = concurrency ?? recommendedScanConcurrency(for: fileURLs[0])
        guard width > 1, fileURLs.count > 1 else {
            return fileURLs.map { FileScan(fileURL: $0, outcome: scanFile($0, directoryListings: listings)) }
        }

        var outcomes = [FileScan.Outcome?](repeating: nil, count: fileURLs.count)
        let lock = NSLock()
        let stride = min(width, fileURLs.count)
        DispatchQueue.concurrentPerform(iterations: stride) { worker in
            var index = worker
            while index < fileURLs.count {
                let outcome = scanFile(fileURLs[index], directoryListings: listings)
                lock.lock()
                outcomes[index] = outcome
                lock.unlock()
                index += stride
            }
        }
        return fileURLs.enumerated().map { index, url in
            FileScan(fileURL: url, outcome: outcomes[index] ?? .failure("Scan produced no result"))
        }
    }

    /// Reads container creation dates for the scanned movies, a few at a time
    /// so a large chunk does not open hundreds of assets at once.
    static func movieCreationDates(for scans: [FileScan], concurrency: Int = 6) async -> [URL: Date] {
        let movies = scans.compactMap { scan -> URL? in
            guard case .success(_, _, let metadata) = scan.outcome else { return nil }
            guard metadata.kind == .video, metadata.captureDate == nil else { return nil }
            return scan.fileURL
        }
        guard !movies.isEmpty else { return [:] }

        var results: [URL: Date] = [:]
        var index = 0
        while index < movies.count {
            let slice = movies[index..<min(index + concurrency, movies.count)]
            await withTaskGroup(of: (URL, Date?).self) { group in
                for url in slice {
                    group.addTask { (url, await CaptureDateResolver.movieCreationDate(url)) }
                }
                for await (url, date) in group {
                    if let date { results[url] = date }
                }
            }
            index += concurrency
        }
        return results
    }

    static func scanFile(_ fileURL: URL, directoryListings: [String: [String]] = [:]) -> FileScan.Outcome {
        do {
            let hash = try HashingService.sha256(of: fileURL)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileSize = (attributes[.size] as? Int64) ?? 0
            var metadata = MetadataExtractor.extract(from: fileURL)
            // Includes the original's sidecar for an edited derivative, which
            // Google gives no sidecar of its own.
            let located = CaptureDateResolver.sidecar(for: fileURL, directoryListings: directoryListings)
            let sidecar = located?.0

            if let description = sidecar?.description, !description.isEmpty {
                metadata.exifSummary["GoogleDescription"] = description
            }
            if metadata.exifSummary["GPS"] == nil,
               let latitude = sidecar?.geoData?.latitude,
               let longitude = sidecar?.geoData?.longitude,
               latitude != 0 || longitude != 0 {
                metadata.exifSummary["GPS"] = String(format: "%.5f, %.5f", latitude, longitude)
            }

            // Google's sidecar is more trustworthy than EXIF in a Takeout
            // export, which is often stripped or rewritten — so it takes the
            // place of "file metadata" for stills when present.
            let resolved = CaptureDateResolver.resolve(
                fileURL: fileURL,
                metadataDate: sidecar?.takenDate ?? metadata.captureDate,
                sidecarDate: sidecar?.takenDate,
                sidecarSource: located?.1
            )
            metadata.captureDate = resolved.date
            metadata.captureDateSource = sidecar?.takenDate != nil ? (located?.1 ?? .sidecar) : resolved.source
            return .success(hash: hash, fileSize: fileSize, metadata: metadata)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Sidecar pairing

    /// Google's sidecar naming varies across export vintages:
    /// `IMG.jpg.json`, `IMG.jpg.supplemental-metadata.json` (possibly
    /// truncated), or `IMG.json`. Tries exact candidates first, then a prefix
    /// match for the truncated supplemental-metadata form.
    static func findSidecar(for mediaURL: URL, directoryListings: [String: [String]] = [:]) -> TakeoutSidecar? {
        let directory = mediaURL.deletingLastPathComponent()
        let filename = mediaURL.lastPathComponent
        let stem = mediaURL.deletingPathExtension().lastPathComponent

        var candidates = [
            "\(filename).json",
            "\(filename).supplemental-metadata.json",
            "\(stem).json",
        ]
        // Only consult a directory listing for the truncated
        // supplemental-metadata form, and prefer a precomputed listing so the
        // drive is not re-read once per file.
        let contents = directoryListings[directory.path]
            ?? (try? FileManager.default.contentsOfDirectory(atPath: directory.path))
        if let contents {
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
