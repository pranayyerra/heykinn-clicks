import SwiftUI

/// What is wrong with the archive, grouped by what is wrong with it.
///
/// This was a flat list, one row per affected photo. Twenty-five damaged
/// copies meant twenty-five rows carrying the same heading and the same
/// sentence with a different filename in it — the reader scrolled past a wall
/// to learn one thing, and the only affordance was "Show asset", twenty-five
/// times. Grouping says the thing once, with the count, and opens on demand.
struct ViolationsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var expanded: Set<ViolationKind> = []

    private struct Group: Identifiable {
        let kind: ViolationKind
        let violations: [Violation]
        var id: ViolationKind { kind }
    }

    private var groups: [Group] {
        Dictionary(grouping: store.violations, by: \.kind)
            .map { Group(kind: $0.key, violations: $0.value) }
            .sorted { ($0.kind.severity, $0.violations.count) > ($1.kind.severity, $1.violations.count) }
    }

    var body: some View {
        NavigationStack {
            Group_ {
                if store.violations.isEmpty {
                    ContentUnavailableView(
                        "Nothing to review",
                        systemImage: "checkmark.seal",
                        description: Text("Every photo is in one place, and every copy matches what was imported.")
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("The app finds these and shows them; it never quietly fixes them, because every fix here moves or forgets somebody's photos.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(groups) { group in
                                groupCard(group)
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("Violations")
            .navigationDestination(for: UUID.self) { assetID in
                AssetDetailView(assetID: assetID)
            }
        }
    }

    private func groupCard(_ group: Group) -> some View {
        let isOpen = expanded.contains(group.kind)
        return CardBox(
            title: group.kind.displayName,
            systemImage: group.kind.symbolName
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Formatters.count(group.violations.count, "photo"))
                    .font(.title3)
                    .foregroundStyle(group.kind.tint)
                Text(group.kind.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    if isOpen { expanded.remove(group.kind) } else { expanded.insert(group.kind) }
                } label: {
                    Label(
                        isOpen ? "Hide the list" : "Show which photos",
                        systemImage: isOpen ? "chevron.down" : "chevron.right"
                    )
                    .font(.callout)
                }
                .buttonStyle(.link)

                if isOpen {
                    VStack(alignment: .leading, spacing: 4) {
                        // Capped: a group of twenty-five thousand is a fact
                        // about the archive, not a list anybody reads to the
                        // end of, and rendering it is the screen locking up.
                        ForEach(group.violations.prefix(50)) { violation in
                            row(violation)
                        }
                        if group.violations.count > 50 {
                            Text("…and \(Formatters.count(group.violations.count - 50, "more")).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 2)
                }
            }
        }
    }

    private func row(_ violation: Violation) -> some View {
        HStack(spacing: 8) {
            Text(violation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let assetID = violation.assetID, store.assetsByID[assetID] != nil {
                NavigationLink(value: assetID) {
                    Text("Open")
                        .font(.caption)
                }
            }
        }
    }
}

/// `Group` is taken by the nested type above; this keeps SwiftUI's own.
private typealias Group_ = SwiftUI.Group

extension ViolationKind {
    /// Worst first. A damaged copy is a photo at risk; a drive holding
    /// something it need not is housekeeping, and putting them in catalog
    /// order made those read as equally urgent.
    var severity: Int {
        switch self {
        case .replicaDrift: return 5
        case .multiDomainCoexistence: return 4
        case .residencyPresenceMismatch: return 3
        case .migrationCleanupPending: return 2
        case .orphanReplica: return 1
        }
    }

    var symbolName: String {
        switch self {
        case .multiDomainCoexistence: return "rectangle.on.rectangle"
        case .residencyPresenceMismatch: return "questionmark.folder"
        case .migrationCleanupPending: return "clock.badge.exclamationmark"
        case .replicaDrift: return "exclamationmark.triangle"
        case .orphanReplica: return "externaldrive.badge.questionmark"
        }
    }

    var tint: Color {
        switch self {
        case .multiDomainCoexistence, .replicaDrift: return .red
        case .residencyPresenceMismatch: return .orange
        case .migrationCleanupPending, .orphanReplica: return .yellow
        }
    }
}

/// The violations, inline on the safety page.
///
/// Not a link to a screen: "3 things to review" with an arrow makes the reader
/// navigate to find out whether it matters. The kinds and counts fit in the
/// space the link would have taken, and the full list is one click away for
/// the reader who wants it.
struct ViolationsSummary: View {
    @EnvironmentObject private var store: AppStore
    @State private var isPresented = false

    var body: some View {
        let byKind = Dictionary(grouping: store.violations, by: \.kind)
            .sorted { ($0.key.severity, $0.value.count) > ($1.key.severity, $1.value.count) }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(byKind, id: \.key) { kind, violations in
                HStack(spacing: 8) {
                    Image(systemName: kind.symbolName)
                        .foregroundStyle(kind.tint)
                        .frame(width: 18)
                    Text(kind.displayName)
                        .font(.callout)
                    Spacer()
                    Text(Formatters.count(violations.count, "photo"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Button("Look at these…") { isPresented = true }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                ViolationsView()
                    .frame(minWidth: 620, minHeight: 460)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isPresented = false }
                        }
                    }
            }
        }
    }
}
