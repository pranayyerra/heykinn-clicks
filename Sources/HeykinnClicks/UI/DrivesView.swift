import SwiftUI

struct DrivesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var registrationCandidate: VolumeInfo?
    @State private var registrationName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                connectionSummary

                Toggle("Automatically sync a managed drive when it connects", isOn: $store.autoSyncOnConnect)
                    .toggleStyle(.switch)

                GroupBox("Managed drives") {
                    if store.drives.isEmpty {
                        Text("No drives registered yet. The archive still works — imports land in Mac staging — but Local assets stay Staged Only until you register two drives.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(store.drives) { drive in
                                driveRow(drive)
                            }
                        }
                        .padding(6)
                    }
                }

                GroupBox("Catalog backup") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The media survives on the drives, but residency, replica state, duplicate grouping, and import history exist only in the catalog. Verified snapshots are written to each connected drive so losing the Mac does not lose the metadata.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    .padding(6)
                }

                GroupBox("Mac staging") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledRow(label: "Location", value: store.staging.rootURL.path)
                        LabeledRow(label: "Size", value: Formatters.bytes.string(fromByteCount: store.staging.totalBytes))
                        LabeledRow(
                            label: "Staged-only assets",
                            value: "\(store.protectionStates.values.filter { $0 == .stagedOnly }.count)"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Available volumes") {
                    let unmanaged = store.availableVolumes.filter { volume in
                        DriveMonitor.match(volume: volume, against: store.drives) == nil
                    }
                    if unmanaged.isEmpty {
                        Text("No unmanaged external volumes mounted.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
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
                        .padding(6)
                    }
                }
            }
            .padding()
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

    private func driveRow(_ drive: ManagedDrive) -> some View {
        let isConnected = store.connectedMounts[drive.id] != nil
        let backlog = store.backlogCount(for: drive.id)
        let driftCount = store.replicaStates.filter { $0.driveID == drive.id && $0.state == .drift }.count
        let progress = store.syncProgress?.driveID == drive.id ? store.syncProgress : nil

        return VStack(spacing: 8) {
        HStack(alignment: .top) {
            Circle()
                .fill(isConnected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 10, height: 10)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(drive.name)
                    .font(.headline)
                Text(isConnected
                     ? "Connected at \(store.connectedMounts[drive.id]?.path ?? "?")"
                     : "Not connected — last seen \(Formatters.relative(drive.lastSeenAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label("\(backlog) pending", systemImage: "tray.full")
                        .foregroundStyle(backlog > 0 ? .orange : .secondary)
                    Label("Last sync \(Formatters.relative(store.lastCompletedSync(for: drive.id)))", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                    if driftCount > 0 {
                        Label("\(driftCount) drifted", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption)
            }
            Spacer()
            if progress != nil {
                Button("Cancel") { store.cancelSync() }
            } else if isConnected {
                Button("Verify") { store.verifyDrive(drive.id) }
                    .disabled(store.isSyncing)
                Button("Sync now") { store.syncDrive(drive.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isSyncing || backlog == 0)
            }
        }
        if let progress {
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: progress.fractionComplete)
                HStack {
                    Text(progress.currentItem.map { "Syncing \($0)" } ?? "Syncing…")
                    Spacer()
                    Text("\(progress.completedTasks + progress.failedTasks) of \(progress.totalTasks)\(progress.failedTasks > 0 ? " (\(progress.failedTasks) failed)" : "")")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
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
                .disabled(store.drives.count >= 2)
            }
            if store.drives.count >= 2 {
                Text("Two managed drives are already registered — the v1 model manages exactly two replicas.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
