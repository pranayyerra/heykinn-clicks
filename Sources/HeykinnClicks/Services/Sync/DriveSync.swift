import Foundation

/// Carrying an archive's changes from one device to another on a drive.
///
/// **One rule does most of the work: a device writes only inside its own
/// `devices/<id>/` directory, and only ever appends.** Everything else it
/// reads. That single constraint removes a whole category of problem — no two
/// devices write the same file, so there is no locking on the drive, no
/// coordination, and nothing to corrupt if a drive is somehow mounted by two
/// devices at once over a share. Merging is reading other people's
/// directories.
///
/// It also sidesteps the worst cross-platform trap. File locking behaves
/// differently on macOS, Windows and Android, and over exFAT or SMB it is close
/// to meaningless. A protocol that needs no locks needs no agreement about
/// locks.
///
/// Layout, under the drive's `HeykinnClicks/Sync/`:
///
///     manifest.json                 what this directory is
///     devices/<id>/device.json      one device's own record of itself
///     devices/<id>/00000001.jsonl   its append-only segments
///     devices/<id>/checkpoints/00000001/state.json    a periodic whole-archive
///     devices/<id>/checkpoints/00000001/00000001.jsonl    state dump
///
/// **The checkpoint is the base and the log is the delta**, not the other way
/// round. Replaying a log onto a device that has never seen the archive measured
/// 111 MB where writing the state out measured 21 MB, because a per-field record
/// spends more on its stamp than on its value. Once a checkpoint exists, a new
/// device reads one of those and a handful of segments, and every segment the
/// checkpoint covers can simply be deleted — which is the only reason a drive
/// that is synced for years does not grow without bound.
enum DriveSync {

    /// Segments roll at this size. Small enough that a torn tail costs little
    /// and a reader can hold one in memory without thinking about it.
    static let segmentSizeLimit = 4 * 1024 * 1024

    static let manifestPath = "manifest.json"
    static let devicesDirectory = "devices"
    static let checkpointsDirectory = "checkpoints"

    static func deviceDirectory(_ deviceID: String) -> String {
        "\(devicesDirectory)/\(deviceID)"
    }

    static func deviceInfoPath(_ deviceID: String) -> String {
        "\(deviceDirectory(deviceID))/device.json"
    }

    static func segmentPath(_ deviceID: String, index: Int) -> String {
        "\(deviceDirectory(deviceID))/\(String(format: "%08d", index)).jsonl"
    }

    static func checkpointDirectory(_ deviceID: String, generation: Int) -> String {
        "\(deviceDirectory(deviceID))/\(checkpointsDirectory)/\(String(format: "%08d", generation))"
    }

    /// The marker, written last. A checkpoint directory without it is a write
    /// that was interrupted, and a reader ignores the whole thing.
    static func checkpointInfoPath(_ deviceID: String, generation: Int) -> String {
        "\(checkpointDirectory(deviceID, generation: generation))/state.json"
    }

    static func checkpointPartPath(_ deviceID: String, generation: Int, part: Int) -> String {
        "\(checkpointDirectory(deviceID, generation: generation))/\(String(format: "%08d", part)).jsonl"
    }

    /// When a publish should write a checkpoint.
    enum CheckpointPolicy {
        /// When the log this device has written since its last checkpoint has
        /// grown larger than that checkpoint — so the checkpoint pays for itself
        /// the moment it is cheaper than the history it replaces. Self-tuning,
        /// with no cadence to guess at.
        ///
        /// With no checkpoint yet the comparison is against one full segment, so
        /// a small archive never writes one and never needs to.
        case automatic
        /// Write one regardless. For tests, and for a person who has just been
        /// told a drive is about to be handed to a new device.
        case always
        case never
    }

    enum SyncError: Error, LocalizedError {
        case formatFromNewerBuild(found: Int, supported: Int)
        case catalogFromNewerBuild(found: Int64, supported: Int64)

        var errorDescription: String? {
            switch self {
            case .formatFromNewerBuild(let found, let supported):
                return """
                This drive holds sync data in a newer format (\(found); this copy understands \
                \(supported)). Update the app on this device to read it.
                """
            case .catalogFromNewerBuild(let found, let supported):
                return """
                This drive was last synced by a newer version of Heykinn Clicks (catalog version \
                \(found); this copy understands \(supported)). Update the app on this device.
                """
            }
        }
    }

