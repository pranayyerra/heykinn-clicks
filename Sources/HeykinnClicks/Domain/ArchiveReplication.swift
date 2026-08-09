import Foundation

/// How well one export part is protected, and on what evidence.
enum PartRedundancy: String, Codable, Hashable {
    /// The part exists on no managed drive.
    case absent
    /// Exactly one managed drive holds it.
    case singleCopy
    /// The policy asks for one copy and one copy exists.
    ///
    /// Every grade below is a comparison *between* copies, so a part in this
    /// state can never earn one — there is nothing to compare it against, and
    /// no amount of checking will change that. Reporting it as `singleCopy`
    /// would put it in `partsNeedingWork` forever, asking for work that cannot
    /// be done; reporting it as `redundant*` would claim agreement nobody
    /// established. It is the same distinction `CheckStanding` draws between a
    /// check that is weak and a check that was never possible.
    case singleCopyByPolicy
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
        case .singleCopyByPolicy: return "One copy, which is what the policy asks"
        case .redundantUnverified: return "Enough copies (sizes match)"
        case .redundantSpotChecked: return "Enough copies, spot-checked"
        case .redundantVerified: return "Enough copies, verified"
        }
    }

    /// Whether this state satisfies the configured local redundancy policy.
    /// Switched rather than compared, so a state added later has to say which
    /// side of the only question the user is asked it falls on.
    var meetsPolicy: Bool {
        switch self {
        case .absent, .singleCopy: return false
        case .singleCopyByPolicy, .redundantUnverified, .redundantSpotChecked, .redundantVerified:
            return true
        }
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
        copiesRequired: Int = 2
    ) -> PartRedundancy {
        let holders = targetIDs.intersection(managedTargetIDs)
        if holders.isEmpty { return .absent }
        guard holders.count >= copiesRequired else { return .singleCopy }
        // A lone copy under a one-copy policy is everything the policy asks
        // for. None of the evidence grades below can apply to it — they are
        // all agreements between copies — so answering with any of them, or
        // falling through to `singleCopy`, would be untrue in a different
        // direction each way.
        if holders.count == 1 { return .singleCopyByPolicy }
        if hashesAgree { return .redundantVerified }
        if quickChecksumsAgree { return .redundantSpotChecked }
        if sizesAgree { return .redundantUnverified }
        // Enough targets hold a part with this number, but their sizes disagree,
        // so they are not the same bytes. Report the weaker truth rather than
        // claiming a redundancy that may not hold.
        return .singleCopy
    }

    /// Drives that should receive this part for its export to be kept the way
    /// it asks.
    ///
    /// The set passed in is the export's **named destinations**, not every
    /// device registered. Passing every device was the first wrong model
    /// surviving in the export path: a Mac that is registered and holds none of
    /// the zips was reported as owing a copy of all of them for ever, and no
    /// change to the export's settings could clear it, because its settings
    /// were never consulted.
    func targetsNeedingACopy(managedTargetIDs: Set<UUID>) -> Set<UUID> {
        managedTargetIDs.subtracting(targetIDs)
    }
}

/// What must happen for an export to be kept the way its source asks.
struct ArchiveReplicationPlan {
    var parts: [ExportPart]
    /// Every registered device. The fallback for a set whose source has not
    /// been recorded yet, and nothing else — see `destinations(forSet:)`.
    var managedTargetIDs: Set<UUID>

    /// The devices each export names, keyed by set id.
    ///
    /// An export is kept where its source says, exactly like a folder. Grading
    /// its parts against every registered device instead reported a device that
    /// holds none of the zips — and was never asked to — as permanently owing a
    /// copy of all of them, and had the transfer planner trying to send them.
    var destinationsBySetID: [String: Set<UUID>] = [:]

    /// How many copies each export set asks for, keyed by set id.
    ///
    /// Per set, because one Google export is one source and carries its own
    /// copy count — two exports on one machine are entitled to different
    /// answers. A set with no entry falls back below; that is the state before
    /// an export has been given a source of its own, not a second policy.
    var copiesRequiredBySetID: [String: Int] = [:]
    /// What a set with no recorded source asks for.
    var defaultCopiesRequired: Int = 2

    func copiesRequired(forSet setID: String) -> Int {
        copiesRequiredBySetID[setID] ?? defaultCopiesRequired
    }

    /// Where this export belongs. Falls back to every registered device only
    /// for a set with no source yet — a download the app has found and nobody
    /// has been asked about.
    func destinations(forSet setID: String) -> Set<UUID> {
        destinationsBySetID[setID] ?? managedTargetIDs
    }

