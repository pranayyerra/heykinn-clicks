import Foundation

/// How well one export part is protected, and on what evidence.
enum PartRedundancy: String, Codable, Hashable {
    /// The part exists on no managed drive.
    case absent
    /// Exactly one managed drive holds it.
    case singleCopy
    /// Enough targets hold it, matched by name and byte size only. Enough to
    /// plan against; not yet proof the bytes agree.
    case redundantUnverified
    /// Enough targets hold it and their quick checksums agree — the same
    /// length and the same bytes at every sampled window. Near-certain, but
    /// not a guarantee about the parts not sampled.
    case redundantSpotChecked
    /// Enough targets hold it and their whole-file hashes agree.
    case redundantVerified

    var displayName: String {
        switch self {
        case .absent: return "Not on any drive"
        case .singleCopy: return "One copy"
        case .redundantUnverified: return "Enough copies (sizes match)"
        case .redundantSpotChecked: return "Enough copies, spot-checked"
        case .redundantVerified: return "Enough copies, verified"
        }
    }

    /// Whether this state satisfies the configured local redundancy policy.
    var meetsPolicy: Bool {
        self == .redundantUnverified || self == .redundantSpotChecked || self == .redundantVerified
    }
}

/// One part of a Google Takeout export, and where its copies live.
///
/// This is the unit the archive is actually made of. The export arrives as a
/// handful of large zips; replicating it means having those zips on as many
/// targets as the redundancy policy asks for, not copying every photo inside
/// them individually. Modelling it per-asset turns a handful of file copies
/// into tens of thousands of operations, and hides the fact that a drive
/// already holding the export is already compliant.
struct ExportPart: Identifiable, Hashable {
    var setID: String
    var partNumber: Int
    /// Copies of this part, keyed by the drive holding them. Only copies whose
    /// bytes are actually there — an archive the app looked for and did not
    /// find is not a copy of anything.
    var copies: [UUID: TakeoutArchive]
    /// How big this part was when a copy of it last existed. A part whose every
    /// copy has been deleted still has to be reported, and reported with the
    /// size of the transfer that would restore it.
    var lastKnownSizeBytes: Int64 = 0

    var id: String { "\(setID)-\(partNumber)" }
    var displayName: String { TakeoutArchive.partStem(setID: setID, partNumber: partNumber) }

    var targetIDs: Set<UUID> { Set(copies.keys) }
    var sizeBytes: Int64 { copies.values.first?.sizeBytes ?? lastKnownSizeBytes }

    /// True when every copy that has been fingerprinted agrees, and at least
    /// two have been.
    var hashesAgree: Bool {
        let hashes = copies.values.compactMap(\.contentHash)
        guard hashes.count >= 2 else { return false }
        return Set(hashes).count == 1
    }

    /// True when the copies are the same size — cheap evidence that they are
    /// the same part, short of hashing tens of gigabytes.
    /// True when every quick checksum computed agrees, and at least the
    /// policy's number have been.
    var quickChecksumsAgree: Bool {
        let checksums = copies.values.compactMap(\.quickChecksum)
        guard checksums.count >= 2 else { return false }
        return Set(checksums).count == 1
    }

    var sizesAgree: Bool {
        let sizes = copies.values.map(\.sizeBytes).filter { $0 > 0 }
        guard sizes.count >= 2 else { return false }
        return Set(sizes).count == 1
    }

    func redundancy(
        acrossTargets managedTargetIDs: Set<UUID>,
        policy: LocalRedundancyPolicy = .default
    ) -> PartRedundancy {
        let holders = targetIDs.intersection(managedTargetIDs)
        if holders.isEmpty { return .absent }
        guard policy.isSatisfied(byCopies: holders.count) else { return .singleCopy }
        if hashesAgree { return .redundantVerified }
        if quickChecksumsAgree { return .redundantSpotChecked }
        if sizesAgree { return .redundantUnverified }
        // Enough targets hold a part with this number, but their sizes disagree,
        // so they are not the same bytes. Report the weaker truth rather than
        // claiming a redundancy that may not hold.
        return .singleCopy
    }

    /// Drives that should receive this part for the policy to be satisfied.
    func targetsNeedingACopy(managedTargetIDs: Set<UUID>) -> Set<UUID> {
        managedTargetIDs.subtracting(targetIDs)
    }
}

