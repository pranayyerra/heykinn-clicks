import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview
    case library
    case duplicates
    case takeout
    case targets
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
        case .targets: return "Storage & Health"
        case .violations: return "Violations"
        case .policies: return "Policies"
        case .migrations: return "Migrations"
        case .takeout: return "Sources"
        case .activity: return "Activity"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .library: return "photo.on.rectangle"
        case .duplicates: return "square.on.square"
        case .targets: return "externaldrive.connected.to.line.below"
        case .violations: return "exclamationmark.triangle"
        case .policies: return "list.bullet.rectangle"
        case .migrations: return "arrow.left.arrow.right"
        case .takeout: return "tray.and.arrow.down"
        case .activity: return "clock"
        }
    }

    var question: Question {
        Question.allCases.first { $0.pages.contains(self) } ?? .overview
    }

    /// What this page's badge is counting, so "1" can say what it is one of.
    func badgeNoun(count: Int) -> String {
        switch self {
        case .violations: return count == 1 ? "to review" : "to review"
        case .duplicates: return count == 1 ? "duplicate set" : "duplicate sets"
        case .migrations: return count == 1 ? "move running" : "moves running"
        case .takeout: return count == 1 ? "file to import" : "files to import"
        default: return ""
        }
    }
}

/// The sidebar, as the three things somebody actually wants to know.
///
/// Nine sections in four groups asked the reader to hold the app's own model
/// in their head to find anything: "Violations" and "Migrations" are the names
/// of mechanisms, not of questions, and the same fact turned up under several
/// of them — a lost copy appeared on Overview, in Violations, and in Activity,
/// and an export's health was split across Sources and Storage & Health.
///
/// So the top level is the questions, and the mechanisms are pages inside the
/// question they answer. Nothing was deleted and no screen was merged: what
/// changed is that finding one no longer requires knowing what the app calls
/// it. The subtitle carries the plain wording, because "Is it safe?" is the
/// question and "Storage & Health" is the answer's filing system.
enum Question: String, CaseIterable, Identifiable {
    case overview
    case have
    case from
    case safe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .have: return "What I have"
        case .from: return "Where it came from"
        case .safe: return "Is it safe"
        }
    }

    /// The sentence under the title. Someone who has never seen the app should
    /// be able to pick the right section from these alone.
    var subtitle: String {
        switch self {
        case .overview: return "The short answer"
        case .have: return "Every photo and video"
        case .from: return "Places photos come in from"
        case .safe: return "Copies, drives and checks"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .have: return "photo.on.rectangle"
        case .from: return "tray.and.arrow.down"
        case .safe: return "checkmark.shield"
        }
    }

    /// The screens that answer this question, in the order they are offered.
    /// The first is what opens when the question is picked.
    var pages: [SidebarSection] {
        switch self {
        case .overview: return [.overview]
        case .have: return [.library, .duplicates]
        case .from: return [.takeout]
        case .safe: return [.targets, .violations, .migrations, .policies, .activity]
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings

    /// The single source of truth. The sidebar shows which question this page
    /// belongs to; picking a question moves to a page inside it.
    @State private var page: SidebarSection = .overview
    /// Where the reader was last inside each question, so coming back to one
    /// returns them to the page they were reading rather than to its first.
    @State private var lastPage: [Question: SidebarSection] = [:]

    private var questionSelection: Binding<Question?> {
        Binding(
            get: { page.question },
            set: { question in
                guard let question else { return }
                page = lastPage[question] ?? question.pages[0]
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: questionSelection) {
                ForEach(Question.allCases) { question in
                    // Label, not a VStack of Text: a sidebar row's selection
                    // tint and its enabled appearance come from the Label's
                    // title/icon slots, and building the row by hand out of
                    // Text left every unselected row rendering like a disabled
                    // control — the whole sidebar read as greyed out.
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(question.title)
                            Text(question.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    } icon: {
                        Image(systemName: question.symbolName)
                    }
                    .badge(badgeText(for: question))
                    .tag(question)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
            // Settings stays a ⌘, window — this is just a door to it where the
            // pointer already lives, pinned under the sidebar rather than
            // scrolling with it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        openSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Preferences (⌘,)")
                }
                .background(.bar)
            }
        } detail: {
            questionDetail
        }
        .onChange(of: page) { _, newPage in
            lastPage[newPage.question] = newPage
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

    /// The question's pages, with a switcher above them when there is more than
    /// one. A question answered by a single screen shows that screen and no
    /// chrome — a picker with one option is furniture.
    @ViewBuilder
    private var questionDetail: some View {
        let pages = page.question.pages
        VStack(spacing: 0) {
            if pages.count > 1 {
                Picker("", selection: $page) {
                    ForEach(pages) { candidate in
                        Text(label(for: candidate)).tag(candidate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            detail(for: page)
        }
    }

    /// A page's own count, carried onto its tab so a switcher does not hide
    /// the thing the reader came to find.
    private func label(for section: SidebarSection) -> String {
        let count = badge(for: section)
        return count > 0 ? "\(section.title) (\(count))" : section.title
    }

    @ViewBuilder
    private func detail(for section: SidebarSection) -> some View {
        switch section {
        // Overview's tiles are shortcuts into other questions' pages, so its
        // binding is the same `page` the sidebar derives from: tapping a tile
        // moves the sidebar too, rather than leaving the two disagreeing.
        case .overview:
            OverviewView(selection: Binding(
                get: { page },
                set: { if let destination = $0 { page = destination } }
            ))
        case .library: LibraryView()
        case .duplicates: DuplicatesView()
        case .targets: DrivesView()
        case .violations: ViolationsView()
        case .policies: PoliciesView()
        case .migrations: MigrationsView()
        case .takeout: SourcesView()
        case .activity: ActivityView()
        }
    }

    private func badge(for section: SidebarSection) -> Int {
        switch section {
        case .violations: return store.violations.count
        case .duplicates: return store.duplicateGroups.count
        case .migrations: return store.migrationJobs.filter { $0.state.isActive }.count
        case .takeout: return TakeoutExportSet.partsAwaitingImport(in: store.takeoutArchives)
        default: return 0
        }
    }

    /// A question carries what its pages are carrying. Something needing
    /// attention two screens down is still something needing attention, and
    /// burying it under a question the reader has not opened is how a nine-item
    /// sidebar hid things in the first place.
    ///
    /// Named, not just counted. A bare "1" against "Is it safe" is a worrying
    /// number with no subject — the reader has to open the question to find out
    /// what the app is worried about, which is the work the badge was supposed
    /// to save them. One item says what it is; several say how many of what.
    private func badgeText(for question: Question) -> String? {
        let carried = question.pages
            .map { (page: $0, count: badge(for: $0)) }
            .filter { $0.count > 0 }
        guard !carried.isEmpty else { return nil }
        if carried.count == 1, let only = carried.first {
            return "\(only.count) \(only.page.badgeNoun(count: only.count))"
        }
        return carried.reduce(0) { $0 + $1.count }.formatted()
    }
}
