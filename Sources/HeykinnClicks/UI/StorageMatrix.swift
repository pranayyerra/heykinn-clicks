import SwiftUI

/// One place a copy of the archive lives, or could.
///
/// Covers both a registered device and a slot that is not one yet, because
/// "nothing is here" is as much of an answer as "everything is here" — a place
/// left out cannot be noticed as missing.
struct ArchivePlace: Identifiable {
    enum State: Equatable {
        /// Registered and holding every photo the archive has.
        case complete
        /// Registered, still filling — or holding damaged copies.
        case filling(photosHeld: Int, photosExpected: Int)
        case damaged(count: Int)
        /// Not a target yet. Drawn as an empty column rather than hidden, so a
        /// place that holds nothing is visibly a place that holds nothing.
        case empty
    }

    let id: UUID
    var name: String
    var symbol: String
    var state: State
    var isReachable: Bool
    var detail: String
    /// What it actually holds, and how much of that has been proven.
    var heldPhotos: Int = 0
    var heldBytes: Int64 = 0
    var neverCheckedPhotos: Int = 0
    /// Photos this place is the only holder of — what its failure would cost.
    var soleCustodyPhotos: Int = 0
    /// Nil for places that are not targets yet.
    var target: ReplicationTarget?

    var holdsACopy: Bool {
        switch state {
        case .empty: return false
        case .complete, .filling, .damaged: return true
        }
    }
}

/// The whole storage picture: groups down the side, places across the top.
///
/// This replaced two stacked lists — everywhere a copy lives, and how many
/// copies each group keeps — which were never two subjects. They are one table
/// read in two directions. **Across a row** is a group's rule and whether it is
/// met; **down a column** is what a device holds. Splitting them meant the
/// crossing fact, *which group is on which device*, lived in neither and had to
/// be opened for: on a real archive you could not see that SampleBooks skips My
/// Passport for this Mac without expanding a row and reading a list.
///
/// The orientation is not arbitrary. Rows grow — a group is made per import, so
/// they accumulate for as long as the archive does. Columns do not; almost
/// nobody has more than a handful of drives. Putting the unbounded axis
/// vertically is what lets this still work after ten years of imports, when the
/// same information as a list of eighty groups would not.
///
/// Degenerate shapes are handled by not drawing a table at all: one group on one
/// device is a sentence, and a 1×1 grid saying it is worse than the sentence.
struct StorageMatrix: View {
    @EnvironmentObject private var store: AppStore

    var places: [ArchivePlace]
    /// The archive's own photo total, so the corner can state what the columns
    /// are shares of.
    var archivePhotoCount: Int
    var onActivateEmpty: (ArchivePlace) -> Void
    var onForget: (ReplicationTarget) -> Void

    /// What is open below the grid. One selection, not two, because a group and
    /// a device are alternative ways into the same table and opening both would
    /// put two panels under one grid with no way to say which cell either came
    /// from.
    private enum Opened: Equatable {
        case group(UUID)
        case place(UUID)
    }
    @State private var opened: Opened?

    @State private var editing: StorageGroup?
    @State private var renaming: StorageGroup?
    @State private var renameText = ""
    @State private var deleting: StorageGroup?
    @State private var placingStranded = false

    private var groups: [StorageGroup] {
        store.storageGroups.sorted { counts[$0.id] ?? 0 > counts[$1.id] ?? 0 }
    }
    private var counts: [UUID: Int] { store.photoCountByStorageGroup }