/// What must happen for an export to satisfy the local redundancy policy.
struct ArchiveReplicationPlan {
    var parts: [ExportPart]
    var managedTargetIDs: Set<UUID>
    var policy: LocalRedundancyPolicy = .default

    var partsMeetingPolicy: [ExportPart] {
        parts.filter {
            $0.redundancy(acrossTargets: managedTargetIDs, policy: policy).meetsPolicy
        }
    }

    var partsNeedingWork: [ExportPart] {
        parts.filter {
            !$0.redundancy(acrossTargets: managedTargetIDs, policy: policy).meetsPolicy
        }
    }

    /// Bytes still to move for the whole export to meet the policy.
    var bytesOutstanding: Int64 {
        partsNeedingWork.reduce(0) { total, part in
            total + part.sizeBytes * Int64(max(part.targetsNeedingACopy(managedTargetIDs: managedTargetIDs).count, 0))
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
        managedTargetIDs: Set<UUID>,
        policy: LocalRedundancyPolicy = .default
    ) -> ArchiveReplicationPlan {
        var byPart: [String: ExportPart] = [:]
        for archive in archives {
            guard let setID = archive.exportSetID,
                  let partNumber = archive.partNumber,
                  let targetID = archive.targetID
            else { continue }
            let key = "\(setID)-\(partNumber)"
            var part = byPart[key] ?? ExportPart(setID: setID, partNumber: partNumber, copies: [:])
            part.lastKnownSizeBytes = max(part.lastKnownSizeBytes, archive.sizeBytes)
            // An archive the app looked for and did not find is not a copy of
            // anything. Counting it would have the plan report redundancy for a
            // part that exists once, and the drive that still has it would look
            // like it needed nothing. The part itself stays in the plan — a
            // part whose copies have all gone is the loudest thing the plan has
            // to say, not something to drop off the end of it.
            guard archive.holdsBytes else {
                byPart[key] = part
                continue
            }
            // Prefer the zip as the canonical copy: it is the pristine original
            // and what gets transferred between targets.
            if let existing = part.copies[targetID], existing.kind == .zip, archive.kind != .zip {
                continue
            }
            part.copies[targetID] = archive
            byPart[key] = part
        }
        return ArchiveReplicationPlan(
            parts: byPart.values.sorted { ($0.setID, $0.partNumber) < ($1.setID, $1.partNumber) },
            managedTargetIDs: managedTargetIDs,
            policy: policy
        )
    }
}

/// An export part parked on the Mac while it travels between targets.
///
/// Named after the part it holds, so the directory listing *is* the state:
/// a catalog restored from backup, a crash mid-copy, or someone emptying the
/// folder by hand all leave the truth visible on disk with nothing to
/// reconcile.
struct HeldExportPart: Identifiable, Hashable {
    var setID: String
    var partNumber: Int
    var path: String
    var sizeBytes: Int64
    var stagedAt: Date

    var id: String { "\(setID)-\(partNumber)" }
    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String { TakeoutArchive.partStem(setID: setID, partNumber: partNumber) }
}

/// One move that gets an export part closer to living on enough targets.
struct ExportPartTransfer: Identifiable, Hashable {
    enum Route: Hashable {
        /// Both targets are connected — copy straight across, no detour.
        case driveToDrive(from: UUID, to: UUID)
        /// Only the drive that has the part is connected. Park it on the Mac
        /// so the transfer can finish later, when the other drive appears.
        case driveToHoldingArea(from: UUID, intendedFor: UUID)
        /// The drive that needs the part is connected and the part is already
        /// parked — deliver it, then free the space.
        case holdingAreaToDrive(to: UUID)

        var recipient: UUID {
            switch self {
            case .driveToDrive(_, let to): return to
            case .driveToHoldingArea(_, let intendedFor): return intendedFor
            case .holdingAreaToDrive(let to): return to
            }
        }
    }

    var setID: String
    var partNumber: Int
    var route: Route
    var sizeBytes: Int64

    var id: String { "\(setID)-\(partNumber)-\(route.recipient.uuidString)" }
    var displayName: String { TakeoutArchive.partStem(setID: setID, partNumber: partNumber) }
}

/// What can be moved right now, given which targets are actually plugged in.
struct ExportPartTransferPlan {
    var transfers: [ExportPartTransfer] = []
    /// Parts in the holding area that no longer need to be there — already on
    /// enough targets. The corridor should stay empty.
    var discardable: [HeldExportPart] = []
    /// Parts short of copies that nothing can be done about at the moment,
    /// because no drive holding one is connected.
    var stranded: [ExportPart] = []
    /// Parts that would be parked on the Mac if there were room for them.
    var deferredForSpace: [ExportPart] = []