    struct PublishOutcome: Equatable {
        var recordsWritten: Int = 0
        /// The checkpoint this publish wrote, if it wrote one.
        var checkpoint: CheckpointInfo?
        /// Segments deleted because that checkpoint covers them.
        var segmentsPruned: Int = 0
        var upToDate: Bool { recordsWritten == 0 }
    }

    struct MergeReport: Equatable {
        var outcome = MergeOutcome()
        /// Peers whose segments stopped short, and where. Reported rather than
        /// swallowed: a drive pulled out mid-write is the ordinary cause and is
        /// worth saying so, and the records lost arrive again on the next sync.
        var truncatedPeers: [String] = []
        var peersRead: Int = 0
    }

    // MARK: - Reading the drive's own claims

    /// Refuses a drive written by a build this one cannot safely read.
    ///
    /// The two versions are checked separately because they move separately —
    /// the file layout can change without the catalog schema changing, and once
    /// several platforms ship on their own release cycles they will not stay in
    /// step. Refusing costs somebody a sync; carrying on would mean merging
    /// records whose columns this build has never heard of.
    private static func checkManifest(_ store: SegmentStore) throws -> SyncManifest? {
        guard let data = try store.read(manifestPath),
              let manifest = try? JSONDecoder().decode(SyncManifest.self, from: data)
        else { return nil }

        guard manifest.formatVersion <= SyncManifest.currentFormatVersion else {
            throw SyncError.formatFromNewerBuild(
                found: manifest.formatVersion, supported: SyncManifest.currentFormatVersion
            )
        }
        guard manifest.catalogSchemaVersion <= CatalogStore.schemaVersion else {
            throw SyncError.catalogFromNewerBuild(
                found: manifest.catalogSchemaVersion, supported: CatalogStore.schemaVersion
            )
        }
        return manifest
    }

    private static func deviceInfo(
        _ store: SegmentStore, _ deviceID: String
    ) throws -> SyncDeviceInfo? {
        guard let data = try store.read(deviceInfoPath(deviceID)) else { return nil }
        return try? JSONDecoder().decode(SyncDeviceInfo.self, from: data)
    }

    // MARK: - Publishing

    /// Writes everything this device has done since it last wrote here.
    ///
    /// Its own directory only, and appended. A device that has never seen this
    /// drive writes its whole history; one that syncs regularly writes the
    /// handful of lines since last time.
    @discardableResult
    static func publish(
        from catalog: CatalogStore,
        to store: SegmentStore,
        checkpointing policy: CheckpointPolicy = .automatic
    ) throws -> PublishOutcome {
        _ = try checkManifest(store)

        let journal = catalog.journal!
        let device = journal.device
        let existing = try deviceInfo(store, device.id)
        let claimed = existing?.published.flatMap(HLCTimestamp.decode)
        let checkpoint = try newestCheckpoint(store, device.id)

        // What the drive can actually still be read to hold, which is not the
        // same as what this device believes it wrote.
        //
        // A drive can be damaged *after* a successful publish — pulled out
        // while the filesystem was still flushing, or corrupted later. The
        // device's own note says "sent", the drive says otherwise, and without
        // this those records would never be offered again by anyone: the writer
        // thinks they are safe and no reader ever saw them. Checking here costs
        // one segment read per sync and makes the loss self-healing.
        let watermark = try min(claimed, readableWatermark(store, device.id, checkpoint: checkpoint))

        // Cut a damaged tail back to its last complete line before writing
        // anything after it. Appending onto a half-written line would splice
        // the new record onto the broken one, and since a reader stops at the
        // first bad line that would block everything written afterwards —
        // permanently, and for every device that ever reads this drive.
        //
        // Its own directory, so no other device is touched by the repair.
        try repairOwnTail(store, device.id)

        let records = try journal.changes(since: watermark)
        let newest = records.map(\.stamp).max()

        if !records.isEmpty {
            let payload = try SegmentCodec.encode(records)
            try store.append(
                payload,
                to: try currentSegmentPath(
                    store, device.id, adding: payload.count, after: checkpoint
                )
            )
        }

        // Written after the segment, never before. If this device dies between
        // the two, the watermark still points at the older position and the
        // records are simply written again — duplicates a merge discards. The
        // other order would lose them silently.
        var info = SyncDeviceInfo(
            id: device.id,
            name: device.displayName,
            platform: SyncDeviceInfo.platformName,
            published: (newest ?? watermark)?.encoded,
            seen: try journal.watermarks(),
            logFloor: existing?.logFloor
        )
        try store.writeAtomically(try JSONEncoder().encode(info), to: deviceInfoPath(device.id))

        // Last, so a directory only claims to be a sync directory once it holds
        // something. A half-written one that a reader skips is better than one
        // that promises segments it does not have.
        if try store.read(manifestPath) == nil {
            let manifest = SyncManifest.current(catalogSchemaVersion: CatalogStore.schemaVersion)
            try store.writeAtomically(try JSONEncoder().encode(manifest), to: manifestPath)
        }

        var outcome = PublishOutcome(recordsWritten: records.count)
        guard try shouldCheckpoint(store, device.id, after: checkpoint, policy: policy) else {
            return outcome
        }

        let written = try writeCheckpoint(from: journal, to: store)
        outcome.checkpoint = written

        // The floor goes down **before** anything is deleted. If this device
        // dies in between, the drive holds segments the floor claims are gone —
        // harmless, since a reader that trusts the floor reads the checkpoint
        // instead. The other order leaves a reader looking for segments that no
        // longer exist and quietly missing everything they held.
        info.logFloor = written.horizon
        try store.writeAtomically(try JSONEncoder().encode(info), to: deviceInfoPath(device.id))

        outcome.segmentsPruned = try prune(store, device.id, coveredBy: written)
        return outcome
    }