    var body: some View {
        CardBox(
            title: "How many copies, and where",
            systemImage: "square.stack.3d.up",
            help: "Every photo is in exactly one group, and a group says how many copies to keep. Read across a row to see where that group's photos are; read down a column to see what one device holds. A gap in a row is a device that group does not use."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if groups.isEmpty {
                    Text("No groups yet. One is made for you each time you add photos.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    grid
                    legend
                }
                if let opened { expansion(opened) }
                footerControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { EditStorageGroupSheet(group: $0) }
        .sheet(isPresented: $placingStranded) {
            MoveToStorageGroupSheet(assetIDs: store.ungroupedAssetIDs)
        }
        .alert("Rename group", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let renaming { store.renameStorageGroup(renaming.id, to: renameText) }
                renaming = nil
            }
        }
        .sheet(item: $deleting) { group in
            RemoveStorageGroupSheet(group: group, photoCount: counts[group.id] ?? 0)
        }
    }

    // MARK: - The table

    private var grid: some View {
        // Horizontally scrollable rather than compressed: a cell narrower than
        // its number is a cell that cannot be read, and there is no useful
        // abbreviation of "21,117".
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(places) { columnHeader($0) }
                }
                ForEach(groups) { group in
                    GridRow {
                        rowHeader(group)
                        ForEach(places) { place in
                            cell(group: group, place: place)
                        }
                    }
                }
                Divider().gridCellColumns(places.count + 1)
                GridRow {
                    Text(archivePhotoCount == 1
                         ? "1 photo in the archive"
                         : "\(archivePhotoCount.formatted()) photos in the archive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: rowHeaderWidth, alignment: .leading)
                    ForEach(places) { columnFooter($0) }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private let rowHeaderWidth: CGFloat = 244
    private let cellWidth: CGFloat = 128

    // MARK: - Headers

    /// A device: its name, whether it is plugged in, and a way into its card.
    @ViewBuilder
    private func columnHeader(_ place: ArchivePlace) -> some View {
        let isOpen = opened == .place(place.id)
        Button {
            if let target = place.target {
                withAnimation(.easeInOut(duration: 0.18)) {
                    opened = isOpen ? nil : .place(target.id)
                }
            } else {
                onActivateEmpty(place)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: place.symbol)
                        .font(.caption)
                        .foregroundStyle(place.holdsACopy ? Color.green : Color.secondary)
                    // Tail, not middle. Middle truncation is right when the
                    // distinguishing part of a name is at the end, which is
                    // true of paths and false of device names: it turned
                    // "Studio MacBook Pro" into "Prana…ook Pro", which is
                    // harder to read than the front of the name alone.
                    Text(place.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if place.target != nil {
                        // A dot rather than the word: every column repeating
                        // "connected" is a lot of ink for a fact that is
                        // binary. The tooltip keeps the words.
                        Circle()
                            .fill(place.isReachable ? Color.green : Color.secondary.opacity(0.45))
                            .frame(width: 6, height: 6)
                    }
                }
                Text(place.target == nil ? "not set up yet"
                     : place.isReachable ? "connected" : "away")
                    .font(.system(size: 9))
                    .foregroundStyle(place.target == nil ? Color.accentColor
                                     : place.isReachable ? Color.green : Color.secondary)
            }
            .frame(width: cellWidth, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                if isOpen {
                    RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12))
                }
            }
        }
        .buttonStyle(.plain)
        .help(place.target == nil
              ? "Not holding any copies. Click to set it up."
              : place.isReachable
                ? "Connected. Click for capacity, last sync and checks."
                : "Not connected — it still holds everything it held. Click for details.")
    }

