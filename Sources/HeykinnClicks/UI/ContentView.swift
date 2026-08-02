import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case library
    case duplicates
    case drives
    case violations
    case policies
    case migrations
    case takeout
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
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

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selection: SidebarSection? = .library

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label {
                    Text(section.title)
                } icon: {
                    Image(systemName: section.symbolName)
                }
                .badge(badge(for: section))
                .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch selection ?? .library {
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
