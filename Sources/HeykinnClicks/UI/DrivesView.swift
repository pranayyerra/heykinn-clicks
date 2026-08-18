import SwiftUI

struct DrivesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var registrationCandidate: VolumeInfo?
    @State private var registrationName = ""
    @State private var isHostFolderPickerPresented = false
    @State private var isExternalDrivePickerPresented = false
    /// Nil means the general Add Drive button; non-nil means an enumerated
    /// drive row asked the user to grant that particular device.
    @State private var expectedVolumeSelection: VolumeInfo?
    /// Keeps the file-panel grant alive while the naming sheet is open. The
    /// registration converts it into a persistent target bookmark.
    @State private var selectedVolumeAccess: SecurityScopedAccess?
    /// The device the user is being asked to point at, for a build that cannot
    /// go looking for it itself.
    @State private var targetToLocate: UUID?
    @State private var targetToForget: ReplicationTarget?

    /// The answer, given the weight of an answer.
    ///
    /// This screen is what "is it safe" opens on, and it opened on a picture:
    /// a hub, some spokes, and half a window of white space under them. A
    /// diagram is a good way to show *where* the copies are and a poor way to
    /// answer *whether they are enough* — the reader had to count the green
    /// boxes and know what green meant. So the sentence comes first.
    ///
    /// It is set in a tinted panel rather than as the first line of a stack
    /// because it is not the first of several things; it is the conclusion, and
    /// everything below it is the working. The Takeout caveat sits inside the
    /// same panel for the same reason — it qualifies this sentence, and as a
    /// separate block underneath it read as a second, unrelated alarm.
    @ViewBuilder
    private var verdict: some View {
        let damaged = store.protectionStates.values.filter { $0 == .driftDetected }.count
        let short = store.protectionStates.values.filter { $0.verdict == .shortOfPolicy }.count
        let holders = store.targets.count
        let reachable = store.targets.filter { store.reachablePaths[$0.id] != nil }.count
        // The mark has to agree with the sentence beside it: whatever the
        // headline reports as short, this is not green for.
        let thin = (store.leastCopiesAnywhere ?? 2) < 2
        let tint: Color = damaged > 0 ? .red : (short > 0 || thin) ? .orange : .green

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: damaged > 0 ? "exclamationmark.triangle.fill"
                      : (short > 0 || thin) ? "exclamationmark.circle.fill" : "checkmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(SafetyAnswer.headline(store.safetyFacts))
                        .font(.title2.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verdictDetail(reachable: reachable, holders: holders))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            archiveBackedNote
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        )
    }

    /// Two copies that can be lost by one action.
    ///
    /// The photos here are not short of anything — on a real archive all 21,380
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

    /// The one answer, worked out in one place — this screen and Overview used
    /// to write it separately and disagree. See `SafetyAnswer`.
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

                devicesToLocate

                verdict

                StorageMatrix(
                    places: places,
                    archivePhotoCount: store.localPhotoCount,
                    onActivateEmpty: activate,
                    onForget: { targetToForget = $0 }
                )

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
                    CardBox(
                        title: "Photos on the move",
                        systemImage: "arrow.left.arrow.right",
                        help: "While a move is running its photos are in both places. Finishing it is what puts them back to one."
                    ) {
                        MigrationsSummary()
                    }
                }

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
                    expectedVolumeSelection = nil
                    isExternalDrivePickerPresented = true
                } label: {
                    Label("Add Drive", systemImage: "externaldrive.badge.plus")
                }
                .help("Choose an external drive for the archive")
            }
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
                targetToForget = nil
            }
            Button("Cancel", role: .cancel) { targetToForget = nil }
        } message: {
            Text("Nothing on it is deleted. The app stops counting it as a copy; another device can be added whenever you choose.")
        }
        .fileImporter(
            isPresented: $isHostFolderPickerPresented,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                guard let access = SecurityScopedAccess(url: url) else {
                    store.lastError = "macOS did not grant access to \(url.lastPathComponent). Choose the folder again and try once more."
                    return
                }
                withExtendedLifetime(access) {
                    store.registerHostDeviceTarget(at: url, name: url.lastPathComponent)
                }
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { targetToLocate != nil },
                set: { if !$0 { targetToLocate = nil } }
            ),
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result, let targetToLocate {
                guard let access = SecurityScopedAccess(url: url) else {
                    store.lastError = "macOS did not grant access to \(url.lastPathComponent). Choose the drive again and try once more."
                    self.targetToLocate = nil
                    return
                }
                _ = withExtendedLifetime(access) {
                    store.locateTarget(targetToLocate, at: url)
                }
            }
            targetToLocate = nil
        }
        .background {
            Color.clear.fileImporter(
                isPresented: $isExternalDrivePickerPresented,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                defer { expectedVolumeSelection = nil }
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    guard let access = SecurityScopedAccess(url: url) else {
                        store.lastError = "macOS did not grant access to \(url.lastPathComponent). Choose the external drive itself and try again."
                        return
                    }
                    guard let volume = store.userSelectedVolume(
                        at: url,
                        matching: expectedVolumeSelection
                    ) else { return }
                    selectedVolumeAccess = access
                    registrationName = volume.name
                    registrationCandidate = volume
                case .failure(let error):
                    store.lastError = "Could not open the selected drive: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Devices registered before this app could keep hold of them, which a
    /// sandboxed build cannot find on its own.
    ///
    /// Shown above everything, because until it is dealt with every drive reads
    /// as away while sitting plugged into the device — and "away" is the app
    /// saying it cannot see something rather than that it is gone.
    @ViewBuilder
    private var devicesToLocate: some View {
        let needing = store.targetsNeedingLocating
        if !needing.isEmpty {
            CardBox(title: "Show the app where these are", systemImage: "questionmark.folder") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("These devices were registered before this version, which needs to be handed each one once before it can reach them. Nothing on them has changed, and nothing is copied — point at the drive and it is remembered from then on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(needing) { target in
                        HStack {
                            Label(target.name, systemImage: "externaldrive.badge.questionmark")
                                .font(.callout)
                            Spacer(minLength: 12)
                            Button("Locate…") { targetToLocate = target.id }
                        }
                    }
                }
            }
        }
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
                soleCustodyPhotos: store.photosOnlyOn[target.id] ?? 0,
                target: target
            )
        }

        // This device is adopted as a target on first launch, so an empty slot
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
            if TargetBookmarks.isSandboxed {
                expectedVolumeSelection = volume
                isExternalDrivePickerPresented = true
            } else {
                registrationName = volume.name
                registrationCandidate = volume
            }
        }
    }

    /// Transit, not a place the archive lives, so it gets a line rather than a
    /// panel — and only mentions waiting photos when there are any to wait for.
    ///
    /// **Absent entirely when it is empty.** It used to sit at the foot of the
    /// screen reading "Staging · Zero KB", which is the app's own bookkeeping
    /// shown to somebody who has nothing waiting and nothing to do about it.
    /// A holding area with nothing in it is not news.
    @ViewBuilder
    private var stagingFooter: some View {
        let stagedOnly = store.protectionStates.values.filter { $0 == .stagedOnly }.count
        let reclaimable = store.stagingReclaimPlan
        if store.staging.totalBytes > 0 || stagedOnly > 0 {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // The one path on this screen that named a real folder and gave
                // no way to it — it was a tooltip, which is somewhere to read a
                // path from, not somewhere to go.
                FolderLink(
                    path: store.staging.rootURL.path,
                    display: "Waiting to be copied",
                    symbol: "tray"
                )
                Text("· \(Formatters.bytes.string(fromByteCount: store.staging.totalBytes))")
                    .foregroundStyle(.secondary)
                if stagedOnly > 0 {
                    Text("· \(stagedOnly.formatted()) waiting for a drive")
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            // Said before it happens, not after. A copy disappearing from the
            // device is alarming unless the reader already knows the rule, and
            // the rule is the reassuring part: it goes because the drives have
            // it, and only once they have been read back and matched.
            if !reclaimable.isEmpty {
                HStack(spacing: 6) {
                    Text(store.reclaimStagingWhenSafe
                         ? "\(Formatters.bytes.string(fromByteCount: reclaimable.bytes)) of this is content your drives already hold safely, and is released after the next sync."
                         : "\(Formatters.bytes.string(fromByteCount: reclaimable.bytes)) of this is content your drives already hold safely.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Release now") { store.reclaimStaging(force: true) }
                        .buttonStyle(.link)
                    Spacer(minLength: 0)
                }
            }
        }
        .font(.caption)
        // Not `.foregroundStyle(.secondary)` on the whole footer: it reaches
        // into the link and paints it grey, so the one thing here that goes
        // somewhere stops looking like it does. Each piece of text says what
        // colour it is.
        }
    }

    private func registrationSheet(_ volume: VolumeInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Use this drive for your photos")
                .font(.title3)
                .bold()
            Text("A small ID file (\(ReplicationTarget.markerFileName)) is written to \(volume.url.path), so the app still knows this drive after it is renamed or plugged into a different port. Every photo you already have is then queued to copy onto it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Drive name", text: $registrationName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") {
                    registrationCandidate = nil
                    selectedVolumeAccess = nil
                }
                Button("Register") {
                    if store.registerVolumeTarget(volume: volume, name: registrationName) {
                        registrationCandidate = nil
                        selectedVolumeAccess = nil
                    }
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