    /// A group: what it is, how big, and whether its rule is being met.
    @ViewBuilder
    private func rowHeader(_ group: StorageGroup) -> some View {
        let isOpen = opened == .group(group.id)
        let short = store.photosShortByGroup[group.id] ?? 0
        HStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    opened = isOpen ? nil : .group(group.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.label)
                            .font(.callout.weight(isOpen ? .semibold : .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(rowSubtitle(group, short: short))
                            .font(.caption2)
                            .foregroundStyle(short > 0 || !group.isSatisfiable ? Color.orange : .secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                // Explicit, not inherited from the row's frame. Without it the
                // button is laid out at the width its label *wants*, which for
                // a long group name is wider than the column — the row then
                // overflows, is clipped back to size, and the clickable area
                // ends up somewhere other than where the words are. It looked
                // like one dead row: "Recovered import (Google Takeout)" was
                // the only name long enough to trigger it, so the two short
                // ones opened and the top row ignored every click.
                .frame(width: rowHeaderWidth - 30, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("Change copies and devices…") { editing = group }
                Button("Rename…") {
                    renameText = group.label
                    renaming = group
                }
                Button("Remove…", role: .destructive) { deleting = group }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(width: rowHeaderWidth, alignment: .leading)
        .padding(.vertical, 3)
    }

    /// What the group asks for, and whether it has it. The rule and the
    /// observation on one line, because a copy count is what was requested and
    /// not necessarily what exists.
    private func rowSubtitle(_ group: StorageGroup, short: Int) -> String {
        let held = counts[group.id] ?? 0
        let size = held == 1 ? "1 photo" : "\(held.formatted()) photos"
        if !group.isSatisfiable {
            return "\(size) · asks for more copies than it names devices"
        }
        if short > 0 {
            return "\(size) · \(short.formatted()) short of \(Formatters.copies(group.desiredCopies))"
        }
        return "\(size) · \(Formatters.copies(group.desiredCopies))"
    }

    /// What a device holds in total, and what losing it would cost.
    ///
    /// The second line is the only thing on this screen that answers the
    /// question people actually arrive with. Held counts cannot: a device with
    /// 21,389 of 21,401 photos sounds indispensable and is expendable, and one
    /// with 12 sounds trivial and is a catastrophe if those 12 are nowhere
    /// else. Only sole custody separates them.
    @ViewBuilder
    private func columnFooter(_ place: ArchivePlace) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if place.target == nil {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(place.heldPhotos == 1 ? "1 held" : "\(place.heldPhotos.formatted()) held")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                if place.soleCustodyPhotos > 0 {
                    Label(
                        place.soleCustodyPhotos == 1
                            ? "1 only here" : "\(place.soleCustodyPhotos.formatted()) only here",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("These photos are on no other device. Losing this one loses them.")
                } else if place.heldPhotos > 0 {
                    Label("nothing only here", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                        .help("Every photo on this device is on another one too. Losing it would lose nothing.")
                }
            }
        }
        .frame(width: cellWidth, alignment: .leading)
        .padding(.horizontal, 6)
    }

    // MARK: - Cells

    @ViewBuilder
    private func cell(group: StorageGroup, place: ArchivePlace) -> some View {
        let entry = place.target.flatMap { store.cell(group: group.id, place: $0.id) }
        let named = place.target.map { group.destinationTargetIDs.contains($0.id) } ?? false
        let shape = RoundedRectangle(cornerRadius: 6)

        Group {
            if let entry, !entry.isEmpty {
                let tint = cellTint(entry)
                VStack(alignment: .leading, spacing: 3) {
                    Text(cellNumber(entry))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(tint)
                    // A bar rather than a second number: the cell says how many
                    // and the bar says how much of the group that is, which is
                    // the comparison the eye makes across a row anyway.
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(tint.opacity(0.18))
                            Capsule()
                                .fill(tint)
                                .frame(width: proxy.size.width * shareOfGroup(entry, group: group))
                        }
                    }
                    .frame(height: 3)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(width: cellWidth, alignment: .leading)
                .background(tint.opacity(0.1), in: shape)
            } else {
                // Named but holding nothing is not the same as never asked.
                // Both are blank; only one of them is waiting for something.
                Text(named ? "nothing yet" : "—")
                    .font(.caption2)
                    .foregroundStyle(named ? Color.orange : Color.secondary.opacity(0.5))
                    .frame(width: cellWidth, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background {
                        shape.strokeBorder(
                            Color.secondary.opacity(named ? 0.3 : 0.15),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                    }
            }
        }
        .help(cellExplanation(group: group, place: place, entry: entry, named: named))
    }

    private func cellTint(_ entry: AppStore.GroupPlaceCell) -> Color {
        if entry.damaged > 0 { return .red }
        if entry.waiting > 0 { return .orange }
        return .green
    }

    private func cellNumber(_ entry: AppStore.GroupPlaceCell) -> String {
        if entry.photos == 0 && entry.waiting > 0 { return "on its way" }
        return entry.photos.formatted()
    }

    private func shareOfGroup(_ entry: AppStore.GroupPlaceCell, group: StorageGroup) -> Double {
        let total = counts[group.id] ?? 0
        guard total > 0 else { return 0 }
        return min(1, Double(entry.photos) / Double(total))
    }

    /// Everything the cell is too small to print. The numbers stay in the grid
    /// and the sentences stay one hover away, which is the same bargain the
    /// section headings make.
    private func cellExplanation(
        group: StorageGroup,
        place: ArchivePlace,
        entry: AppStore.GroupPlaceCell?,
        named: Bool
    ) -> String {
        guard place.target != nil else {
            return "\(place.name) is not set up to hold copies yet."
        }
        guard let entry, !entry.isEmpty else {
            return named
                ? "\(group.label) is meant to be kept on \(place.name), and none of it is there yet."
                : "\(group.label) does not use \(place.name)."
        }
        let total = counts[group.id] ?? 0
        var parts = ["\(entry.photos.formatted()) of \(group.label)'s \(total.formatted()) photos are on \(place.name)."]
        if entry.insideDownload > 0 {
            parts.append(entry.insideDownload == entry.photos
                ? "All of them are counted inside Google download files rather than copied out."
                : "\(entry.insideDownload.formatted()) of them are counted inside Google download files rather than copied out.")
        }
        if entry.waiting > 0 { parts.append("\(entry.waiting.formatted()) still to copy.") }
        if entry.damaged > 0 { parts.append("\(entry.damaged.formatted()) no longer match what was imported.") }
        return parts.joined(separator: " ")
    }

    private var legend: some View {
        HStack(spacing: 12) {
            key(.green, "held and read back")
            key(.orange, "still copying")
            key(.red, "no longer matching")
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: 11, height: 11)
                Text("not used by that group")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func key(_ colour: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(colour.opacity(0.55)).frame(width: 11, height: 11)
            Text(text)
        }
    }

    // MARK: - What opens under the grid

    @ViewBuilder
    private func expansion(_ opened: Opened) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Both panels were written to open directly under the thing that
            // names them, and neither prints its own name because of it. Under
            // a table that is no longer true — a column's header can be four
            // rows above the panel it opened, with two other columns in
            // between — so the panel has to say what it is about.
            HStack(spacing: 6) {
                Image(systemName: openedSymbol(opened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(openedName(opened))
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { self.opened = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            Divider()
            switch opened {
            case .group(let id):
                if let group = store.storageGroups.first(where: { $0.id == id }) {
                    StorageGroupDetail(group: group)
                }
            case .place(let id):
                if let target = store.targetsByID[id] {
                    DriveCard(drive: target, drawsContainer: false, onForget: { onForget(target) })
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
        .transition(.opacity)
    }

    private func openedName(_ opened: Opened) -> String {
        switch opened {
        case .group(let id):
            return store.storageGroups.first { $0.id == id }?.label ?? "This group"
        case .place(let id):
            return store.targetsByID[id]?.name ?? "This device"
        }
    }

    private func openedSymbol(_ opened: Opened) -> String {
        switch opened {
        case .group: return "square.stack.3d.up"
        case .place(let id):
            return store.targetsByID[id]?.kind == .hostDevice ? "laptopcomputer" : "externaldrive.fill"
        }
    }

    // MARK: - Below the table

    @ViewBuilder
    private var footerControls: some View {
        // Photos nobody has placed. Said out loud rather than left to the
        // defaults in silence: a photo whose copies are decided by a remembered
        // UI answer is the one case where the archive's storage does not come
        // from something the user can read.
        if !store.ungroupedAssetIDs.isEmpty {
            let stranded = store.ungroupedAssetIDs
            HStack(spacing: 10) {
                Image(systemName: "questionmark.square.dashed")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Formatters.count(stranded.count, "photo")) in no group")
                        .font(.callout.weight(.medium))
                    Text("They follow whatever was last chosen in the add sheet until you put them somewhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Put them in a group…") { placingStranded = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(.vertical, 2)
        }
        Button {
            // Straight into the settings, because a group whose devices nobody
            // has chosen keeps nothing.
            if let made = store.createStorageGroup(label: "New group") { editing = made }
        } label: {
            Label("New group", systemImage: "plus")
                .font(.callout)
        }
        .buttonStyle(.link)
    }
}