    // MARK: - Checkpoints

    /// Whether the log has outgrown the checkpoint that would replace it.
    private static func shouldCheckpoint(
        _ store: SegmentStore, _ deviceID: String,
        after checkpoint: CheckpointInfo?, policy: CheckpointPolicy
    ) throws -> Bool {
        switch policy {
        case .never: return false
        case .always: return true
        case .automatic:
            let uncovered = try segmentSizes(store, deviceID)
                .filter { $0.index >= (checkpoint?.firstSegmentIndexAfter ?? 0) }
                .reduce(0) { $0 + $1.bytes }
            return uncovered > (checkpoint?.byteCount ?? segmentSizeLimit)
        }
    }

    /// Writes this device's whole state into a fresh checkpoint generation.
    ///
    /// The parts go down first and the marker last, so a checkpoint interrupted
    /// by a drive being pulled out is invisible rather than partial — there is
    /// no state in which a reader can find a checkpoint that is short.
    /// - Parameter partSizeLimit: where a part rolls. A parameter only so a test
    ///   can force several parts without writing 4 MiB of them.
    @discardableResult
    static func writeCheckpoint(
        from journal: ChangeJournal,
        to store: SegmentStore,
        partSizeLimit: Int = segmentSizeLimit
    ) throws -> CheckpointInfo {
        let deviceID = journal.device.id
        let generation = (try newestCheckpoint(store, deviceID)?.generation ?? 0) + 1

        // Rolled deliberately, so every segment that exists now is *wholly*
        // covered by this checkpoint and none is half covered. That is what lets
        // both the reader and the pruner work in whole files.
        let firstSegmentIndexAfter = (try segmentSizes(store, deviceID).map(\.index).max() ?? 0) + 1

        // Read **before** the rows, never after. A checkpoint claims coverage up
        // to its horizon, and anything written while it runs is not in it — so a
        // horizon read afterwards would include a write the dump had already
        // scanned past, and every reader would skip the segment carrying it.
        // Reading first can only under-claim, and under-claiming costs a reread.
        let horizon = try journal.horizon() ?? journal.stamp()

        var buffer = Data()
        var byteCount = 0
        var rows = 0
        // Counted as parts are written, never derived from a roll counter. A
        // roll that lands on the last record leaves the counter one ahead of
        // the files, and a marker claiming a part that is not there refuses the
        // whole checkpoint — after the log it replaces has been deleted.
        var parts = 0

        func flush() throws {
            guard !buffer.isEmpty else { return }
            parts += 1
            try store.append(
                buffer, to: checkpointPartPath(deviceID, generation: generation, part: parts)
            )
            byteCount += buffer.count
            buffer.removeAll(keepingCapacity: true)
        }

        try journal.writeCheckpoint { record in
            buffer.append(try SegmentCodec.encodeLine(record))
            rows += 1
            if buffer.count >= partSizeLimit { try flush() }
        }
        try flush()

        let info = CheckpointInfo(
            formatVersion: CheckpointInfo.currentFormatVersion,
            catalogSchemaVersion: CatalogStore.schemaVersion,
            generation: generation,
            horizon: horizon.encoded,
            parts: parts,
            rows: rows,
            byteCount: byteCount,
            firstSegmentIndexAfter: firstSegmentIndexAfter,
            seen: try journal.watermarks(),
            writtenAt: Date().timeIntervalSince1970
        )
        try store.writeAtomically(
            try JSONEncoder().encode(info),
            to: checkpointInfoPath(deviceID, generation: generation)
        )
        return info
    }

