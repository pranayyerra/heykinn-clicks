import SwiftUI

struct LibraryView: View {
    /// Owned by `ContentView`, so leaving this page closes the photo it had
    /// open. See `ContentView.detailPath`.
    @Binding var path: [UUID]
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

    /// Everything the grid needs to draw itself, worked out in one walk of the
    /// archive.
    ///
    /// Each figure here used to be its own computed property, and a computed
    /// property is recomputed at every mention: `filteredAssets` was mentioned
    /// four times per redraw and walked all 24,000 photographs each time.
    /// Typing a letter into the search field paid all of it on the main thread
    /// before a single character appeared.
    ///
    /// Gathered here, the archive is walked once and every figure below is read
    /// rather than recounted.
    private struct Shown {
        var matched: [Asset] = []
        var months: [(month: String, assets: [Asset], impossibleCount: Int)] = []
        /// How many photographs the archive holds regardless of what is on
        /// screen, so the empty state can say the rest are still there.
        var countedTotal = 0
    }

    private func currentlyShown() -> Shown {
        var shown = Shown()

        for asset in store.assets {
            // The movie half of a Live Photo belongs to its still, not to the
            // grid as a separate entry.
            if asset.isLivePhotoMotion { continue }
            shown.countedTotal += 1

            if holdingFilter == .notHeld, !asset.isIndexedOnly { continue }
            if let residencyFilter, asset.residency != residencyFilter { continue }
            if !searchText.isEmpty,
               !asset.originalFilename.localizedCaseInsensitiveContains(searchText) {
                continue
            }
            if let tagFilter, !(store.assetIDsByTag[tagFilter]?.contains(asset.id) ?? false) {
                continue
            }
            shown.matched.append(asset)
        }

        shown.months = Self.monthGroups(of: shown.matched)
        return shown
    }

    /// Timeline-friendly grouping by capture month (falling back to import date).
    ///
    /// Months that cannot exist — a camera whose clock was never set dates its
    /// files years ahead — sort to the top like any other. They are labelled
    /// rather than moved: the grouping follows the recorded date, and quietly
    /// filing a file somewhere other than where its own metadata puts it would
    /// be the same guess as rewriting the date.
    private static func monthGroups(
        of assets: [Asset]
    ) -> [(month: String, assets: [Asset], impossibleCount: Int)] {
        // Read once rather than twice per photograph. Worth about a tenth of
        // the grouping at 24,000 — measured, because the shape of it suggests
        // more: the date arithmetic itself is the expensive part, and hoisting
        // the calendar does not touch that.
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: assets) { asset -> Date in
            let date = asset.captureDate ?? asset.importDate
            let components = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: components) ?? date
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
        // Once, here, and read from everywhere below.
        let shown = currentlyShown()
        return NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    albumHeader(shown)
                    ForEach(shown.months, id: \.month) { group in
                        Section {
                            // Selection is off inside the grid. Every `Text`
                            // in the window became selectable, and here that
                            // is a caption under each of 24,639 thumbnails —
                            // enough hit-testing that the I-beam took a
                            // noticeable moment to appear anywhere on the
                            // screen. Nobody copies a filename out of a grid;
                            // the ones worth copying are on the photo's own
                            // page, which keeps it.
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                                ForEach(group.assets) { asset in
                                    gridItem(asset, showsResidency: !store.residencyIsUniform)
                                        .textSelection(.disabled)
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
                    if shown.matched.isEmpty {
                        emptyState(shown)
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
                if isSelecting { selectionBar(shown) }
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
    private func gridItem(_ asset: Asset, showsResidency: Bool) -> some View {
        if isSelecting {
            Button {
                toggle(asset.id)
            } label: {
                assetCell(asset, showsResidency: showsResidency)
                    .overlay(alignment: .topLeading) { selectionMark(for: asset.id) }
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: asset.id) {
                assetCell(asset, showsResidency: showsResidency)
            }
            .buttonStyle(.plain)
        }
    }

    /// What the album says about itself, when the grid is narrowed to one.
    ///
    /// Its date and its places were captured with everything else and shown
    /// nowhere. The places are the interesting part: Google recorded "Elm
    /// Park, Northgate" against an album years ago, and this is the only
    /// surviving record of it — no photo in the album carries it.
    @ViewBuilder
    private func albumHeader(_ shown: Shown) -> some View {
        if let tagFilter, tagFilter.kind == .album,
           let detail = store.albumDetails[tagFilter.value] {
            VStack(alignment: .leading, spacing: 4) {
                Text(detail.title)
                    .font(.title2)
                    .bold()
                Text(
                    [detail.date.map(Formatters.providerDateOnly.string(from:)),
                     Formatters.count(shown.matched.count, "photo")]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                if let description = detail.description {
                    Text(description)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !detail.places.isEmpty {
                    albumLine(
                        detail.places.map(Self.described).joined(separator: " · "),
                        icon: "mappin.and.ellipse"
                    )
                }
                ForEach(detail.journeys, id: \.self) { journey in
                    // A map rather than an arrow: the arrow is already doing the
                    // work between the two places, and leading with a second one
                    // reads as a three-stop trip whose first stop is missing.
                    albumLine(
                        "\(Self.described(journey.from)) → \(Self.described(journey.to))",
                        icon: "map"
                    )
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 4)
        }
    }

    private func albumLine(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "Elm Park, Northgate" — Google's own subtitle, kept when it has one.
    private static func described(_ place: AlbumDetail.Place) -> String {
        place.locality.map { "\(place.name), \($0)" } ?? place.name
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
    private func selectionBar(_ shown: Shown) -> some View {
        HStack(spacing: 12) {
            Text(selection.isEmpty
                 ? "Select photos to move them into a group"
                 : "\(Formatters.count(selection.count, "photo")) selected")
                .font(.callout)
            Spacer(minLength: 8)
            Button("Select all shown") {
                selection = Set(shown.matched.map(\.id))
            }
            .disabled(shown.matched.isEmpty)
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

    /// Whether the reader has narrowed the view themselves.
    private var isNarrowed: Bool {
        !searchText.isEmpty || residencyFilter != nil || holdingFilter != .everything
    }

    /// Two different nothings, and they want different sentences: an archive
    /// with no photos in it needs telling how to get some, and a filter that
    /// matched none needs telling that the photos are still there. "No assets"
    /// told neither, in the app's own word for a photograph.
    @ViewBuilder
    private func emptyState(_ shown: Shown) -> some View {
        if isNarrowed {
            ContentUnavailableView(
                "Nothing matches",
                systemImage: "magnifyingglass",
                description: Text("The archive still holds "
                                  + "\(Formatters.count(shown.countedTotal, "photo")). "
                                  + "Clear the search or the filters to see them.")
            )
        } else {
            ContentUnavailableView(
                "No photos yet",
                systemImage: "photo.on.rectangle",
                description: Text("Add a folder with ⌘I, or open Add photos to connect your "
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

    private func assetCell(_ asset: Asset, showsResidency: Bool) -> some View {
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
                if showsResidency {
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
