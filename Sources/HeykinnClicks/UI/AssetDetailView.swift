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
                                ProtectionBadge(state: store.protectionStates[asset.id] ?? .notApplicable, copies: store.desiredCopies(forAsset: asset.id))
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
                            LabeledRow(
                                label: "Captured",
                                value: asset.captureDate.map {
                                    asset.captureDateSource.isExact
                                        ? Formatters.dateTime.string(from: $0)
                                        : "\(Calendar.current.component(.year, from: $0)) (approximate)"
                                } ?? "Unknown"
                            )
                            LabeledRow(label: "Date known from", value: asset.captureDateSource.displayName)
                            LabeledRow(label: "Imported", value: Formatters.dateTime.string(from: asset.importDate))
                            // Sits between the two rows it is about, rather
                            // than in a panel further down: the caveat is
                            // useless anywhere the claim is not visible.
                            if let impossible = asset.impossibleCaptureDate {
                                impossibleDateNote(impossible)
                            }
                            LabeledRow(label: "Size", value: Formatters.bytes.string(fromByteCount: asset.fileSize))
                            if let width = asset.pixelWidth, let height = asset.pixelHeight {
                                LabeledRow(label: "Dimensions", value: "\(width) × \(height)")
                            }
                            // The whole hash, truncated by the view rather
                            // than by the string. Cutting it in code and
                            // appending an ellipsis was invisible until text
                            // became selectable — and then copying the one
                            // value anybody would ever want to copy gave back
                            // twenty characters and a "…".
                            LabeledRow(label: "Content hash", value: asset.contentHash, truncates: true)
                            ForEach(asset.exifSummary.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                LabeledRow(label: key, value: value)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }

                    GroupBox("Where this should be kept") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("This changes where the photo is meant to be kept. It does not move anything. Until something does, Keep safe will show it as being in the wrong place — so if you want it actually moved, start a move instead.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("Kept on", selection: Binding(
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
                                Text("No copies on any drive yet.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }

                    if let original = store.originalOf(asset) {
                        GroupBox("Edited from") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Google exported this edit and its original as separate files. They are linked so the edit sits beside what it came from rather than drifting to the wrong end of the timeline.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                NavigationLink(value: original.id) {
                                    Label(original.originalFilename, systemImage: "photo.on.rectangle.angled")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        }
                    }
                    if !store.editsOf(asset).isEmpty {
                        GroupBox("Edited versions") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(store.editsOf(asset)) { edit in
                                    NavigationLink(value: edit.id) {
                                        Label(edit.originalFilename, systemImage: "wand.and.stars")
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        }
                    }

                    if let motion = store.livePhotoMotion(for: asset) {
                        GroupBox("Live Photo") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("The moving half is kept as its own file, so it is looked after and checked for damage the same way the still is.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                LabeledRow(label: "Motion file", value: motion.originalFilename)
                                LabeledRow(label: "Size", value: Formatters.bytes.string(fromByteCount: motion.fileSize))
                                HStack(spacing: 8) {
                                    ResidencyBadge(domain: motion.residency)
                                    ProtectionBadge(state: store.protectionStates[motion.id] ?? .notApplicable, copies: store.desiredCopies(forAsset: motion.id))
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
                Text("This only changes where the photo is meant to be kept. Nothing is moved, and Keep safe will show it as being in the wrong place until something moves it.")
            }
        } else {
            ContentUnavailableView("Photo not found", systemImage: "questionmark.square")
        }
    }

    /// The full account of an impossible capture date: what is wrong, and that
    /// the app deliberately did not fix it. Both halves are needed — a warning
    /// with no statement of restraint reads as a defect the app failed to
    /// handle, rather than as a fact about the file.
    private func impossibleDateNote(_ impossible: ImpossibleCaptureDate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(ImpossibleCaptureDate.headline, systemImage: ImpossibleCaptureDate.symbolName)
                .font(.callout)
                .foregroundStyle(.orange)
            Text(impossible.finding)
            Text(impossible.restraint)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 4)
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
                guard let drive = store.targetsByID[replica.targetID] else { return nil }
                let connected = store.reachablePaths[drive.id] != nil ? "connected" : "offline"
                let checked = replica.lastVerifiedAt.map { "checked \(Formatters.relative($0))" } ?? "never checked"
                var line = "\(drive.name) (\(connected)): \(replica.state.displayName), \(checked)"
                // Which copy this is matters to the reader in one specific
                // way: a copy that is their own file, at their own path, is
                // one they can delete while tidying up. The app will never
                // remove it — and will never get it back either.
                if let path = archiveBackedPath(replica) {
                    line += " — this copy is your own file at \(path)"
                }
                return (replica.id, line)
            }
    }

    /// Where a replica backed by the user's own content sits on its drive.
    /// Nil for copies the app wrote and manages under its own folder.
    private func archiveBackedPath(_ replica: TargetReplicaState) -> String? {
        guard ReplicationService.isVolumeBacked(replica), let relative = replica.relativePath
        else { return nil }
        return String(relative.dropFirst(ReplicationService.volumeBackedPrefix.count))
    }
}
