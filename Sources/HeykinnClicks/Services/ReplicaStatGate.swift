import Foundation

/// The third leg of the aimed-reads triad: stat every replica when its target
/// connects, and re-read only the files whose size or modification date moved.
///
/// Anchor checks catch a directory that moved. Comparing Merkle trees catches
/// two targets whose recorded content disagrees. Neither can see a file edited
/// *in place* under a path that still resolves — no recorded hash changed, so
/// the trees go on agreeing, and the directory is still there. Such a file used
/// to wait for the rot patrol to reach it, at around forty files every half
/// hour.
///
/// What makes running this on every connect affordable is that a replica is
/// often not its own file. On a target holding a Google Takeout export,
/// thousands of replicas are backed by a handful of zips or whole export parts,
/// and one stat covers all of them: on the archive this was measured against,
/// one target's replicas resolved to thirteen files, and the other's loose
/// files sat in 177 directories.
///
/// The gate never records damage. It has established that a file changed, not
/// that its bytes are wrong — so it aims a read and lets the read make the
/// claim.
enum ReplicaStatGate {

    /// One file to stat, and the replicas whose bytes live inside it.
    struct Subject {
        var url: URL
        var replicas: [TargetReplicaState]
        /// True when this file *is* the replica's own content, so its size can
        /// be checked against what the catalog records for the asset. A zip or
        /// an export part backs many assets and is none of them.
        var isOwnFile: Bool
    }

    struct Observation: Equatable {
        var size: Int64
        var modifiedAt: Date
    }

    enum Finding: Equatable {
        /// Matches what was recorded. Nothing to read.
        case unchanged
        /// Nothing had been recorded to compare against. This pass writes the
        /// baseline and claims nothing about the bytes — a comparison against
        /// no observation is not a check.
        case baselineRecorded
        /// Size or modification date moved: the bytes must be read again.
        case changed(reason: String)
        /// Not there. Path repair runs first and owns *relocation* — content
        /// the user moved is repointed before this gate looks, and a replica
        /// it could not place is already recorded missing and never reaches
        /// here. What is left is the case path repair cannot see: one file
        /// deleted from inside a directory that still resolves, and the
        /// archive-backed replicas whose recorded path it does not even
        /// examine. Reporting absence is not a claim about bytes.
        case absent
    }

    /// Modification dates that differ by less than this are treated as equal.
    /// exFAT stores mtime to two-second granularity and remounting can round a
    /// stored value; a whole target re-read because a timestamp shifted by a
    /// second would be the overhead this design exists to avoid. An in-place
    /// edit moves the clock by far more than this.
    static let modificationTolerance: TimeInterval = 2

    /// Groups a target's replicas by the file that actually holds their bytes.
    ///
    /// `archivePartPaths` maps an export part's display name to where that part
    /// sits on this target; parts whose location is unknown are skipped rather
    /// than guessed at.
    static func subjects(
        replicas: [TargetReplicaState],
        assetsByID: [UUID: Asset],
        target: ReplicationTarget,
        mountURL: URL,
        archivePartPaths: [String: String]
    ) -> [Subject] {
        var order: [String] = []
        var byPath: [String: Subject] = [:]

        for replica in replicas {
            let url: URL
            let isOwnFile: Bool

            if let stem = ReplicationService.archivePartStem(replica) {
                guard let path = archivePartPaths[stem] else { continue }
                url = URL(fileURLWithPath: path)
                isOwnFile = false
            } else if let components = ReplicationService.zipMemberComponents(replica) {
                url = mountURL.appendingPathComponent(components.zipRelativePath)
                isOwnFile = false
            } else if let asset = assetsByID[replica.assetID] {
                url = ReplicationService.resolveReplicaURL(
                    asset: asset, drive: target, mountURL: mountURL, existingReplica: replica
                )
                isOwnFile = true
            } else {
                continue
            }

            let key = url.path
            if byPath[key] == nil {
                order.append(key)
                byPath[key] = Subject(url: url, replicas: [], isOwnFile: isOwnFile)
            }
            byPath[key]?.replicas.append(replica)
        }
        return order.compactMap { byPath[$0] }
    }

    /// Reads one file's size and modification date. Nil means the file is not
    /// there — which this gate reports as `absent` and does nothing about.
    static func observe(_ url: URL) -> Observation? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Observation(
            size: Int64(info.st_size),
            modifiedAt: Date(
                timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            )
        )
    }

    /// What one replica's stat says about it.
    ///
    /// `expectedSize` is the size the catalog records for the asset, and is
    /// given only when the file being stat-ed *is* that asset. It is what makes
    /// the gate useful on its first run, before any baseline exists: a replica
    /// whose file is the wrong length is wrong whether or not anyone wrote down
    /// what it used to be.
    static func finding(
        for replica: TargetReplicaState,
        expectedSize: Int64?,
        observed: Observation?
    ) -> Finding {
        guard let observed else { return .absent }

        if let recordedSize = replica.observedSize, let recordedTime = replica.observedModifiedAt {
            if observed.size != recordedSize {
                return .changed(
                    reason: "its size went from \(recordedSize) to \(observed.size) bytes"
                )
            }
            if abs(observed.modifiedAt.timeIntervalSince(recordedTime)) > modificationTolerance {
                return .changed(reason: "it was modified after the app last read it")
            }
            return .unchanged
        }

        if let expectedSize, expectedSize > 0, observed.size != expectedSize {
            return .changed(
                reason: "it is \(observed.size) bytes on the target where the catalog records \(expectedSize)"
            )
        }
        return .baselineRecorded
    }
}
