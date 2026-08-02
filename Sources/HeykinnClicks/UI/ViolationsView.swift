import SwiftUI

struct ViolationsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            Group {
                if store.violations.isEmpty {
                    ContentUnavailableView(
                        "No violations",
                        systemImage: "checkmark.seal",
                        description: Text("Every asset satisfies the exclusive-residency and replication invariants.")
                    )
                } else {
                    List {
                        ForEach(ResidencyDomain.allCases.filter { $0 != .local }, id: \.self) { domain in
                            let count = store.unverifiedCloudPresenceCount(domain: domain)
                            if count > 0 {
                                Section {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Label("\(count) asset(s) claim \(domain.displayName) presence that was never verified", systemImage: "questionmark.circle")
                                            .font(.headline)
                                        Text("The app has no \(domain.displayName) account connection, so it cannot check whether this content is still there. If it isn't, withdraw the claim — the assets stay Local, which is what hashing actually proves.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Button("Withdraw unverified \(domain.displayName) claim") {
                                            store.clearUnverifiedCloudPresence(domain: domain)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                        Section {
                            ForEach(store.violations) { violation in
                                violationRow(violation)
                            }
                        } header: {
                            Text("Violations are surfaced, never auto-fixed. Resolve them with a migration or by correcting presence records.")
                        }
                    }
                }
            }
            .navigationTitle("Violations")
            .navigationDestination(for: UUID.self) { assetID in
                AssetDetailView(assetID: assetID)
            }
        }
    }

    private func violationRow(_ violation: Violation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(for: violation.kind))
                .foregroundStyle(color(for: violation.kind))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(violation.kind.displayName)
                    .font(.headline)
                Text(violation.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let assetID = violation.assetID, store.assetsByID[assetID] != nil {
                    NavigationLink(value: assetID) {
                        Text("Show asset")
                            .font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func symbol(for kind: ViolationKind) -> String {
        switch kind {
        case .multiDomainCoexistence: return "square.stack.3d.up.badge.exclamationmark"
        case .residencyPresenceMismatch: return "questionmark.folder"
        case .migrationCleanupPending: return "clock.badge.exclamationmark"
        case .replicaDrift: return "exclamationmark.triangle"
        case .orphanReplica: return "externaldrive.badge.questionmark"
        }
    }

    private func color(for kind: ViolationKind) -> Color {
        switch kind {
        case .multiDomainCoexistence, .replicaDrift: return .red
        case .residencyPresenceMismatch: return .orange
        case .migrationCleanupPending, .orphanReplica: return .yellow
        }
    }
}
