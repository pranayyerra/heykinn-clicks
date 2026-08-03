import SwiftUI

struct DrivesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var registrationCandidate: VolumeInfo?
    @State private var registrationName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                connectionSummary

                // A transfer can be started from this screen, so its progress
                // has to be visible here rather than only on the Takeout one.
                if store.isTransferringParts, let activity = store.takeoutActivity {
                    TakeoutActivityBanner(activity: activity)
                }

                if store.drives.isEmpty {
                    Text("No drives registered yet. The archive still works — imports land in Mac staging — but Local assets stay Staged Only until you register \(store.redundancyPolicy.description).")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 12)], spacing: 12) {
                        ForEach(store.drives) { drive in
                            DriveCard(drive: drive)
                        }
                    }
                }

                CardBox(title: "Catalog backup", systemImage: "shield.checkerboard") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            if let latest = store.latestCatalogSnapshot {
                                Label(
                                    "Last snapshot \(Formatters.relative(latest.createdAt)) · \(Formatters.bytes.string(fromByteCount: latest.sizeBytes))",
                                    systemImage: "checkmark.shield"
                                )
                                .font(.callout)
                                .foregroundStyle(.green)
                            } else {
                                Label("No snapshot yet", systemImage: "exclamationmark.shield")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button("Back up now") { store.backupCatalog(force: true) }
                                .disabled(store.connectedMounts.isEmpty)
                        }
                        ForEach(store.drives) { drive in
                            let snapshots = store.catalogSnapshots[drive.id] ?? []
                            if !snapshots.isEmpty {
                                Text("\(drive.name): \(snapshots.count) snapshot(s), newest \(snapshots[0].displayName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if store.connectedMounts.isEmpty {
                            Text("Connect a managed drive to store a snapshot.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if !store.heldExportParts.isEmpty || !store.partTransferPlan.transfers.isEmpty {
                    CardBox(title: "Export parts in transit", systemImage: "shippingbox") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("When the drive that has a part and the drive that needs it are never plugged in at the same time, the part waits here on the Mac in between. It is deleted as soon as it reaches the other drive.")
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
                                    Text("\(store.partTransferPlan.transfers.count) part(s) can move now — \(Formatters.bytes.string(fromByteCount: store.partTransferPlan.bytesToMove)).")
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

                CardBox(title: "Mac staging", systemImage: "tray") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledRow(label: "Location", value: store.staging.rootURL.path)
                        LabeledRow(label: "Size", value: Formatters.bytes.string(fromByteCount: store.staging.totalBytes))
                        LabeledRow(
                            label: "Staged-only assets",
                            value: "\(store.protectionStates.values.filter { $0 == .stagedOnly }.count)"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                CardBox(title: "Available volumes", systemImage: "externaldrive.badge.plus") {
                    let unmanaged = store.availableVolumes.filter { volume in
                        DriveMonitor.match(volume: volume, against: store.drives) == nil
                    }
                    if unmanaged.isEmpty {
                        Text("No unmanaged external volumes mounted.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(unmanaged) { volume in
                                HStack {
                                    Label(volume.name, systemImage: "externaldrive")
                                    Text(volume.url.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Register as managed drive…") {
                                        registrationName = volume.name
                                        registrationCandidate = volume
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Drives & Health")
        .toolbar {
            ToolbarItem {
                Button {
                    store.rescanDrives()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(item: $registrationCandidate) { volume in
            registrationSheet(volume)
        }
    }

    private var connectionSummary: some View {
        let connectedCount = store.drives.filter { store.connectedMounts[$0.id] != nil }.count
        let text: String
        switch (store.drives.count, connectedCount) {
        case (0, _): text = "No managed drives registered."
        case (_, 0): text = "No managed drives connected — imports and catalog work continue; replication is queued."
        case (let total, let connected) where connected < total: text = "\(connected) of \(total) managed drives connected. The absent drive keeps accumulating backlog."
        default: text = "All managed drives connected."
        }
        return Label(text, systemImage: "info.circle")
            .foregroundStyle(.secondary)
    }

    private func registrationSheet(_ volume: VolumeInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Register managed drive")
                .font(.title3)
                .bold()
            Text("A marker file (\(ManagedDrive.markerFileName)) will be written to \(volume.url.path) so the drive is recognized by identity, not mount path. All existing Local assets will be queued for replication to it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Drive name", text: $registrationName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { registrationCandidate = nil }
                Button("Register") {
                    store.registerDrive(volume: volume, name: registrationName)
                    registrationCandidate = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.drives.count >= store.redundancyPolicy.desiredCopies)
            }
            if store.drives.count >= store.redundancyPolicy.desiredCopies {
                Text("\(store.redundancyPolicy.desiredCopies) managed drive(s) are already registered, which is what the local redundancy policy asks for.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
