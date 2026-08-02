import Foundation

/// How well one export part is protected, and on what evidence.
enum PartRedundancy: String, Codable, Hashable {
    /// The part exists on no managed drive.
    case absent
    /// Exactly one managed drive holds it.
    case singleCopy
    /// Enough drives hold it, matched by name and byte size only. Enough to
    /// plan against; not yet proof the bytes agree.
    case redundantUnverified
    /// Enough drives hold it and their whole-file hashes agree.
    case redundantVerified

    var displayName: String {
        switch self {
        case .absent: return "Not on any drive"
        case .singleCopy: return "One copy"
        case .redundantUnverified: return "Enough copies (sizes match)"
        case .redundantVerified: return "Enough copies, verified"
        }
    }

    /// Whether this state satisfies the configured local redundancy policy.
    var meetsPolicy: Bool {
        self == .redundantUnverified || self == .redundantVerified
    }
}

/// One part of a Google Takeout export, and where its copies live.
///
/// This is the unit the archive is actually made of. The export arrives as a
/// handful of large zips; replicating it means having those zips on as many
/// drives as the redundancy policy asks for, not copying every photo inside
/// them individually. Modelling it per-asset turns a handful of file copies
/// into tens of thousands of operations, and hides the fact that a drive
/// already holding the export is already compliant.
struct ExportPart: Identifiable, Hashable {
    var setID: String
    var partNumber: Int
    /// Copies of this part, keyed by the drive holding them.
    var copies: [UUID: TakeoutArchive]

    var id: String { "\(setID)-\(partNumber)" }
    var displayName: String { "takeout-\(setID)-\(String(format: "%03d", partNumber))" }

    var driveIDs: Set<UUID> { Set(copies.keys) }
    var sizeBytes: Int64 { copies.values.first?.sizeBytes ?? 0 }

    /// True when every copy that has been fingerprinted agrees, and at least
    /// two have been.
    var hashesAgree: Bool {
        let hashes = copies.values.compactMap(\.contentHash)
        guard hashes.count >= 2 else { return false }
        return Set(hashes).count == 1
    }

    /// True when the copies are the same size — cheap evidence that they are
    /// the same part, short of hashing tens of gigabytes.
    var sizesAgree: Bool {
        let sizes = copies.values.map(\.sizeBytes).filter { $0 > 0 }
        guard sizes.count >= 2 else { return false }
        return Set(sizes).count == 1
    }

    func redundancy(
        acrossManagedDrives managedDriveIDs: Set<UUID>,
        policy: LocalRedundancyPolicy = .default
    ) -> PartRedundancy {
        let holders = driveIDs.intersection(managedDriveIDs)
        if holders.isEmpty { return .absent }
        guard policy.isSatisfied(byCopies: holders.count) else { return .singleCopy }
        if hashesAgree { return .redundantVerified }
        if sizesAgree { return .redundantUnverified }
        // Enough drives hold a part with this number, but their sizes disagree,
        // so they are not the same bytes. Report the weaker truth rather than
        // claiming a redundancy that may not hold.
        return .singleCopy
    }

    /// Drives that should receive this part for the policy to be satisfied.
    func drivesNeedingACopy(managedDriveIDs: Set<UUID>) -> Set<UUID> {
        managedDriveIDs.subtracting(driveIDs)
    }
}

/// What must happen for an export to satisfy the local redundancy policy.
struct ArchiveReplicationPlan {
    var parts: [ExportPart]
    var managedDriveIDs: Set<UUID>
    var policy: LocalRedundancyPolicy = .default

    var partsMeetingPolicy: [ExportPart] {
        parts.filter {
            $0.redundancy(acrossManagedDrives: managedDriveIDs, policy: policy).meetsPolicy
        }
    }

    var partsNeedingWork: [ExportPart] {
        parts.filter {
            !$0.redundancy(acrossManagedDrives: managedDriveIDs, policy: policy).meetsPolicy
        }
    }

    /// Bytes still to move for the whole export to meet the policy.
    var bytesOutstanding: Int64 {
        partsNeedingWork.reduce(0) { total, part in
            total + part.sizeBytes * Int64(max(part.drivesNeedingACopy(managedDriveIDs: managedDriveIDs).count, 0))
        }
    }

    var isSatisfied: Bool { partsNeedingWork.isEmpty && !parts.isEmpty }
}

/// Builds the plan from the archives the catalog knows about.
enum ArchiveReplicationPlanner {

    /// Groups every discovered archive into parts. Extracted folders count as
    /// a copy of their part too — the bytes are present either way.
    static func plan(
        archives: [TakeoutArchive],
        managedDriveIDs: Set<UUID>,
        policy: LocalRedundancyPolicy = .default
    ) -> ArchiveReplicationPlan {
        var byPart: [String: ExportPart] = [:]
        for archive in archives {
            guard let setID = archive.exportSetID,
                  let partNumber = archive.partNumber,
                  let driveID = archive.driveID
            else { continue }
            let key = "\(setID)-\(partNumber)"
            var part = byPart[key] ?? ExportPart(setID: setID, partNumber: partNumber, copies: [:])
            // Prefer the zip as the canonical copy: it is the pristine original
            // and what gets transferred between drives.
            if let existing = part.copies[driveID], existing.kind == .zip, archive.kind != .zip {
                continue
            }
            part.copies[driveID] = archive
            byPart[key] = part
        }
        return ArchiveReplicationPlan(
            parts: byPart.values.sorted { ($0.setID, $0.partNumber) < ($1.setID, $1.partNumber) },
            managedDriveIDs: managedDriveIDs,
            policy: policy
        )
    }
}
