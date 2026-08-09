import SwiftUI

struct DrivesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var registrationCandidate: VolumeInfo?
    @State private var registrationName = ""
    @State private var isHostFolderPickerPresented = false
    @State private var selectedPlace: UUID?
    @State private var targetToForget: ReplicationTarget?

    /// The answer, before the diagram of it.
    ///
    /// This screen is what "Is it safe" opens on, and it opened on a picture:
    /// a hub, some spokes, and half a window of white space under them. A
    /// diagram is a good way to show *where* the copies are and a poor way to
    /// answer *whether they are enough* — the reader had to count the green
    /// boxes and know what green meant. So the sentence comes first and the
    /// map illustrates it, which is also what fills the space the map left.
    @ViewBuilder
    private var verdict: some View {
        let damaged = store.protectionStates.values.filter { $0 == .driftDetected }.count
        let short = store.protectionStates.values.filter { $0.verdict == .shortOfPolicy }.count
        let holders = store.targets.count
        let reachable = store.targets.filter { store.reachablePaths[$0.id] != nil }.count

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: damaged > 0 ? "exclamationmark.triangle.fill"
                  : short > 0 ? "exclamationmark.circle.fill" : "checkmark.seal.fill")
                .font(.title)
                .foregroundStyle(damaged > 0 ? .red : short > 0 ? .orange : .green)
            VStack(alignment: .leading, spacing: 3) {
                Text(verdictHeadline(damaged: damaged, short: short, holders: holders))
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verdictDetail(reachable: reachable, holders: holders))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// Two copies that can be lost by one action.
    ///
    /// The photos here are not short of anything — on a real archive all 18,136
    /// of them sit on both drives, and every check the app runs says so. What
    /// they share is *how* they would go: their copies are the same Takeout
    /// files on each drive, so deleting those files, on both, loses photos that
    /// every other screen reports as safely duplicated.
    ///
    /// Said plainly rather than as a warning colour, because nothing is wrong
    /// yet and there is nothing to fix — the app counts photos inside those
    /// files rather than storing a second copy, which is what keeps the archive
    /// from doubling in size. It is a fact about the shape of the archive, and
    /// the only place it can be read.
    @ViewBuilder
    private var archiveBackedNote: some View {
        if store.archiveBackedOnlyCount > 0 {
            Label {
                Text("\(store.archiveBackedOnlyCount.formatted()) of them are inside your Google Takeout files rather than copied out of them. Those are the same files on each drive, so deleting them is the one thing that would lose photos the app otherwise counts as safe.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "shippingbox")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func verdictHeadline(damaged: Int, short: Int, holders: Int) -> String {
        if store.assets.isEmpty { return "Nothing in the archive yet." }
        if holders == 0 { return "No drive is holding your photos yet." }
        if damaged > 0 {
            return "\(Formatters.count(damaged, "photo")) \(damaged == 1 ? "has" : "have") a copy that no longer matches."
        }
        if short > 0 {
            return "\(short.formatted()) of \(store.protectionStates.count.formatted()) photos are not yet on all the drives they are meant to be on."
        }
        // Answers how many *places*, not whether the bookkeeping balances. A
        // photo alone on one drive satisfies a one-copy group, so "on all the
        // drives it is meant to be on" reads as reassurance while describing
        // the least safe arrangement there is.
        if let fewest = store.leastCopiesAnywhere {
            switch fewest {
            case 0: return "Some photos are not on any drive."
            case 1: return "Some photos are on one drive only."
            default: return "Every photo is on \(Formatters.count(fewest, "drive"))."
            }
        }
        return "Yes — every photo is on all the drives it is meant to be on."
    }

    private func verdictDetail(reachable: Int, holders: Int) -> String {
        guard holders > 0 else {
            return "Register a drive below and the archive starts copying itself onto it."
        }
        let plugged = reachable == 0
            ? "None are plugged in right now, which is fine — a drive that is away still holds what it held."
            : reachable == holders
                ? "All of them are plugged in."
                : "\(reachable) of \(holders) plugged in right now."
        return plugged + " Copies are checked by reading them back; the app works through that in the background."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // A transfer can be started from this screen, so its progress
                // has to be visible here rather than only on the Takeout one.
                if store.isTransferringParts, let activity = store.takeoutActivity {
                    TakeoutActivityBanner(activity: activity)
                }

                verdict

                archiveBackedNote

                ArchivePlaceList(
                    places: places,
                    selection: $selectedPlace,
                    onActivateEmpty: activate
                )

                // Detail lives under the list rather than in the row: a row has
                // room for a name, its holdings and a state, not for capacity,
                // progress and the controls that act on them.
                if let target = selectedTarget {
                    DriveCard(drive: target, onForget: { targetToForget = target })
                } else if !store.targets.isEmpty {
                    Text("Click a drive above for its detail and controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Both of these are answers to "is it safe", and both are
                // empty on a healthy archive — which is exactly why they were
                // wrong as permanent tabs. Here they are silent until they
                // have something, and unmissable when they do.
                if !store.violations.isEmpty {
                    CardBox(title: "Things to review", systemImage: "exclamationmark.triangle") {
                        ViolationsSummary()
                    }
                }
                if !store.migrationJobs.filter({ $0.state.isActive }).isEmpty {
                    CardBox(title: "Photos on the move", systemImage: "arrow.left.arrow.right") {
                        MigrationsSummary()
                    }
                }

                StorageGroupsList()

                if !store.heldExportParts.isEmpty || !store.partTransferPlan.transfers.isEmpty {
                    CardBox(title: "Export parts in transit", systemImage: "shippingbox") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("When the drive that has a part and the drive that needs it are never reachable at the same time, the part waits here in between. It is deleted as soon as it lands.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(store.heldExportParts) { part in
                                HStack {
                                    Label(part.displayName, systemImage: "shippingbox")
                                        .font(.callout)
                                    Text(Formatters.bytes.string(fromByteCount: part.sizeBytes))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("waiting since \(Formatters.relative(part.stagedAt))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if !store.partTransferPlan.transfers.isEmpty {
                                HStack {
                                    Text("\(Formatters.count(store.partTransferPlan.transfers.count, "file")) can be copied now — \(Formatters.bytes.string(fromByteCount: store.partTransferPlan.bytesToMove)).")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if store.isTransferringParts {
                                        Button("Stop") { store.cancelExportPartTransfers() }
                                    } else {
                                        Button("Move them now") { store.transferExportParts() }
                                            .disabled(store.isSyncing || store.isImporting || store.takeoutActivity != nil)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                stagingFooter
            }
            .padding(20)
        }
        .navigationTitle("Copies")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { @MainActor in
                        await store.rescanTargetsOffMainThread()
                        // On demand means on demand: check the paths still
                        // resolve rather than only noticing at the next mount.
                        // After the await, so it reads a settled scan.
                        for target in store.targets where store.reachablePaths[target.id] != nil {
                            store.repairReplicaPaths(for: target.id)
                        }
                    }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(item: $registrationCandidate) { volume in
            registrationSheet(volume)
        }
        .confirmationDialog(
            "Forget \(targetToForget?.name ?? "this drive")?",
            isPresented: Binding(
                get: { targetToForget != nil },
                set: { if !$0 { targetToForget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget it", role: .destructive) {
                if let targetToForget { store.forgetTarget(targetToForget.id) }
                selectedPlace = nil
                targetToForget = nil
            }
            Button("Cancel", role: .cancel) { targetToForget = nil }
        } message: {
            Text("Nothing on it is deleted. The app stops counting it as a copy, which frees the slot for a replacement.")
        }
        .fileImporter(
            isPresented: $isHostFolderPickerPresented,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                store.registerHostDeviceTarget(at: url, name: url.lastPathComponent)
            }
        }
    }

    private var selectedTarget: ReplicationTarget? {
        selectedPlace.flatMap { id in store.targets.first { $0.id == id } }
    }

    private var unmanagedVolumes: [VolumeInfo] {
        store.availableVolumes.filter { volume in
            TargetMonitor.match(volume: volume, against: store.targets) == nil
        }
    }

    /// Every place a copy could live: the targets that hold one, then the
    /// places that could. Empty slots are drawn, not hidden — "nothing is here"
    /// is the answer the user came for as much as "everything is here".
    private var places: [ArchivePlace] {
        var result = store.targets.map { target -> ArchivePlace in
            let breakdown = store.driveBreakdowns[target.id] ?? DriveContentBreakdown()
            let reachable = store.reachablePaths[target.id] != nil
            let state: ArchivePlace.State
            if breakdown.driftPhotos > 0 {
                state = .damaged(count: breakdown.driftPhotos)
            } else if breakdown.expectedPhotos > 0, breakdown.presentPhotos < breakdown.expectedPhotos {
                state = .filling(photosHeld: breakdown.presentPhotos, photosExpected: breakdown.expectedPhotos)
            } else if breakdown.expectedPhotos == 0 {
                // Holds nothing and is owed nothing, because no group names it.
                // This fell through to `.complete` and read "Complete copy" —
                // the every-device-holds-everything model talking. Under
                // k-of-n a device is complete when it holds what it was asked
                // to hold, and one asked for nothing is empty, not complete.
                // The card underneath already said "Nothing to hold yet", so
                // the two halves of the same screen contradicted each other.
                state = .empty
            } else {
                state = .complete
            }
            return ArchivePlace(
                id: target.id,
                name: target.name,
                symbol: target.kind == .hostDevice ? "laptopcomputer" : "externaldrive.fill",
                state: state,
                isReachable: reachable,
                detail: detail(for: state, reachable: reachable, target: target),
                heldPhotos: breakdown.presentPhotos,
                heldBytes: breakdown.presentBytes,
                neverCheckedPhotos: breakdown.neverCheckedPhotos,
                target: target
            )
        }

        // This Mac is adopted as a target on first launch, so an empty slot
        // here means it was deliberately forgotten — the supported way to run
        // an archive the boot disk cannot hold. The detail says what taking it
        // back would cost, since that is the decision being offered.
        if !store.targets.contains(where: { $0.kind == .hostDevice }) {
            let needed = Formatters.bytes.string(fromByteCount: store.localArchiveBytes)
            result.append(ArchivePlace(
                id: Self.hostDevicePlaceID,
                name: store.hostDeviceName,
                symbol: "laptopcomputer",
                state: .empty,
                isReachable: true,
                detail: "Holding no copy · \(needed) to add",
                target: nil
            ))
        }
        for volume in unmanagedVolumes {
            result.append(ArchivePlace(
                // Derived from the mount path so the slot keeps its identity
                // between redraws; these places have no target ID yet.
                id: Self.placeID(forPath: volume.url.path),
                name: volume.name,
                symbol: "externaldrive",
                state: .empty,
                isReachable: true,
                detail: "Connected, holding no copy",
                target: nil
            ))
        }
        return result
    }

    private func detail(for state: ArchivePlace.State, reachable: Bool, target: ReplicationTarget) -> String {
        let presence = reachable
            ? "Connected"
            : "Not connected · \(Formatters.relative(target.lastSeenAt))"
        switch state {
        case .complete:
            return "Complete copy · \(presence)"
        case .filling(let held, let expected):
            return "\(held.formatted()) of \(expected.formatted()) photos · \(presence)"
        case .damaged(let count):
            return "\(count.formatted()) damaged · \(presence)"
        case .empty:
            return presence
        }
    }

    /// Stable id so the empty host-device slot keeps its identity across
    /// redraws and does not animate as a different node each time.
    private static let hostDevicePlaceID = UUID(uuidString: "00000000-0000-0000-0000-00000000D0C1")!

    private static func placeID(forPath path: String) -> UUID {
        var hasher = Hasher()
        hasher.combine(path)
        let value = UInt64(bitPattern: Int64(hasher.finalize()))
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: value >> 56), UInt8(truncatingIfNeeded: value >> 48),
            UInt8(truncatingIfNeeded: value >> 40), UInt8(truncatingIfNeeded: value >> 32),
            UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
            0, 0, 0, 0, 0, 0, 0, 1
        ))
    }

    private func activate(_ place: ArchivePlace) {
        if place.id == Self.hostDevicePlaceID {
            isHostFolderPickerPresented = true
            return
        }
        if let volume = unmanagedVolumes.first(where: { $0.name == place.name }) {
            registrationName = volume.name
            registrationCandidate = volume
        }
    }

    /// Staging is transit, not a place the archive lives, so it gets a line
    /// rather than a panel — and only mentions waiting assets when there are
    /// any to wait for.
    private var stagingFooter: some View {
        let stagedOnly = store.protectionStates.values.filter { $0 == .stagedOnly }.count
        let reclaimable = store.stagingReclaimPlan
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "tray")
                Text("Staging · \(Formatters.bytes.string(fromByteCount: store.staging.totalBytes))")
                if stagedOnly > 0 {
                    Text("· \(stagedOnly.formatted()) waiting for a target")
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            // Said before it happens, not after. A copy disappearing from the
            // Mac is alarming unless the reader already knows the rule, and
            // the rule is the reassuring part: it goes because the drives have
            // it, and only once they have been read back and matched.
            if !reclaimable.isEmpty {
                HStack(spacing: 6) {
                    Text(store.reclaimStagingWhenSafe
                         ? "\(Formatters.bytes.string(fromByteCount: reclaimable.bytes)) of this is content your drives already hold safely, and is released after the next sync."
                         : "\(Formatters.bytes.string(fromByteCount: reclaimable.bytes)) of this is content your drives already hold safely.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Release now") { store.reclaimStaging(force: true) }
                        .buttonStyle(.link)
                    Spacer(minLength: 0)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(store.staging.rootURL.path)
    }

    private func registrationSheet(_ volume: VolumeInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Register managed drive")
                .font(.title3)
                .bold()
            Text("A marker file (\(ReplicationTarget.markerFileName)) will be written to \(volume.url.path) so the drive is recognized by identity, not mount path. All existing Local assets will be queued for replication to it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Drive name", text: $registrationName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { registrationCandidate = nil }
                Button("Register") {
                    store.registerVolumeTarget(volume: volume, name: registrationName)
                    registrationCandidate = nil
                }
                .buttonStyle(.borderedProminent)
            }
            // No cap: copies are per photo, not devices in total, and refusing
            // a drive because two copies were asked for confused the two.
            //
            // Nor does adding a device change where anything goes. This line
            // used to say the archive would spread itself across devices "by
            // whichever has the most room", which was the model before this
            // one — the app choosing destinations is precisely what SPEC
            // invariant 4 rules out.
            Text("Registering a drive moves nothing by itself. A group that works out its own devices will use this one as soon as it asks for more copies than it has drives; a group set to specific drives stays exactly where you put it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 460)
    }
}