    var bytesToMove: Int64 { transfers.reduce(0) { $0 + $1.sizeBytes } }
    var isEmpty: Bool { transfers.isEmpty && discardable.isEmpty }
}

enum ExportPartTransferPlanner {

    /// Bytes left free on the Mac after parking parts. The holding area is a
    /// corridor on the boot disk; filling it is a worse failure than a
    /// transfer taking two sessions instead of one.
    static let holdingAreaReserveBytes: Int64 = 20 * 1024 * 1024 * 1024

    /// Works out the moves that would satisfy the redundancy policy for the
    /// export, using only the targets connected right now.
    ///
    /// The order matters: deliveries first, because they are the steps that
    /// complete a transfer already half-done and are the only way the holding
    /// area empties. Direct drive-to-drive copies come next — they need no
    /// space on the Mac at all. Parking a part on the Mac is the last resort,
    /// taken only when the drive that needs the part is not here to receive it.
    static func plan(
        replication: ArchiveReplicationPlan,
        connectedDriveIDs: Set<UUID>,
        heldParts: [HeldExportPart],
        availableHoldingBytes: Int64
    ) -> ExportPartTransferPlan {
        var result = ExportPartTransferPlan()
        let managed = replication.managedTargetIDs
        let partsByID = Dictionary(uniqueKeysWithValues: replication.parts.map { ($0.id, $0) })
        var held = Dictionary(uniqueKeysWithValues: heldParts.map { ($0.id, $0) })

        // 1. Deliver what is already waiting.
        for (id, part) in held.sorted(by: { $0.key < $1.key }) {
            let catalogued = partsByID[id]
            let needing = catalogued?.targetsNeedingACopy(managedTargetIDs: managed) ?? managed
            guard let recipient = needing.sorted(by: { $0.uuidString < $1.uuidString }).first else {
                // Every managed drive already has it; the corridor is done
                // with this one.
                result.discardable.append(part)
                held[id] = nil
                continue
            }
            guard connectedDriveIDs.contains(recipient) else { continue }
            result.transfers.append(ExportPartTransfer(
                setID: part.setID,
                partNumber: part.partNumber,
                route: .holdingAreaToDrive(to: recipient),
                sizeBytes: part.sizeBytes
            ))
        }

        // 2. Parts still short of copies.
        var holdingBudget = max(availableHoldingBytes - holdingAreaReserveBytes, 0)
        for part in replication.partsNeedingWork.sorted(by: { ($0.setID, $0.partNumber) < ($1.setID, $1.partNumber) }) {
            // Already in the corridor: it is handled above, or waiting for its
            // recipient. Either way, do not copy it a second time.
            if held[part.id] != nil { continue }
            let recipients = part.targetsNeedingACopy(managedTargetIDs: managed)
            guard !recipients.isEmpty else { continue }
            // Only a zip can be handed to another drive as-is. An extracted
            // folder is the same content, but copying a directory of tens of
            // thousands of files is a different operation with none of the
            // same guarantees, so a part that survives only as a folder is
            // reported as stranded rather than half-transferred.
            let donors = part.copies
                .filter { connectedDriveIDs.contains($0.key) && $0.value.kind == .zip }
                .keys
            guard let donor = donors.sorted(by: { $0.uuidString < $1.uuidString }).first else {
                result.stranded.append(part)
                continue
            }
            for recipient in recipients.sorted(by: { $0.uuidString < $1.uuidString }) {
                if connectedDriveIDs.contains(recipient) {
                    result.transfers.append(ExportPartTransfer(
                        setID: part.setID,
                        partNumber: part.partNumber,
                        route: .driveToDrive(from: donor, to: recipient),
                        sizeBytes: part.sizeBytes
                    ))
                } else if part.sizeBytes > 0, part.sizeBytes <= holdingBudget {
                    holdingBudget -= part.sizeBytes
                    result.transfers.append(ExportPartTransfer(
                        setID: part.setID,
                        partNumber: part.partNumber,
                        route: .driveToHoldingArea(from: donor, intendedFor: recipient),
                        sizeBytes: part.sizeBytes
                    ))
                } else {
                    result.deferredForSpace.append(part)
                }
            }
        }
        return result
    }
}
