import SwiftUI

struct AssetDetailView: View {
    let assetID: UUID
    @EnvironmentObject private var store: AppStore
    @State private var pendingResidency: ResidencyDomain?

    private var asset: Asset? { store.assetsByID[assetID] }

    var body: some View {
        if let asset {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 20) {
                        AssetThumbnailView(asset: asset)
                            .frame(width: 260, height: 260)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(asset.originalFilename)
                                .font(.title2)
                                .bold()
                            HStack(spacing: 8) {
                                ResidencyBadge(domain: asset.residency)
                                ProtectionBadge(state: store.protectionStates[asset.id] ?? .notApplicable)
                            }
                            Text("Residency set by \(asset.residencySource.displayName.lowercased())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            presenceChips(asset)
                            if asset.cloudPresenceEvidence != .none {
                                Label(
                                    "Cloud presence: \(asset.cloudPresenceEvidence.displayName)",
                                    systemImage: asset.cloudPresenceEvidence.isTrustworthy
                                        ? "checkmark.seal" : "questionmark.circle"
                                )
                                .font(.caption)
                                .foregroundStyle(asset.cloudPresenceEvidence.isTrustworthy ? .green : .orange)
                            }
                        }
                        Spacer()
                    }

                    GroupBox("Metadata") {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledRow(label: "Kind", value: asset.kind.displayName)
                            LabeledRow(label: "Origin", value: asset.importOrigin.displayName)
                            LabeledRow(label: "Captured", value: asset.captureDate.map { Formatters.dateTime.string(from: $0) } ?? "Unknown")
                            LabeledRow(label: "Imported", value: Formatters.dateTime.string(from: asset.importDate))
                            LabeledRow(label: "Size", value: Formatters.bytes.string(fromByteCount: asset.fileSize))
                            if let width = asset.pixelWidth, let height = asset.pixelHeight {
                                LabeledRow(label: "Dimensions", value: "\(width) × \(height)")
                            }
                            LabeledRow(label: "Content hash", value: String(asset.contentHash.prefix(20)) + "…")
                            ForEach(asset.exifSummary.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                LabeledRow(label: key, value: value)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }

                    GroupBox("Residency") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Changing residency here only reassigns the logical domain. The Violations screen will flag the presence mismatch until a migration moves the actual content — prefer creating a migration for real moves.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("Residency domain", selection: Binding(
                                get: { asset.residency },
                                set: { pendingResidency = $0 }
                            )) {
                                ForEach(ResidencyDomain.allCases) { domain in
                                    Text(domain.displayName).tag(domain)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 420)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }

                    GroupBox("Local storage") {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledRow(
                                label: "Staging",
                                value: asset.stagingRelativePath.map {
                                    store.staging.exists(relativePath: $0) ? "Staged (\($0))" : "Recorded but file missing (\($0))"
                                } ?? "Not staged"
                            )
                            ForEach(replicaRows(for: asset), id: \.0) { _, text in
                                Text(text)
                                    .font(.callout)
                            }
                            if replicaRows(for: asset).isEmpty {
                                Text("No drive replicas tracked.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }

                    if let motion = store.livePhotoMotion(for: asset) {
                        GroupBox("Live Photo") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("The moving half is kept as its own file, so it gets the same residency and damage checking as the still.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                LabeledRow(label: "Motion file", value: motion.originalFilename)
                                LabeledRow(label: "Size", value: Formatters.bytes.string(fromByteCount: motion.fileSize))
                                HStack(spacing: 8) {
                                    ResidencyBadge(domain: motion.residency)
                                    ProtectionBadge(state: store.protectionStates[motion.id] ?? .notApplicable)
                                }
                                NavigationLink(value: motion.id) {
                                    Text("Show the motion file")
                                        .font(.caption)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        }
                    }

                    if let group = store.duplicateGroups.first(where: { $0.assetIDs.contains(asset.id) }) {
                        GroupBox("Exact duplicates") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(group.assetIDs.filter { $0 != asset.id }, id: \.self) { otherID in
                                    if let other = store.assetsByID[otherID] {
                                        NavigationLink(value: otherID) {
                                            Label(other.originalFilename, systemImage: "square.on.square")
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        }
                    }

                    GroupBox("History") {
                        VStack(alignment: .leading, spacing: 4) {
                            let events = store.auditEvents.filter { $0.assetID == asset.id }
                            if events.isEmpty {
                                Text("No recorded events for this asset.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(events) { event in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(Formatters.dateTime.string(from: event.at))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 150, alignment: .leading)
                                    Text(event.message)
                                        .font(.callout)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                }
                .padding()
            }
            .navigationTitle(asset.originalFilename)
            .confirmationDialog(
                "Reassign residency?",
                isPresented: Binding(
                    get: { pendingResidency != nil },
                    set: { if !$0 { pendingResidency = nil } }
                )
            ) {
                if let target = pendingResidency {
                    Button("Reassign to \(target.displayName)") {
                        store.setManualResidency(assetID: asset.id, to: target)
                        pendingResidency = nil
                    }
                }
                Button("Cancel", role: .cancel) { pendingResidency = nil }
            } message: {
                Text("This flips the logical domain only. Content is not moved; any presence mismatch will appear in Violations.")
            }
        } else {
            ContentUnavailableView("Asset not found", systemImage: "questionmark.square")
        }
    }

    private func presenceChips(_ asset: Asset) -> some View {
        HStack(spacing: 6) {
            Text("Present in:")
                .font(.caption)
                .foregroundStyle(.secondary)
            if asset.presence.count == 0 {
                Text("nowhere known")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            ForEach(asset.presence.domains) { domain in
                Text(domain.displayName)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(domain.tint.opacity(0.12), in: Capsule())
            }
        }
    }

    private func replicaRows(for asset: Asset) -> [(String, String)] {
        store.replicaStates
            .filter { $0.assetID == asset.id }
            .compactMap { replica in
                guard let drive = store.drivesByID[replica.driveID] else { return nil }
                let connected = store.connectedMounts[drive.id] != nil ? "connected" : "offline"
                let checked = replica.lastVerifiedAt.map { "checked \(Formatters.relative($0))" } ?? "never checked"
                return (replica.id, "\(drive.name) (\(connected)): \(replica.state.displayName), \(checked)")
            }
    }
}