    func redundancy(of part: ExportPart) -> PartRedundancy {
        part.redundancy(
            acrossTargets: destinations(forSet: part.setID),
            copiesRequired: copiesRequired(forSet: part.setID)
        )
    }

    /// Devices this part still owes a copy to, out of the ones its export names.
    func targetsNeedingACopy(of part: ExportPart) -> Set<UUID> {
        part.targetsNeedingACopy(managedTargetIDs: destinations(forSet: part.setID))
    }

    var partsMeetingPolicy: [ExportPart] {
        parts.filter { redundancy(of: $0).meetsPolicy }
    }

    var partsNeedingWork: [ExportPart] {
        parts.filter { !redundancy(of: $0).meetsPolicy }
    }

    /// Bytes still to move for the whole export to meet the policy.
    var bytesOutstanding: Int64 {
        partsNeedingWork.reduce(0) { total, part in
            total + part.sizeBytes * Int64(max(targetsNeedingACopy(of: part).count, 0))
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
        destinationsBySetID: [String: Set<UUID>] = [:],
        copiesRequiredBySetID: [String: Int] = [:],
        defaultCopiesRequired: Int = 2
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
            destinationsBySetID: destinationsBySetID,
            copiesRequiredBySetID: copiesRequiredBySetID,
            defaultCopiesRequired: defaultCopiesRequired
        )
    }
}

/// Where an export set already lives on a target, so a part arriving later
/// joins it instead of starting a second pile somewhere else.
///
/// The app used to deliver every part to one folder at the volume root,
/// whatever the drive's own layout was. Restoring a single deleted part
/// therefore split a twelve-part export across two directories — the eleven
/// the user had put somewhere, and the one the app had put at the root. The
/// drive belongs to the user; where their export lives is their decision, and
/// it is already recorded in the paths of the parts they placed.
enum ExportSetLayout {

    /// The directory on this target holding the most parts of this set, or nil
    /// when the target holds none.
    ///
    /// The *waiting room* is never the answer. `ExportPartRelay`'s directory is
    /// where a part lands when there is nowhere better, and treating that as a
    /// home would mean the first delivery decided the layout for every delivery
    /// after it.
    ///
    /// This once excluded the whole of the app's folder, which was the same
    /// rule while the app had only one thing in there. It stopped being the
    /// same rule the moment an export could be *deliberately* moved into
    /// `HeykinnClicks/Exports` — a home chosen on purpose then read as no home
    /// at all, which left a delivered part sitting in the waiting room for ever
    /// because `rehomeDeliveredParts` had nowhere to take it.
    static func home(
        forSet setID: String,
        onMount mountURL: URL,
        archives: [TakeoutArchive]
    ) -> URL? {
        let prefix = mountURL.path.hasSuffix("/") ? mountURL.path : mountURL.path + "/"
        let waitingRoom = prefix + ExportPartRelay.onDriveDirectoryName + "/"

        // Distinct part numbers, not rows: a zip and the folder extracted from
        // it sit in the same directory and are one part between them.
        var partsByDirectory: [String: Set<Int>] = [:]
        for archive in archives {
            guard archive.exportSetID == setID, archive.holdsBytes,
                  let partNumber = archive.partNumber,
                  archive.path.hasPrefix(prefix),
                  !archive.path.hasPrefix(waitingRoom)
            else { continue }
            let directory = (archive.path as NSString).deletingLastPathComponent
            partsByDirectory[directory, default: []].insert(partNumber)
        }

        // Most parts wins; the shortest path breaks a tie, then alphabetical —
        // arbitrary, but the same answer every time, which is what stops two
        // deliveries of the same export disagreeing about where it lives.
        let best = partsByDirectory.max { a, b in
            if a.value.count != b.value.count { return a.value.count < b.value.count }
            if a.key.count != b.key.count { return a.key.count > b.key.count }
            return a.key > b.key
        }
        return best.map { URL(fileURLWithPath: $0.key, isDirectory: true) }
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
        let partsByID = Dictionary(uniqueKeysWithValues: replication.parts.map { ($0.id, $0) })
        var held = Dictionary(uniqueKeysWithValues: heldParts.map { ($0.id, $0) })

        // 1. Deliver what is already waiting.
        for (id, part) in held.sorted(by: { $0.key < $1.key }) {
            let catalogued = partsByID[id]
            // The devices this export names, not every device registered.
            let named = replication.destinations(forSet: part.setID)
            let needing = catalogued.map { replication.targetsNeedingACopy(of: $0) } ?? named
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
            let recipients = replication.targetsNeedingACopy(of: part)
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