    /// The newest complete checkpoint in a device's directory, or nil.
    ///
    /// Newest *complete*: a generation whose marker is absent was interrupted,
    /// and one whose marker is from a newer build is not this build's to read.
    static func newestCheckpoint(
        _ store: SegmentStore, _ deviceID: String
    ) throws -> CheckpointInfo? {
        let generations = try store
            .list("\(deviceDirectory(deviceID))/\(checkpointsDirectory)")
            .compactMap(Int.init)
            .sorted()
            .reversed()

        for generation in generations {
            guard let data = try store.read(checkpointInfoPath(deviceID, generation: generation)),
                  let info = try? JSONDecoder().decode(CheckpointInfo.self, from: data)
            else { continue }
            guard info.formatVersion <= CheckpointInfo.currentFormatVersion else {
                throw SyncError.formatFromNewerBuild(
                    found: info.formatVersion, supported: CheckpointInfo.currentFormatVersion
                )
            }
            guard info.catalogSchemaVersion <= CatalogStore.schemaVersion else {
                throw SyncError.catalogFromNewerBuild(
                    found: info.catalogSchemaVersion, supported: CatalogStore.schemaVersion
                )
            }
            return info
        }
        return nil
    }

    /// A checkpoint's rows, one group per row, or nil if any part of it is
    /// damaged or missing.
    ///
    /// **All or nothing.** Half a state dump is not a smaller state dump: its
    /// records are in table order rather than stamp order, so applying part of
    /// one and then advancing a watermark past its horizon would skip whatever
    /// was in the rest, permanently. The log is still there to fall back on.
    static func readCheckpoint(
        _ store: SegmentStore, _ deviceID: String, _ info: CheckpointInfo
    ) throws -> [[ChangeRecord]]? {
        var rows: [[ChangeRecord]] = []
        for part in stride(from: 1, through: info.parts, by: 1) {
            guard let data = try store.read(
                checkpointPartPath(deviceID, generation: info.generation, part: part)
            ) else { return nil }
            let result = SegmentCodec.decode(data, as: CheckpointRecord.self)
            guard result.stoppedAt == nil else { return nil }
            rows.append(contentsOf: result.values.map { $0.expanded() })
        }
        // The marker says how many rows it wrote. Short means a part is missing
        // or was cut, whatever the checksums thought of the lines that survived.
        guard rows.count == info.rows else { return nil }
        return rows
    }

    /// Deletes this device's own segments and older checkpoints that `info`
    /// has made redundant. Returns how many segments went.
    ///
    /// Deleting is confined to this device's own directory, which is the same
    /// rule that makes the whole protocol lock-free. A device behind the
    /// checkpoint reads the checkpoint; a device past it needs nothing here. So
    /// no reader has to be consulted and there is no watermark arithmetic —
    /// which is the second reason the checkpoint is the base mechanism rather
    /// than an optimisation on top of the log.
    @discardableResult
    private static func prune(
        _ store: SegmentStore, _ deviceID: String, coveredBy info: CheckpointInfo
    ) throws -> Int {
        var removed = 0
        for segment in try segmentSizes(store, deviceID)
        where segment.index < info.firstSegmentIndexAfter {
            try store.remove(segmentPath(deviceID, index: segment.index))
            removed += 1
        }

        for generation in try store
            .list("\(deviceDirectory(deviceID))/\(checkpointsDirectory)")
            .compactMap(Int.init)
        where generation < info.generation {
            try store.remove(checkpointDirectory(deviceID, generation: generation))
        }

        return removed
    }

