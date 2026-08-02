import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var searchText = ""
    @State private var residencyFilter: ResidencyDomain?
    @State private var isImporterPresented = false

    private var filteredAssets: [Asset] {
        store.assets.filter { asset in
            // The movie half of a Live Photo belongs to its still, not to the
            // grid as a separate entry.
            if asset.isLivePhotoMotion { return false }
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
                if let protection = store.protectionStates[asset.id], protection != .notApplicable {
                    Image(systemName: protection.symbolName)
                        .font(.caption)
                        .foregroundStyle(protection.tint)
                        .help(protection.displayName)
                }
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
