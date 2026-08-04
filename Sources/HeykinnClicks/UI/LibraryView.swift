import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var searchText = ""
    @State private var residencyFilter: ResidencyDomain?
    @State private var holdingFilter: HoldingFilter = .everything
    @State private var isImporterPresented = false

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
            return true
        }
    }

    /// Timeline-friendly grouping by capture month (falling back to import date).
    private var monthGroups: [(month: String, assets: [Asset])] {
        let grouped = Dictionary(grouping: filteredAssets) { asset -> Date in
            let date = asset.captureDate ?? asset.importDate
            let components = Calendar.current.dateComponents([.year, .month], from: date)
            return Calendar.current.date(from: components) ?? date
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { (Formatters.monthYear.string(from: $0.key), $0.value) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    ForEach(monthGroups, id: \.month) { group in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                                ForEach(group.assets) { asset in
                                    NavigationLink(value: asset.id) {
                                        assetCell(asset)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        } header: {
                            Text(group.month)
                                .font(.headline)
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.bar)
                        }
                    }
                    if filteredAssets.isEmpty {
                        ContentUnavailableView(
                            "No assets",
                            systemImage: "photo.on.rectangle",
                            description: Text("Import a folder to get started.")
                        )
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
            .searchable(text: $searchText, prompt: "Filename")
            .toolbar {
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
                        isImporterPresented = true
                    } label: {
                        if store.isImporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Import…", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(store.isImporting)
                }
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.folder, .image, .movie],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    store.importFolders(urls)
                }
            }
        }
    }

    private func assetCell(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AssetThumbnailView(asset: asset)
                .frame(height: 120)
            Text(asset.originalFilename)
                .font(.caption)
                .lineLimit(1)
            HStack(spacing: 4) {
                ResidencyBadge(domain: asset.residency)
                // The archive can see this photograph and holds nothing of it.
                // Said in the same words the map uses for a place holding no
                // copy, because it is the same fact about a different subject.
                if asset.isIndexedOnly {
                    Image(systemName: "photo.badge.arrow.down")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("In the Photos library · the archive holds no copy here yet")
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
                        .help(verdict.displayName(policy: store.redundancyPolicy))
                }
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