    /// Truncates this device's newest segment back to its last good line, if it
    /// ends in a half-written one.
    ///
    /// Only the newest: an append can only damage the file it was appending to.
    private static func repairOwnTail(_ store: SegmentStore, _ deviceID: String) throws {
        let names = try store.list(deviceDirectory(deviceID))
            .filter { $0.hasSuffix(".jsonl") }
            .sorted()
        guard let newest = names.last else { return }

        let path = "\(deviceDirectory(deviceID))/\(newest)"
        guard let data = try store.read(path) else { return }
        let result = SegmentCodec.decode(data)
        guard result.stoppedAt != nil, result.goodByteCount < data.count else { return }

        try store.writeAtomically(data.prefix(result.goodByteCount), to: path)
    }

    /// Takes the lower of two watermarks, treating nil as "nothing".
    private static func min(_ a: HLCTimestamp?, _ b: HLCTimestamp?) -> HLCTimestamp? {
        switch (a, b) {
        case (let a?, let b?): return a < b ? a : b
        default: return nil
        }
    }

    /// The highest stamp still readable from this device's own corner of the
    /// drive.
    ///
    /// **The checkpoint counts, and has to.** It stands in for every segment it
    /// covers, including the ones pruning has since deleted. Without consulting
    /// it, a device that had pruned its own log would read back "nothing here",
    /// conclude the drive had lost its work, and republish its entire history on
    /// every single sync.
    ///
    /// Then the cheap path: damage is at the tail, so if the newest segment
    /// decodes whole then nothing before it can have been affected by an
    /// interrupted append. Only when that one is damaged is the whole log
    /// re-read to find where the good part ends — which is rare, and the
    /// alternative is silently losing whatever was in the torn part.
    private static func readableWatermark(
        _ store: SegmentStore, _ deviceID: String, checkpoint: CheckpointInfo?
    ) throws -> HLCTimestamp? {
        var highest = checkpoint?.horizonStamp
        func raise(_ candidate: HLCTimestamp?) {
            guard let candidate else { return }
            highest = highest.map { $0 > candidate ? $0 : candidate } ?? candidate
        }

        let names = try store.list(deviceDirectory(deviceID))
            .filter { $0.hasSuffix(".jsonl") }
            .sorted()
        guard let newest = names.last else { return highest }

        let tail = SegmentCodec.decode(try store.read("\(deviceDirectory(deviceID))/\(newest)") ?? Data())
        if tail.stoppedAt == nil {
            raise(tail.records.map(\.stamp).max())
            return highest
        }

        for name in names {
            let result = SegmentCodec.decode(
                try store.read("\(deviceDirectory(deviceID))/\(name)") ?? Data()
            )
            raise(result.records.map(\.stamp).max())
            if result.stoppedAt != nil { break }
        }
        return highest
    }

    /// This device's segments, by index and size, without reading any of them.
    private static func segmentSizes(
        _ store: SegmentStore, _ deviceID: String
    ) throws -> [(index: Int, bytes: Int)] {
        try store.list(deviceDirectory(deviceID))
            .filter { $0.hasSuffix(".jsonl") }
            .compactMap { name -> (index: Int, bytes: Int)? in
                guard let index = Int(name.replacingOccurrences(of: ".jsonl", with: "")) else {
                    return nil
                }
                return (index, try store.size("\(deviceDirectory(deviceID))/\(name)") ?? 0)
            }
            .sorted { $0.index < $1.index }
    }

    /// The segment to append to: the newest one with room, or the next one.
    private static func currentSegmentPath(
        _ store: SegmentStore, _ deviceID: String, adding bytes: Int, after checkpoint: CheckpointInfo?
    ) throws -> String {
        let segments = try segmentSizes(store, deviceID)

        // Never below where the newest checkpoint says the log resumes. Pruning
        // deletes the files, so the names are free again — and writing into one
        // would put fresh records exactly where every reader skips, because the
        // checkpoint has told them everything below that index is covered.
        let floor = checkpoint?.firstSegmentIndexAfter ?? 1
        guard let newest = segments.last, newest.index >= floor else {
            return segmentPath(deviceID, index: floor)
        }
        // Rolled on the way in rather than out, so a segment never exceeds the
        // limit — a reader is entitled to assume one fits in memory.
        return newest.bytes + bytes > segmentSizeLimit
            ? segmentPath(deviceID, index: newest.index + 1)
            : segmentPath(deviceID, index: newest.index)
    }

