import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var searchText = ""
    @State private var residencyFilter: ResidencyDomain?
    @State private var holdingFilter: HoldingFilter = .everything
    /// An album or a person, when the grid is narrowed to one.
    ///
    /// A filter rather than a screen of its own: the photos in an album are the
    /// same photos, shown the same way. A second grid would duplicate the
    /// thumbnails, the hover previews, the protection marks and the selection
    /// mode, and give them somewhere to drift apart from these.
    @State private var tagFilter: AppStore.TagKey?
    /// Selecting is a mode rather than a modifier chord. A thumbnail's ordinary
    /// click opens the photo, and quietly turning that into "select" the moment
    /// a key is held is how somebody loses their place in a 24,000-photo scroll
    /// without knowing what they pressed.
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var isMoving = false
    /// Importing is one code path with one file picker, owned by the window.
    /// This screen and the File menu were each carrying their own `fileImporter`
    /// with the same content types and the same call underneath — two ways to
    /// do one thing, which is two places for it to drift.
    @EnvironmentObject private var commands: AppCommandBus

    /// Whether the archive holds a photograph or merely knows it exists.
    ///
    /// One unified Library is the right picture — the archive and the Photos
    /// library are one collection — but it hid the difference that decides what
    /// still needs doing: a photo indexed from Photos is one this app protects
    /// with nothing at all.
    private enum HoldingFilter: Hashable, CaseIterable {
        case everything
        /// Indexed from a provider's library, bytes never read.
        case notHeld

        var label: String {
            switch self {
            case .everything: return "Everything"
            case .notHeld: return "In Photos, no copy here"
            }
        }
    }

    private var filteredAssets: [Asset] {
        store.assets.filter { asset in
            // The movie half of a Live Photo belongs to its still, not to the
            // grid as a separate entry.
            if asset.isLivePhotoMotion { return false }
            if holdingFilter == .notHeld, !asset.isIndexedOnly { return false }
            if let residencyFilter, asset.residency != residencyFilter { return false }
            if !searchText.isEmpty,
               !asset.originalFilename.localizedCaseInsensitiveContains(searchText) {
                return false
            }
            if let tagFilter, !(store.assetIDsByTag[tagFilter]?.contains(asset.id) ?? false) {
                return false
            }
            return true
        }
    }

    /// Timeline-friendly grouping by capture month (falling back to import date).
    ///
    /// Months that cannot exist — a camera whose clock was never set dates its
    /// files years ahead — sort to the top like any other. They are labelled
    /// rather than moved: the grouping follows the recorded date, and quietly
    /// filing a file somewhere other than where its own metadata puts it would
    /// be the same guess as rewriting the date.
    private var monthGroups: [(month: String, assets: [Asset], impossibleCount: Int)] {
        let grouped = Dictionary(grouping: filteredAssets) { asset -> Date in
            let date = asset.captureDate ?? asset.importDate
            let components = Calendar.current.dateComponents([.year, .month], from: date)
            return Calendar.current.date(from: components) ?? date
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { month, assets in
                (
                    Formatters.monthYear.string(from: month),
                    assets,
                    assets.count { $0.impossibleCaptureDate != nil }
                )
            }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    ForEach(monthGroups, id: \.month) { group in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                                ForEach(group.assets) { asset in
                                    gridItem(asset)
                                }
                            }
                            .padding(.horizontal)
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.month)
                                    .font(.headline)
                                // Said on the section, not on every cell: an
                                // unset camera clock takes a whole month with
                                // it, and a badge repeated down every
                                // thumbnail would compete with the protection
                                // marks, which are about the archive's safety
                                // rather than about a wrong date.
                                if group.impossibleCount > 0 {
                                    Label(
                                        impossibleNote(count: group.impossibleCount, of: group.assets.count),
                                        systemImage: ImpossibleCaptureDate.symbolName
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.bar)
                        }
                    }
                    if filteredAssets.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Library")
            .navigationDestination(for: UUID.self) { assetID in
                AssetDetailView(assetID: assetID)
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting { selectionBar }
            }
            .searchable(text: $searchText, prompt: "Filename")
            .sheet(isPresented: $isMoving) {
                MoveToStorageGroupSheet(assetIDs: Array(selection)) { moved in
                    if moved > 0 {
                        selection = []
                        isSelecting = false
                    }
                }
            }
            .toolbar {
                ToolbarItem {
                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting { selection = [] }
                    }
                }
                ToolbarItem {
                    tagPicker
                }
                ToolbarItem {
                    Picker("Residency", selection: $residencyFilter) {
                        Text("All domains").tag(ResidencyDomain?.none)
                        ForEach(ResidencyDomain.allCases) { domain in
                            Text(domain.displayName).tag(ResidencyDomain?.some(domain))
                        }
                    }
                    .pickerStyle(.menu)
                }
                // Only offered once there is something to separate. A filter
                // that always reads "Everything" is a control that has never
                // had anything to say.
                if store.assets.contains(where: \.isIndexedOnly) {
                    ToolbarItem {
                        Picker("Holdings", selection: $holdingFilter) {
                            ForEach(HoldingFilter.allCases, id: \.self) { filter in
                                Text(filter.label).tag(filter)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                ToolbarItem {
                    Button {
                        commands.isImportPickerPresented = true
                    } label: {
                        if store.isImporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Add Photos…", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(store.isImporting)
                    .help(store.isImporting ? "Reading photos in…" : "Add photos from a folder (⌘I)")
                }
            }
        }
    }

    /// How many photographs the archive holds regardless of what is on screen.
    /// Extracted from the grid: as an inline `if` inside `LazyVGrid` inside
    /// `Section` inside `LazyVStack`, the type-checker gave up on it.
    @ViewBuilder
    private func gridItem(_ asset: Asset) -> some View {
        if isSelecting {
            Button {
                toggle(asset.id)
            } label: {
                assetCell(asset)
                    .overlay(alignment: .topLeading) { selectionMark(for: asset.id) }
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: asset.id) {
                assetCell(asset)
            }
            .buttonStyle(.plain)
        }
    }

    /// Albums and people Google recorded, as one more way to narrow the grid.
    ///
    /// Empty until an export has been read and its descriptions worked out, so
    /// it hides itself rather than offering a menu with nothing in it.
    @ViewBuilder
    private var tagPicker: some View {
        let albums = store.tagValues(ofKind: .album)
        let people = store.tagValues(ofKind: .person)
        if !albums.isEmpty || !people.isEmpty {
            Picker("Album or person", selection: $tagFilter) {
                Text("Everything").tag(AppStore.TagKey?.none)
                if !albums.isEmpty {
                    Section("Albums") {
                        ForEach(albums, id: \.value) { album in
                            Text("\(album.value) (\(album.count))")
                                .tag(AppStore.TagKey?.some(
                                    AppStore.TagKey(kind: .album, value: album.value)
                                ))
                        }
                    }
                }
                if !people.isEmpty {
                    Section("People") {
                        ForEach(people, id: \.value) { person in
                            Text("\(person.value) (\(person.count))")
                                .tag(AppStore.TagKey?.some(
                                    AppStore.TagKey(kind: .person, value: person.value)
                                ))
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ assetID: UUID) {
        if selection.contains(assetID) { selection.remove(assetID) } else { selection.insert(assetID) }
    }

    @ViewBuilder
    private func selectionMark(for assetID: UUID) -> some View {
        let chosen = selection.contains(assetID)
        Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(chosen ? Color.white : Color.white.opacity(0.9),
                             chosen ? Color.accentColor : Color.black.opacity(0.25))
            .padding(6)
    }

    /// What is selected and the one thing worth doing with it.
    ///
    /// Kept to moving photos between groups: that is the action the storage
    /// model needs and could not offer, and a bar that grows a dozen verbs is
    /// how a destructive one ends up next to a harmless one.
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text(selection.isEmpty
                 ? "Select photos to move them into a group"
                 : "\(Formatters.count(selection.count, "photo")) selected")
                .font(.callout)
            Spacer(minLength: 8)
            Button("Select all shown") {
                selection = Set(filteredAssets.map(\.id))
            }
            .disabled(filteredAssets.isEmpty)
            Button("Clear") { selection = [] }
                .disabled(selection.isEmpty)
            Button("Move to group…") { isMoving = true }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var countedAssetTotal: Int {
        store.assets.count { !$0.isLivePhotoMotion }
    }

    /// Whether the reader has narrowed the view themselves.
    private var isNarrowed: Bool {
        !searchText.isEmpty || residencyFilter != nil || holdingFilter != .everything
    }

    /// Two different nothings, and they want different sentences: an archive
    /// with no photos in it needs telling how to get some, and a filter that
    /// matched none needs telling that the photos are still there. "No assets"
    /// told neither, in the app's own word for a photograph.
    @ViewBuilder
    private var emptyState: some View {
        if isNarrowed {
            ContentUnavailableView(
                "Nothing matches",
                systemImage: "magnifyingglass",
                description: Text("The archive still holds "
                                  + "\(Formatters.count(countedAssetTotal, "photo")). "
                                  + "Clear the search or the filters to see them.")
            )
        } else {
            ContentUnavailableView(
                "No photos yet",
                systemImage: "photo.on.rectangle",
                description: Text("Add a folder with ⌘I, or open Sources to connect your "
                                  + "Photos library or a Google download.")
            )
        }
    }

    /// A month that has not happened yet needs its position explained, not
    /// defended: one line saying what the files claim and that nothing was
    /// done about it.
    private func impossibleNote(count: Int, of total: Int) -> String {
        let subject = count == total
            ? "These files date themselves"
            : "\(count) of these files date themselves"
        return "\(subject) after the day this archive imported them — usually a camera "
            + "clock that was never set. Shown where the files claim, unchanged."
    }

    /// True when every photo in the archive lives in the same domain, which is
    /// the normal state and the one where the badge is pure repetition.
    private var residencyIsUniform: Bool {
        var seen: ResidencyDomain?
        for asset in store.assets {
            if let seen, seen != asset.residency { return false }
            seen = asset.residency
        }
        return true
    }

    private func assetCell(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AssetThumbnailView(asset: asset)
                .frame(height: 120)
            Text(asset.originalFilename)
                .font(.caption)
                .lineLimit(1)
            HStack(spacing: 4) {
                // Only where it says something. On an archive that is entirely
                // Local — which is every archive until a cloud is involved —
                // this drew the same badge on all 21,000 tiles, so the one
                // place the badge matters, a photo that is somewhere else, had
                // nothing to stand out from.
                if !residencyIsUniform {
                    ResidencyBadge(domain: asset.residency)
                }
                // The archive can see this photograph and holds nothing of it.
                // Said in the same words the map uses for a place holding no
                // copy, because it is the same fact about a different subject.
                if asset.isIndexedOnly {
                    Image(systemName: "photo.badge.arrow.down")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("In the Photos library · the archive holds no copy here yet")
                        .accessibilityLabel("In the Photos library. The archive holds no copy here yet.")
                }
                // Only assets that fail the policy are marked. A badge on every
                // cell is a field of icons the eye has to decode one by one;
                // the useful signal is which few are not safe.
                if let protection = store.protectionStates[asset.id],
                   case let verdict = protection.verdict,
                   verdict != .notLocal, !verdict.isSatisfied {
                    Image(systemName: verdict.symbolName)
                        .font(.caption)
                        .foregroundStyle(verdict.tint)
                        .help(verdict.displayName(copies: store.desiredCopies(forAsset: asset.id)))
                        .accessibilityLabel(verdict.displayName(copies: store.desiredCopies(forAsset: asset.id)))
                }
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
