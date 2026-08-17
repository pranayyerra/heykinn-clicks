import Foundation

/// A plain-text account of what the app currently believes, for somebody
/// helping with a problem on a device they cannot see.
///
/// The material has always existed — protection counts, backlogs, target state,
/// the audit log — and none of it was reachable without opening the SQLite file
/// by hand. What stopped it being a menu item was the audit log: its messages
/// are written for the person who owns the archive and they name drives, and
/// occasionally paths. So the report is redacted rather than trimmed. Every
/// registered target becomes "Target A", "Target B" wherever its name appears,
/// absolute paths become `‹path›`, and anything with a media extension on it
/// becomes `‹file›`. What survives is the shape of the problem, which is the
/// part that helps.
extension AppStore {

    func diagnosticsReport() -> String {
        var out: [String] = []

        func heading(_ text: String) {
            out.append("")
            out.append(text)
            out.append(String(repeating: "-", count: text.count))
        }

        let names = redactionMap()
        let redactions = namesToRedact

        out.append("heykinn clicks — diagnostics")
        out.append("Written \(Formatters.dateTime.string(from: Date()))")
        out.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("")
        out.append("Counts, states and timings only. No file names, no folder paths,")
        out.append("and nothing about the photographs themselves.")

        // MARK: Archive

        heading("Archive")
        let photos = assets.filter { !$0.isLivePhotoMotion }
        out.append("Photos: \(photos.count.formatted())  (files on disk: \(assets.count.formatted()))")
        out.append("Logical size: \(Formatters.bytes.string(fromByteCount: localArchiveBytes))")
        out.append("Staging: \(Formatters.bytes.string(fromByteCount: staging.totalBytes))")
        // Per source, since there is no archive-wide copy count any more.
        // Kind and numbers only, never labels: a source is usually named after
        // a folder, and this report promises no folder paths.
        out.append("Sources: \(sources.count.formatted())")
        for source in sources.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }) {
            out.append("  \(source.kind.rawValue)")
        }
        // Policy is per group now, and a group need not correspond to a source.
        out.append("Storage groups: \(storageGroups.count.formatted())")
        for group in storageGroups.sorted(by: { $0.createdAt < $1.createdAt }) {
            let devices = "\(group.destinationTargetIDs.count) of \(targets.count) devices named"
            let flag = group.isSatisfiable ? "" : "  UNSATISFIABLE"
            out.append("  \(Formatters.count(group.desiredCopies, "copy", "copies")), \(devices)\(flag)")
        }
        let orphans = assets.filter { storageGroupIDByAsset[$0.id] == nil }.count
        if orphans > 0 {
            out.append("  no source recorded: \(orphans.formatted()) assets (using add-sheet defaults)")
        }

        for kind in AssetKind.allCases {
            let count = photos.count { $0.kind == kind }
            if count > 0 { out.append("  \(kind.displayName): \(count.formatted())") }
        }
        for origin in ImportOrigin.allCases {
            let count = photos.count { $0.importOrigin == origin }
            if count > 0 { out.append("  from \(origin.displayName): \(count.formatted())") }
        }
        for domain in ResidencyDomain.allCases {
            let count = photos.count { $0.residency == domain }
            if count > 0 { out.append("  in \(domain.displayName): \(count.formatted())") }
        }

        // MARK: Protection

        heading("Protection")
        var byState: [ProtectionState: Int] = [:]
        for asset in photos {
            guard let state = protectionStates[asset.id], state != .notApplicable else { continue }
            byState[state, default: 0] += 1
        }
        let local = byState.values.reduce(0, +)
        if local == 0 {
            out.append("No Local-resident photo has a protection state yet.")
        } else {
            let met = byState.filter { $0.key.verdict.isSatisfied }.values.reduce(0, +)
            let confirmed = byState
                .filter { $0.key.verdict.isSatisfied && $0.key.checkStanding == .fresh }
                .values.reduce(0, +)
            out.append("Meets the policy: \(met.formatted()) of \(local.formatted())")
            out.append("Read back and matched: \(confirmed.formatted()) of \(local.formatted())")
            for (state, count) in byState.sorted(by: { $0.value > $1.value }) {
                out.append("  \(state.displayName): \(count.formatted())")
            }
        }

        // MARK: Targets

        heading("Targets")
        if targets.isEmpty {
            out.append("None registered. Everything imported is staged on this device only.")
        }
        for target in targets {
            let label = names[target.id] ?? "Target ?"
            let breakdown = driveBreakdowns[target.id] ?? DriveContentBreakdown()
            let backlog = backlogSummary(for: target.id)
            out.append("\(label) — \(target.kind.displayName)")
            out.append("  reachable: \(reachablePaths[target.id] != nil ? "yes" : "no")")
            out.append("  registered: \(Formatters.dateTime.string(from: target.registeredAt))")
            out.append("  last seen: \(Formatters.relative(target.lastSeenAt))")
            out.append("  last completed sync: \(Formatters.relative(lastCompletedSync(for: target.id)))")
            out.append("  holds: \(breakdown.presentPhotos.formatted()) of \(breakdown.expectedPhotos.formatted()) photos"
                       + " · \(Formatters.bytes.string(fromByteCount: breakdown.presentBytes))")
            out.append("  drift: \(breakdown.driftPhotos.formatted())  missing: \(breakdown.missing.formatted())")
            out.append("  backlog: \(backlog.description)")
            out.append("  busy: \(isBusy(target.id) ? "yes" : "no")  quiescing: \(isQuiescing(target.id) ? "yes" : "no")")
        }
        if let progress = syncProgress {
            let label = names[progress.targetID] ?? "a target"
            out.append("Sync running against \(label): "
                       + "\(progress.completedTasks.formatted()) done, "
                       + "\(progress.failedTasks.formatted()) failed, "
                       + "of \(progress.totalTasks.formatted()).")
        }

        // MARK: Findings

        heading("Findings")
        if violations.isEmpty {
            out.append("No violations.")
        } else {
            for kind in ViolationKind.allCases {
                let count = violations.count { $0.kind == kind }
                if count > 0 { out.append("\(kind.displayName): \(count.formatted())") }
            }
        }
        out.append("Duplicate sets: \(duplicateGroups.count.formatted())")
        let active = migrationJobs.filter { $0.state.isActive }
        out.append("Active moves: \(active.count.formatted())")
        for job in active {
            out.append("  \(job.fromDomain.displayName) → \(job.toDomain.displayName): "
                       + "\(job.state.displayName), \(job.assetIDs.count.formatted()) photos")
        }

        // MARK: Sources

        heading("Sources")
        out.append("Photos library: \(applePhotosStateDescription)")
        out.append("iCloud Photos answered: \(iCloudPhotosEnabled.map { $0 ? "yes" : "no" } ?? "not asked yet")")
        out.append("Google download files known: \(takeoutArchives.count.formatted())"
                   + " · awaiting import: \(TakeoutExportSet.partsAwaitingImport(in: takeoutArchives).formatted())")
        out.append("Export parts held in transit: \(heldExportParts.count.formatted())")
        out.append("Import batches recorded: \(importBatches.count.formatted())")

        // MARK: What the provider sent

        // The early-warning system for a format that changes on somebody
        // else's schedule. Keys and counts only — the census also records an
        // example path per shape, and this report promises no folder paths.
        heading("Provider metadata")
        let payloads = (try? catalog.metadataRecordCount()) ?? 0
        out.append("Descriptions kept whole: \(payloads.formatted())")
        if payloads > 0 {
            let attached = (try? catalog.photosCarryingMetadata()) ?? 0
            out.append("Photos carrying one: \(attached.formatted()) of \(assets.count.formatted())")
            out.append("Read by projection version: \(CatalogStore.currentProjectionVersion)")
            let awaiting = (try? catalog.metadataRecordsAwaitingProjection()) ?? 0
            if awaiting > 0 {
                out.append("Awaiting re-reading: \(awaiting.formatted())")
            }

            let shapes = (try? catalog.fetchMetadataSchemas()) ?? []
            out.append("Distinct payload shapes seen: \(shapes.count.formatted())")
            // Ordered by first sighting rather than by size: a shape that
            // arrived recently and holds three payloads is the one worth
            // looking at, and sorting by count buries it.
            for shape in shapes.sorted(by: { $0.firstSeenAt > $1.firstSeenAt }).prefix(12) {
                out.append("  \(shape.scope.rawValue) · \(shape.recordCount.formatted()) ·"
                           + " first seen \(Formatters.dateOnly.string(from: shape.firstSeenAt))")
                out.append("    \(shape.keys.joined(separator: ", "))")
            }
            if shapes.count > 12 {
                out.append("  … and \(shapes.count - 12) more")
            }

            for kind in AssetTag.Kind.allCases {
                let values = (try? catalog.fetchTagSummary(kind: kind)) ?? []
                guard !values.isEmpty else { continue }
                out.append("\(kind.displayName)s recovered: \(values.count.formatted())")
            }
        }

        // MARK: Catalog

        heading("Catalog")
        if let latest = latestCatalogSnapshot {
            out.append("Latest snapshot: \(Formatters.dateTime.string(from: latest.createdAt))")
        } else {
            out.append("No snapshot has been written yet.")
        }

        // MARK: Log

        heading("Recent log (newest first, redacted)")
        var counts: [AuditCategory: Int] = [:]
        for event in auditEvents { counts[event.category, default: 0] += 1 }
        for category in AuditCategory.allCases {
            let count = counts[category] ?? 0
            if count > 0 { out.append("\(category.displayName): \(count.formatted()) recorded") }
        }
        out.append("")
        for event in auditEvents.prefix(60) {
            out.append("\(Formatters.dateTime.string(from: event.at))  [\(event.category.displayName)]  "
                       + Self.redact(event.message, names: redactions))
        }

        return out.joined(separator: "\n") + "\n"
    }

    private var applePhotosStateDescription: String {
        switch applePhotosState {
        case .connected: return "connected · \(applePhotosLibraryCount.formatted()) photos in library"
        case .notDetermined: return "not connected"
        case .denied: return "access denied by macOS"
        case .unavailable(let reason): return "unavailable — \(reason)"
        }
    }

    /// Target names, in registration order, so the same drive is the same
    /// letter throughout the report and between two reports from the same device.
    private func redactionMap() -> [UUID: String] {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let ordered = targets.sorted { $0.registeredAt < $1.registeredAt }
        var map: [UUID: String] = [:]
        for (index, target) in ordered.enumerated() {
            let letter = index < letters.count ? String(letters[index]) : String(index + 1)
            map[target.id] = "Target \(letter)"
        }
        return map
    }

    /// Real drive names, longest first, so "Photos Backup" is replaced before
    /// a target merely called "Photos" can eat half of it.
    private var namesToRedact: [(real: String, label: String)] {
        let map = redactionMap()
        var pairs: [(real: String, label: String)] = []
        for target in targets {
            guard let label = map[target.id], !target.name.isEmpty else { continue }
            pairs.append((real: target.name, label: label))
        }
        return pairs.sorted { $0.real.count > $1.real.count }
    }

    /// Names out, shapes kept.
    ///
    /// Order matters: drive names are substituted first, because a drive called
    /// "Photos" would otherwise survive the path rule and be mistaken for an
    /// ordinary word. Everything after that is pattern work — absolute paths,
    /// then anything carrying a media extension.
    nonisolated static func redact(_ message: String, names: [(real: String, label: String)]) -> String {
        var text = message
        for entry in names {
            text = text.replacingOccurrences(of: entry.real, with: entry.label)
        }
        return text
            .replacingOccurrences(
                of: "/[^\\s\"',;)]+",
                with: "‹path›",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\\b[\\w-]+\\.(jpe?g|png|heic|heif|dng|raw|cr2|nef|arw|mov|mp4|m4v|avi|zip|tgz|json)\\b",
                with: "‹file›",
                options: [.regularExpression, .caseInsensitive]
            )
    }
}
