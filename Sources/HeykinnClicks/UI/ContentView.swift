import SwiftUI
import AppKit

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview
    case library
    case duplicates
    case takeout
    case targets
    case migrations
    case violations
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .library: return "Library"
        case .duplicates: return "Duplicates"
        case .targets: return "Copies"
        case .violations: return "Violations"
        case .migrations: return "Migrations"
        case .takeout: return "Add photos"
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
        case .migrations: return "arrow.left.arrow.right"
        case .takeout: return "tray.and.arrow.down"
        case .activity: return "clock"
        }
    }

    /// Which question this page belongs under.
    ///
    /// Two sections — violations and migrations — are not tabs anywhere: they
    /// are answers to "is it safe" that are usually empty, and they render as
    /// sections of the safety page rather than as permanent destinations. They
    /// still have to *belong* somewhere, or the sidebar highlights Overview
    /// while showing one of them and the reader has no way back.
    var question: Question {
        Question.allCases.first { $0.pages.contains(self) }
            ?? Question.allCases.first { $0.carriedSections.contains(self) }
            ?? .overview
    }

    /// What this page's badge is counting, so "1" can say what it is one of.
    ///
    /// Kept to one or two words: the badge sits at the right-hand end of a
    /// sidebar row and takes its width from the row's text, so "3 duplicate
    /// sets" pushed "Every photo and video" into an ellipsis. The subtitle is
    /// what makes the row legible to somebody new; the badge is a nudge.
    func badgeNoun(count: Int) -> String {
        switch self {
        case .violations: return "to review"
        case .duplicates: return count == 1 ? "dupe set" : "dupe sets"
        case .migrations: return count == 1 ? "move" : "moves"
        case .takeout: return count == 1 ? "to import" : "to import"
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
/// and an export's health was split across Sources and the drives screen.
///
/// So the top level is the questions, and the mechanisms are pages inside the
/// question they answer. Nothing was deleted and no screen was merged: what
/// changed is that finding one no longer requires knowing what the app calls
/// it. The subtitle carries the plain wording, because "Is it safe?" is the
/// question and "Drives" is the answer's filing system.
enum Question: String, CaseIterable, Identifiable {
    case overview
    case have
    case from
    case safe

    var id: String { rawValue }

    /// Places, not questions.
    ///
    /// These were phrased as things the reader wants to know — "What I have",
    /// "Where it came from" — which casts them as somebody asking, once. The
    /// same person arrives wearing different hats: first to say where their
    /// photos are and get them in, later to keep an eye on what is arriving.
    /// A question-shaped name fits one of those and quietly excludes the
    /// other, and "Where it came from" is the past tense of a screen whose
    /// main job is adding things. A noun is a place you go back to; the
    /// subtitle carries the plain meaning, and names both jobs where there
    /// are two.
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .have: return "Photos"
        case .from: return "Add photos"
        case .safe: return "Keep safe"
        }
    }

    /// The sentence under the title. Someone who has never seen the app should
    /// be able to pick the right section from these alone.
    var subtitle: String {
        switch self {
        case .overview: return "The short answer"
        case .have: return "The whole archive"
        case .from: return "From a folder, Google, or Photos"
        // Short enough to survive a badge beside it. "Every place your
        // photos are kept" was truer and ran into an ellipsis, which tells the
        // reader nothing at all.
        case .safe: return "Where your copies are"
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
    ///
    /// "Is it safe" used to list five, and five tabs is the nine-item sidebar
    /// wearing a hat: the reader still had to know that a damaged copy lives
    /// under Violations and a half-finished move under Migrations. Both are
    /// answers to *this* question and both are usually empty, so they are
    /// sections on the safety page now, appearing only when there is something
    /// to say. What is left are the two that are genuinely their own subject:
    /// the rules, and the log.
    var pages: [SidebarSection] {
        switch self {
        case .overview: return [.overview]
        case .have: return [.library, .duplicates]
        case .from: return [.takeout]
        // Policies is gone as a destination. Storage groups are a section of
        // the copies page — "how many copies, and where" is the same subject as
        // "where are my copies", read one line apart — and the residency rules
        // that shared the screen are automation, which is what Settings is.
        case .safe: return [.targets, .activity]
        }
    }

    /// Everything whose count this question is answerable for, including the
    /// two that are sections of a page rather than pages of their own.
    ///
    /// Without this the sidebar sat silent while the safety page was carrying
    /// twenty-five damaged copies: the badge counted pages, violations was not
    /// a page any more, and so the one number the whole sidebar exists to
    /// surface was the one it could not see. Worst first.
    var carriedSections: [SidebarSection] {
        switch self {
        case .safe: return [.violations, .migrations] + pages
        default: return pages
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var commands: AppCommandBus
    @Environment(\.openSettings) private var openSettings

    /// The single source of truth, kept across launches.
    ///
    /// It was `@State`, so quitting mid-import and reopening put the reader
    /// back on Overview — the app forgot what they were doing every time, which
    /// is the one piece of state a window is expected to remember.
    @AppStorage("ui.lastViewedPage") private var storedPage = SidebarSection.overview.rawValue
    /// Where the reader was last inside each question, so coming back to one
    /// returns them to the page they were reading rather than to its first.
    /// In-session only: this is a convenience within a sitting, not a setting.
    @State private var lastPage: [Question: SidebarSection] = [:]

    /// The photo a grid has pushed to, owned here rather than inside each grid.
    ///
    /// Three screens open an asset — the Library, Duplicates and Violations —
    /// and each had its own `NavigationStack` with a path SwiftUI keeps. Inside
    /// a split view's detail column that path outlives the column's content: a
    /// photo pushed from the Library stayed on screen while the sidebar moved
    /// to Overview, so the two halves of the window disagreed and the only way
    /// back was the chevron the reader had already stopped looking at.
    ///
    /// Hoisted so there is one path and one place that clears it. A shared path
    /// is also the truthful shape — there is one detail column, so there is one
    /// thing pushed into it.
    @State private var detailPath: [UUID] = []

    private var page: SidebarSection {
        SidebarSection(rawValue: storedPage) ?? .overview
    }

    private var pageSelection: Binding<SidebarSection> {
        Binding(
            get: { page },
            set: { newPage in
                storedPage = newPage.rawValue
                lastPage[newPage.question] = newPage
                // Leaving a page closes what it had open. Every route into a
                // photo goes through here, including the menu bar's.
                detailPath.removeAll()
            }
        )
    }

    private var questionSelection: Binding<Question?> {
        Binding(
            get: { page.question },
            set: { question in
                guard let question else { return }
                pageSelection.wrappedValue = lastPage[question] ?? question.pages[0]
            }
        )
    }

    var body: some View {
        if let explanation = store.catalogRequiresNewerApp {
            // Above the lock check, because this one is true whether or not
            // anybody else has the archive open, and "quit the other copy"
            // would send somebody chasing a problem they do not have.
            //
            // Instead of the app, for the same reason as the lock: every screen
            // is drawn from state loaded into memory and written back as whole
            // rows, so a build that has never heard of a column would write it
            // away. Refusing to show the archive is refusing to damage it.
            ContentUnavailableView {
                Label("This archive needs a newer version", systemImage: "arrow.up.circle")
            } description: {
                Text("\(explanation)\n\nNothing is wrong with your archive and nothing has been changed. It was opened on a device running a newer version of the app — updating this copy will open it.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 520, minHeight: 340)
        } else if store.archiveIsHeldByAnotherInstance {
            // Instead of the app, not beside it. Both builds share one archive
            // on purpose, so the second one to open is looking at a catalog
            // somebody else is already writing to — and everything here is
            // drawn from state held in memory, so carrying on would mean
            // overwriting their work without ever having seen it.
            ContentUnavailableView {
                Label("This archive is already open", systemImage: "lock.circle")
            } description: {
                VStack(spacing: 14) {
                    Text("Another copy of Heykinn Clicks has it — usually the App Store version and this one at the same time. They share a single archive on purpose, so only one can be in it at once.\n\nQuit the other copy and reopen this one. Nothing is wrong with your archive and nothing has been changed.")
                        .fixedSize(horizontal: false, vertical: true)

                    // The other way out, for the person who wants both copies
                    // running: a second archive with nothing in it, so there is
                    // nothing to collide over. Offered here because this screen
                    // is where somebody meets the problem.
                    if TestArchiveMode.canRelaunch {
                        Button("Open a test archive instead") { TestArchiveMode.set(true) }
                            .buttonStyle(.borderedProminent)
                        Text("Starts this copy on an empty archive of its own, leaving your photos and the other copy alone. You can switch back at any time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(minWidth: 520, minHeight: 360)
        } else if let problem = AppInstallLocation.problem() {
            // Ahead of everything, because in this state nothing else the app
            // says about permissions is true. macOS refuses a translocated app
            // every grant there is, and the screens underneath would report
            // that as the user having declined.
            ContentUnavailableView {
                Label(problem.headline, systemImage: "arrow.down.app")
            } description: {
                Text(problem.explanation)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 520, minHeight: 340)
        } else if TestArchiveMode.isOn {
            // Loud, permanent, and above everything. This app's whole subject is
            // telling somebody the truth about where their photographs are, and
            // a test archive looks exactly like a real one that has lost
            // everything. Nobody may be one glance away from believing that.
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "testtube.2")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Test archive").font(.callout.weight(.semibold))
                        Text("Not your photos. Nothing here affects your real archive.")
                            .font(.caption)
                    }
                    Spacer(minLength: 12)
                    Button("Switch back to my archive") { TestArchiveMode.set(false) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.22))
                Divider()
                archiveContent
            }
        } else {
            archiveContent
        }
    }

    private var archiveContent: some View {
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
            // Wide enough for the subtitle *and* a badge beside it: at 230
            // the badge took its width off the subtitle, so the line that
            // exists to make the row legible was the line that got an
            // ellipsis.
            .navigationSplitViewColumnWidth(min: 240, ideal: 260)
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
        .sheet(item: $store.connectPrompt) { volume in
            DriveConnectPrompt(volume: volume)
        }
        .sheet(item: $store.takeoutRedirect) { redirect in
            TakeoutRedirectPrompt(redirect: redirect)
        }
        .sheet(item: $store.unmanagedSourceOffer) { offer in
            UnmanagedSourcePrompt(offer: offer)
        }
        .sheet(isPresented: $commands.isHelpPresented) {
            HelpView()
        }
        // The menu bar's requests, acted on here because this is where the
        // selection and the pickers live.
        .onChange(of: commands.requestedPage) { _, requested in
            guard let requested else { return }
            pageSelection.wrappedValue = requested
            commands.requestedPage = nil
        }
        .sheet(item: $store.pendingSourceSetup) { AddSourceSheet(setup: $0) }
        // Each picker on its own view rather than stacked with the sheets.
        //
        // Seven presentations were attached to this one view — four sheets and
        // two importers, with a sheet between the importers. On macOS they
        // compete, and "Choose a folder…" silently stopped opening anything:
        // the button set the flag, and nothing watched it any more. An empty
        // background gives each presentation a view of its own to hang from,
        // so adding the next one cannot quietly disable an existing one.
        .background {
            Color.clear.fileImporter(
                isPresented: $commands.isImportPickerPresented,
                allowedContentTypes: [.folder, .image, .movie],
                allowsMultipleSelection: true
            ) { result in
                // Asks before reading. Placement needs a destination, and
                // choosing one silently is the app deciding where somebody's
                // photos live.
                if case .success(let urls) = result { store.beginAddingSource(urls) }
            }
        }
        .background {
            Color.clear.fileImporter(
                isPresented: $commands.isExportSearchPickerPresented,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    store.scanForTakeout(rootURL: url, targetID: nil)
                }
            }
        }
        // Titled for what happened rather than for the app's embarrassment.
        // "Something went wrong" is the wording of a crash reporter: it tells
        // the reader nothing, and it frames a refused registration or an
        // unplugged drive — both of which are the app working correctly — as a
        // malfunction. The message underneath is often a whole explanation, so
        // it is worth being able to keep.
        .alert(
            "That didn’t finish",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            )
        ) {
            Button("Copy the details") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(store.lastError ?? "", forType: .string)
            }
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
                Picker("", selection: pageSelection) {
                    ForEach(pages) { candidate in
                        Text(label(for: candidate)).tag(candidate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Pages in \(page.question.title)")
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
                set: { if let destination = $0 { pageSelection.wrappedValue = destination } }
            ))
        case .library: LibraryView(path: $detailPath)
        case .duplicates: DuplicatesView(path: $detailPath)
        case .targets: DrivesView()
        case .violations: ViolationsView(path: $detailPath)
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
        let carried = question.carriedSections
            .map { (page: $0, count: badge(for: $0)) }
            .filter { $0.count > 0 }
        // The first page that has something, named — rather than a sum across
        // pages, which added violations to migrations and produced a number
        // ("33") that counts nothing anybody can name. Whatever else is
        // waiting is on the tab bar inside, with its own count.
        guard let leading = carried.first else { return nil }
        return "\(leading.count) \(leading.page.badgeNoun(count: leading.count))"
    }
}