    // MARK: - Merging

    /// What one other device has written here that this one has not read.
    struct PeerRecords {
        var peerID: String
        /// A whole-archive state dump, one entry per row.
        ///
        /// Grouped by row and applied before `records`, because a row the
        /// receiver has never seen can only be created from all of its columns
        /// at once.
        var checkpointRows: [[ChangeRecord]] = []
        /// What the checkpoint is worth **once all of it has been applied**.
        ///
        /// A checkpoint's records are in table order, not stamp order, so no
        /// prefix of it is worth anything in particular — which is why its
        /// watermark is set at the end rather than batch by batch the way the
        /// log's is.
        var checkpointHorizon: HLCTimestamp?
        /// Oldest stamp first.
        var records: [ChangeRecord] = []
        /// Its log stopped short — a drive pulled out mid-write, most likely.
        var truncated: Bool = false

        var total: Int {
            checkpointRows.reduce(0) { $0 + $1.count } + records.count
        }
    }

    /// Reads the drive. No catalog writes, so this is the part that can be done
    /// without holding anything up.
    static func pending(from store: SegmentStore, for journal: ChangeJournal) throws -> [PeerRecords] {
        var found: [PeerRecords] = []

        for peerID in try store.list(devicesDirectory) where peerID != journal.device.id {
            let watermark = try journal.watermark(forPeer: peerID)
            var peer = PeerRecords(peerID: peerID)
            var fresh: [ChangeRecord] = []
            var firstSegment = 1

            // **The checkpoint is a fallback, not the normal path.** A day's
            // work is kilobytes of log against a whole archive of state, so
            // reading the log is far cheaper whenever the log can answer. It
            // cannot in exactly two cases: this device has never read this peer,
            // or the peer has pruned its log past where this device got to.
            let floor = (try deviceInfo(store, peerID))?.logFloor.flatMap(HLCTimestamp.decode)
            let behindTheLog = watermark == nil || (floor.map { watermark! < $0 } ?? false)

            if behindTheLog,
               let checkpoint = try newestCheckpoint(store, peerID),
               let horizon = checkpoint.horizonStamp,
               let rows = try readCheckpoint(store, peerID, checkpoint) {
                peer.checkpointRows = rows
                peer.checkpointHorizon = horizon
                firstSegment = checkpoint.firstSegmentIndexAfter
            }

            // In name order, which is the order they were written. A segment
            // read out of order would still merge correctly — that is what
            // order-independence buys — but the watermark would jump past a
            // gap it had not actually read.
            for name in try store.list(deviceDirectory(peerID)).sorted()
            where name.hasSuffix(".jsonl") {
                guard let index = Int(name.replacingOccurrences(of: ".jsonl", with: "")),
                      index >= firstSegment else { continue }
                guard let data = try store.read("\(deviceDirectory(peerID))/\(name)") else { continue }
                let result = SegmentCodec.decode(data)
                fresh.append(contentsOf: result.records)
                if result.stoppedAt != nil {
                    peer.truncated = true
                    // Nothing after a bad line is trustworthy, including later
                    // segments — they were written after the damage.
                    break
                }
            }

            // The checkpoint's horizon counts as read once it is applied, so
            // anything the log repeats below it is already answered.
            let mark = [watermark, peer.checkpointHorizon].compactMap { $0 }.max()
            peer.records = (mark.map { bound in fresh.filter { $0.stamp > bound } } ?? fresh)
                .sorted { $0.stamp < $1.stamp }
            found.append(peer)
        }

        return found
    }

