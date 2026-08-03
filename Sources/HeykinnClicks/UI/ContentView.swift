import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview
    case library
    case duplicates
    case takeout
    case drives
    case migrations
    case violations
    case policies
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .library: return "Library"
        case .duplicates: return "Duplicates"
        case .drives: return "Drives & Health"
        case .violations: return "Violations"
        case .policies: return "Policies"
        case .migrations: return "Migrations"
        case .takeout: return "Google Takeout"
        case .activity: return "Activity"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .library: return "photo.on.rectangle"
        case .duplicates: return "square.on.square"
        case .drives: return "externaldrive.connected.to.line.below"
        case .violations: return "exclamationmark.triangle"
        case .policies: return "list.bullet.rectangle"
        case .migrations: return "arrow.left.arrow.right"
        case .takeout: return "shippingbox"
        case .activity: return "clock"
        }
    }
}

/// Sidebar grouping by what the user is trying to do, rather than one flat list
/// where "Policies" and "Library" look like the same kind of thing.
private struct SidebarGroup: Identifiable {
    let title: String?
    let sections: [SidebarSection]

    var id: String { title ?? "root" }

    static let all: [SidebarGroup] = [
        SidebarGroup(title: nil, sections: [.overview]),
        SidebarGroup(title: "Photos", sections: [.library, .duplicates, .takeout]),
        SidebarGroup(title: "Storage", sections: [.drives, .migrations]),
        SidebarGroup(title: "Housekeeping", sections: [.violations, .policies, .activity])
    ]
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selection: SidebarSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarGroup.all) { group in
                    Section {
                        ForEach(group.sections) { section in
                            Label {
                                Text(section.title)
                            } icon: {
                                Image(systemName: section.symbolName)
                            }
                            .badge(badge(for: section))
                            .tag(section)
                        }
                    } header: {
                        if let title = group.title {
                            Text(title)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch selection ?? .overview {
            case .overview: OverviewView(selection: $selection)
            case .library: LibraryView()
            case .duplicates: DuplicatesView()
            case .drives: DrivesView()
            case .violations: ViolationsView()
            case .policies: PoliciesView()
            case .migrations: MigrationsView()
            case .takeout: TakeoutView()
            case .activity: ActivityView()
            }
        }
        .sheet(item: $store.connectPrompt) { volume in
            DriveConnectPrompt(volume: volume)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private func badge(for section: SidebarSection) -> Int {
        switch section {
        case .violations: return store.violations.count
        case .duplicates: return store.duplicateGroups.count
        case .migrations: return store.migrationJobs.filter { $0.state.isActive }.count
        case .takeout: return store.takeoutArchives.filter { !$0.isImported }.count
        default: return 0
        }
    }
}
