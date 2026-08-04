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

    private func verdictHeadline(damaged: Int, short: Int, holders: Int) -> String {
        if store.assets.isEmpty { return "Nothing in the archive yet." }
        if holders == 0 { return "No drive is holding your photos yet." }
        if damaged > 0 {
            return "\(Formatters.count(damaged, "photo")) \(damaged == 1 ? "has" : "have") a copy that no longer matches."
        }
        if short > 0 {
            return "\(short.formatted()) of \(store.protectionStates.count.formatted()) photos do not have \(store.redundancyPolicy.description) yet."
        }
        return "Yes — every photo has \(store.redundancyPolicy.description)."
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

                ArchiveMapView(
                    photoCount: photoCount,
                    fileCount: store.assets.count,
                    byteCount: store.localArchiveBytes,
                    places: places,
                    selection: $selectedPlace,
                    onActivateEmpty: activate
                )

                // Detail lives under the map rather than on it: a spoke has room
                // for a name and a state, not for capacity, progress and the
                // controls that act on them.
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

                if !store.heldExportParts.isEmpty || !store.partTransferPlan.transfers.isEmpty {
                    CardBox(title: "Export parts in transit", systemImage: "shippingbox") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("When the target that has a part and the target that needs it are never reachable at the same time, the part waits here in between. It is deleted as soon as it lands.")
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
        .navigationTitle("Storage & Health")
        .toolbar {
            ToolbarItem {
                Button {
                    store.rescanTargets()
                    // On demand means on demand: check the paths still resolve
                    // rather than only noticing at the next mount.
                    for target in store.targets where store.reachablePaths[target.id] != nil {
                        store.repairReplicaPaths(for: target.id)
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
            "Forget \(targetToForget?.name ?? "this target")?",
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

    /// Photos, not files: a Live Photo is one photo though it is a still and a
    /// movie on disk, and leading with the file count overstates the library.
    private var photoCount: Int {
        store.assets.filter { !$0.isLivePhotoMotion }.count
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
                target: target
            )
        }

        if !store.targets.contains(where: { $0.kind == .hostDevice }) {
            result.append(ArchivePlace(
                id: Self.hostDevicePlaceID,
                name: "This device",
                symbol: "laptopcomputer",
                state: .empty,
                isReachable: true,
                detail: "No copy here · \(Formatters.bytes.string(fromByteCount: store.localArchiveBytes)) to add",
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
        return HStack(spacing: 6) {
            Image(systemName: "tray")
            Text("Staging · \(Formatters.bytes.string(fromByteCount: store.staging.totalBytes))")
            if stagedOnly > 0 {
                Text("· \(stagedOnly.formatted()) waiting for a target")
                    .foregroundStyle(.orange)
            }
            Spacer()
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
                .disabled(store.targets.count >= store.redundancyPolicy.desiredCopies)
            }
            if store.targets.count >= store.redundancyPolicy.desiredCopies {
                Text("\(store.redundancyPolicy.desiredCopies) managed drive(s) are already registered, which is what the local redundancy policy asks for.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