    /// Applies one peer's checkpoint whole, then moves that peer's watermark to
    /// its horizon.
    ///
    /// Whole, and only then. Its records are in table order, so a watermark set
    /// part way through would claim coverage of rows that had not been applied
    /// and skip them for good. An interrupted checkpoint therefore costs a retry
    /// and nothing else — merging is idempotent.
    /// Which rows go in each batch, so no batch ever cuts a row in half.
    ///
    /// A batch is a unit of responsiveness, not a unit of meaning. Splitting a
    /// row across two of them is how a row arrives with columns missing — and a
    /// row that arrives incomplete is rejected outright, because guessing at a
    /// value somebody's archive depends on is not something a merge should do.
    static func checkpointBatches(_ rows: [[ChangeRecord]], size: Int) -> [Range<Int>] {
        var batches: [Range<Int>] = []
        var start = 0
        var count = 0
        for (index, row) in rows.enumerated() {
            count += row.count
            if count >= size {
                batches.append(start..<(index + 1))
                start = index + 1
                count = 0
            }
        }
        if start < rows.count { batches.append(start..<rows.count) }
        return batches
    }

    /// Applies one slice of one peer's records and moves that peer's watermark
    /// to the end of it.
    ///
    /// Per slice rather than per peer, so a first sync interrupted half way —
    /// the drive pulled out, the app quit — resumes from where it stopped
    /// instead of starting over. Safe because records are applied oldest first
    /// and merging is order-independent: the watermark never passes a record
    /// that has not been applied.
    @discardableResult
    static func applySlice(
        _ slice: ArraySlice<ChangeRecord>,
        from peerID: String,
        using journal: ChangeJournal,
        rowIndex: [String: [ChangeRecord]]? = nil,
        advancingWatermark: Bool = true
    ) throws -> MergeOutcome {
        guard !slice.isEmpty else { return MergeOutcome() }
        let records = Array(slice)

        // Before merging, so this device's own clock is already ahead of
        // everything it is about to apply — anything it does next then sorts
        // after what it has just learned.
        for record in records { try journal.observe(record.stamp) }

        let outcome = try journal.merge(records, rowIndex: rowIndex)
        if advancingWatermark, let highest = records.map(\.stamp).max() {
            try journal.setWatermark(highest, forPeer: peerID)
        }
        return outcome
    }

    /// Reads every other device's directory and applies what is new, in one go.
    ///
    /// The app uses the batched form below; this is for tests and for callers
    /// with nothing to keep responsive.
    @discardableResult
    static func merge(into catalog: CatalogStore, from store: SegmentStore) throws -> MergeReport {
        try mergeInBatches(into: catalog, from: store, sliceSize: Int.max)
    }

    /// The same, in slices, pausing between them.
    ///
    /// A first sync of a real archive is around 58,000 records per 2,000
    /// photographs, and the catalog is written on the main actor — so doing it
    /// in one piece would hold the window still for as long as it took. This
    /// hands control back between slices.
    @discardableResult
    static func merge(
        into catalog: CatalogStore,
        from store: SegmentStore,
        sliceSize: Int,
        onProgress: (Int, Int) -> Void = { _, _ in },
        betweenSlices: () async -> Void
    ) async throws -> MergeReport {
        // The slices themselves are synchronous — the catalog is not something
        // that can be written from anywhere. What `betweenSlices` buys is the
        // gap between them, so this walks the plan and awaits at each boundary.
        var report = MergeReport()
        let work = try plan(into: catalog, from: store, sliceSize: sliceSize)
        var done = 0

        for step in work.steps {
            let outcome = try step.apply()
            report.outcome.applied += outcome.applied
            report.outcome.superseded += outcome.superseded
            report.outcome.rejected.append(contentsOf: outcome.rejected)
            done += step.count
            onProgress(done, work.total)
            await betweenSlices()
        }
        report.truncatedPeers = work.truncatedPeers
        report.peersRead = work.peersRead

        if report.peersRead > 0 { try updateSeen(store, work.journal) }
        return report
    }

    /// A merge broken into pieces, each safe to run on its own.
    struct Plan {
        var journal: ChangeJournal
        var steps: [Step] = []
        var truncatedPeers: [String] = []
        var peersRead = 0
        var total = 0

        struct Step {
            var count: Int
            var apply: () throws -> MergeOutcome
        }
    }

