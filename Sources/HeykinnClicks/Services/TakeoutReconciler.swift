import Foundation

/// Matches Takeout content already present on a managed drive against the
/// catalog, claiming it as that drive's replicas — so a drive that arrives
/// with the same export (zips or extracted folders) satisfies the two-copy
/// policy without a single additional byte written to it.
///
/// Every claim is verified by content hash at claim time: a folder file is
/// hashed directly; a zip entry is stream-hashed out of the zip. Read-only
/// with respect to the drive.
enum TakeoutReconciler {

    struct Result {
        var claimedReplicas: [DriveReplicaState]
        var scannedFileCount: Int
    }

    /// Walks an extracted Takeout folder, hashing media files and claiming
    /// volume-backed replicas for catalog assets that lack one on this drive.
    static func reconcileFolder(
        folderURL: URL,
        mountURL: URL,
        driveID: UUID,
        assetIDsByHash: [String: UUID],
        assetsNeedingReplica: Set<UUID>
    ) -> Result {
        var claimed: [DriveReplicaState] = []
        var scanned = 0
        for fileURL in ImportService.mediaFileURLs(under: [folderURL]) {
            scanned += 1
            guard let hash = try? HashingService.sha256(of: fileURL),
                  let assetID = assetIDsByHash[hash],
                  assetsNeedingReplica.contains(assetID),
                  !claimed.contains(where: { $0.assetID == assetID }),
                  fileURL.path.hasPrefix(mountURL.path + "/")
            else { continue }
            let volumeRelative = String(fileURL.path.dropFirst(mountURL.path.count + 1))
            claimed.append(DriveReplicaState(
                assetID: assetID,
                driveID: driveID,
                state: .present,
                relativePath: ReplicationService.volumeBackedPrefix + volumeRelative,
                lastVerifiedAt: Date()
            ))
        }
        return Result(claimedReplicas: claimed, scannedFileCount: scanned)
    }

    /// Stream-hashes media entries inside a zip (no extraction, no writes) and
    /// claims zip-member replicas for matching catalog assets. The zip itself
    /// becomes the drive's copy.
    static func reconcileZip(
        zipURL: URL,
        mountURL: URL,
        driveID: UUID,
        assetIDsByHash: [String: UUID],
        assetsNeedingReplica: Set<UUID>
    ) -> Result {
        var claimed: [DriveReplicaState] = []
        guard zipURL.path.hasPrefix(mountURL.path + "/") else {
            return Result(claimedReplicas: [], scannedFileCount: 0)
        }
        let zipRelative = String(zipURL.path.dropFirst(mountURL.path.count + 1))
        let entries = mediaEntries(inZip: zipURL)
        for entry in entries {
            guard let hash = try? HashingService.sha256OfZipEntry(zipURL: zipURL, entry: entry),
                  let assetID = assetIDsByHash[hash],
                  assetsNeedingReplica.contains(assetID),
                  !claimed.contains(where: { $0.assetID == assetID })
            else { continue }
            claimed.append(DriveReplicaState(
                assetID: assetID,
                driveID: driveID,
                state: .present,
                relativePath: ReplicationService.zipMemberPrefix + zipRelative + "!" + entry,
                lastVerifiedAt: Date()
            ))
        }
        return Result(claimedReplicas: claimed, scannedFileCount: entries.count)
    }

    /// Derives the entry-path → asset mapping known for a zip's content, from
    /// existing archive-backed replicas of the SAME bytes elsewhere:
    /// - `zipmember:` replicas referencing a byte-identical donor zip, and
    /// - `volume:` replicas under the donor's extracted folder twin
    ///   (`<folder>/Takeout/…` → entry `Takeout/…`).
    static func knownEntryMapping(
        donorZip: TakeoutArchive,
        folderTwins: [TakeoutArchive],
        replicaStates: [DriveReplicaState]
    ) -> [String: UUID] {
        var mapping: [String: UUID] = [:]
        let zipMarker = donorZip.displayName + "!"
        let folderMarkers = folderTwins.map { $0.displayName + "/" }

        for replica in replicaStates where replica.state == .present {
            guard let relative = replica.relativePath else { continue }
            if relative.hasPrefix(ReplicationService.zipMemberPrefix) {
                if let range = relative.range(of: zipMarker) {
                    mapping[String(relative[range.upperBound...])] = replica.assetID
                }
            } else if relative.hasPrefix(ReplicationService.volumeBackedPrefix) {
                for marker in folderMarkers {
                    if let range = relative.range(of: marker) {
                        mapping[String(relative[range.upperBound...])] = replica.assetID
                        break
                    }
                }
            }
        }
        return mapping
    }

    /// Checksum fast path: when this zip's whole-file hash equals a donor's,
    /// the archives are byte-identical, so the donor's entry→asset mapping
    /// transfers directly — no per-entry hashing. Returns nil when no donor
    /// with a matching fingerprint (or no usable mapping) exists; callers fall
    /// back to `reconcileZip`.
    static func fastReconcileZip(
        zipHash: String,
        zipRelativePath: String,
        driveID: UUID,
        candidateDonors: [TakeoutArchive],
        folderTwins: [TakeoutArchive],
        replicaStates: [DriveReplicaState],
        assetsNeedingReplica: Set<UUID>
    ) -> Result? {
        let donors = candidateDonors.filter { $0.kind == .zip && $0.contentHash == zipHash }
        for donor in donors {
            let mapping = knownEntryMapping(
                donorZip: donor,
                folderTwins: folderTwins,
                replicaStates: replicaStates
            )
            guard !mapping.isEmpty else { continue }
            var claimed: [DriveReplicaState] = []
            for (entry, assetID) in mapping where assetsNeedingReplica.contains(assetID) {
                claimed.append(DriveReplicaState(
                    assetID: assetID,
                    driveID: driveID,
                    state: .present,
                    relativePath: ReplicationService.zipMemberPrefix + zipRelativePath + "!" + entry,
                    lastVerifiedAt: Date()
                ))
            }
            return Result(claimedReplicas: claimed, scannedFileCount: mapping.count)
        }
        return nil
    }

    /// Media-file entry paths in a zip's listing.
    static func mediaEntries(inZip zipURL: URL) -> [String] {
        ZipTools.listEntries(inZip: zipURL).filter { entry in
            MetadataExtractor.kind(forFileExtension: (entry as NSString).pathExtension) != .unknown
        }
    }
}