    /// Works out what a merge would do, without doing any of it.
    ///
    /// Split out so both entry points run the *same* steps in the same order and
    /// only differ in whether they pause between them. The two used to be
    /// separate loops, which is exactly the shape in which one of them quietly
    /// stops matching the other.
    private static func plan(
        into catalog: CatalogStore, from store: SegmentStore, sliceSize: Int
    ) throws -> Plan {
        _ = try checkManifest(store)
        let journal = catalog.journal!
        var work = Plan(journal: journal)

        for peer in try pending(from: store, for: journal) {
            if peer.truncated { work.truncatedPeers.append(peer.peerID) }
            work.peersRead += 1
            work.total += peer.total
            let peerID = peer.peerID

            // The checkpoint first: it is the base state, and the log after it
            // is the delta.
            let ranges = checkpointBatches(peer.checkpointRows, size: sliceSize)
            for (position, range) in ranges.enumerated() {
                let isLast = position == ranges.count - 1
                let horizon = peer.checkpointHorizon
                let rows = peer.checkpointRows
                let count = rows[range].reduce(0) { $0 + $1.count }
                // Flattened inside the step, not here: materialising every batch
                // up front would hold a second copy of the whole checkpoint.
                work.steps.append(Plan.Step(count: count) {
                    let batch = rows[range].flatMap { $0 }
                    let outcome = try applySlice(
                        batch[...], from: peerID, using: journal, advancingWatermark: false
                    )
                    // Only when the whole of it has landed. Its records are in
                    // table order rather than stamp order, so a watermark set
                    // part way through would claim coverage of rows that had
                    // not been applied and skip them for good. An interrupted
                    // checkpoint costs a retry and nothing else.
                    if isLast, let horizon {
                        try journal.setWatermark(horizon, forPeer: peerID)
                    }
                    return outcome
                })
            }
            // An archive with nothing in it still has a horizon worth recording,
            // and there is no batch to hang it off.
            if ranges.isEmpty, let horizon = peer.checkpointHorizon {
                work.steps.append(Plan.Step(count: 0) {
                    try journal.setWatermark(horizon, forPeer: peerID)
                    return MergeOutcome()
                })
            }

            // Every record this peer has pending, grouped by row, so a slice
            // boundary does not leave a new row short of the columns it needs.
            let rowIndex = ChangeJournal.rowIndex(of: peer.records)
            var start = peer.records.startIndex
            while start < peer.records.endIndex {
                let end = sliceSize >= peer.records.count - start
                    ? peer.records.endIndex
                    : start + sliceSize
                let slice = peer.records[start..<end]
                work.steps.append(Plan.Step(count: slice.count) {
                    try applySlice(slice, from: peerID, using: journal, rowIndex: rowIndex)
                })
                start = end
            }
        }

        return work
    }

    /// Runs a whole plan with no pauses.
    private static func mergeInBatches(
        into catalog: CatalogStore, from store: SegmentStore, sliceSize: Int
    ) throws -> MergeReport {
        var report = MergeReport()
        let plan = try plan(into: catalog, from: store, sliceSize: sliceSize)

        for step in plan.steps {
            let outcome = try step.apply()
            report.outcome.applied += outcome.applied
            report.outcome.superseded += outcome.superseded
            report.outcome.rejected.append(contentsOf: outcome.rejected)
        }
        report.truncatedPeers = plan.truncatedPeers
        report.peersRead = plan.peersRead

        if report.peersRead > 0 { try updateSeen(store, plan.journal) }
        return report
    }

    /// Rewrites this device's own record of what it has read. Its own file, so
    /// no other device is disturbed by it.
    private static func updateSeen(_ store: SegmentStore, _ journal: ChangeJournal) throws {
        let device = journal.device
        let existing = try deviceInfo(store, device.id)
        let info = SyncDeviceInfo(
            id: device.id,
            name: device.displayName,
            platform: SyncDeviceInfo.platformName,
            published: existing?.published,
            seen: try journal.watermarks(),
            logFloor: existing?.logFloor
        )
        try store.writeAtomically(try JSONEncoder().encode(info), to: deviceInfoPath(device.id))
    }

    /// Publish then merge, which is what connecting a drive means.
    ///
    /// Publish first so that a drive carried straight to another device has
    /// this device's work on it even if reading fails half way.
    @discardableResult
    static func synchronise(
        _ catalog: CatalogStore, with store: SegmentStore
    ) throws -> (published: PublishOutcome, merged: MergeReport) {
        let published = try publish(from: catalog, to: store)
        let merged = try merge(into: catalog, from: store)
        return (published, merged)
    }
}
