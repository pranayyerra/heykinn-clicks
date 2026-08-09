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

    /// The change being composed. Its rules live in `StoragePlacementDraft`,
    /// which is where they can be tested; this only holds it and draws it.
    @State private var draft: StoragePlacementDraft?
    @State private var plan: RetargetPlan?
    @State private var confirmingApply = false

    /// A failure being played out against the table. Nil means the table is
    /// showing what is actually there, which is its normal and default state:
    /// this is the one screen whose whole job is telling the truth, so a
    /// hypothesis on it has to be loud, opt-in, and easy to leave.
    @State private var whatIf: ArchiveLoss?

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
                    failureChips
                    if let whatIf { consequence(of: whatIf) }
                    grid
                        .padding(whatIf == nil ? 0 : 8)
                        .background {
                            if whatIf != nil {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(
                                        Color.orange.opacity(0.5),
                                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                                    )
                            }
                        }
                    // The legend names the colours of a real archive. Under
                    // a hypothesis the colours mean something else entirely,
                    // and a key to the wrong picture is worse than none.
                    if whatIf == nil { legend }
                }
                footerControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    // MARK: - What if I lost it

    /// The failure modes, each carrying what it would cost, worst first.
    ///
    /// The cost is on the chip rather than behind it on purpose. A row of bare
    /// names is a toy nobody touches; a row that already says *my Google
    /// downloads · 21,380* and *Owner's Back · nothing* is a ranked answer to
    /// "what should I worry about" that happens to also be clickable. It reads
    /// without being used, which is the property a status has and a simulator
    /// does not.
    @ViewBuilder
    private var failureChips: some View {
        let ranked = store.rankedFailures
        if !ranked.isEmpty {
            HStack(spacing: 6) {
                Text("What if I lost")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(ranked, id: \.loss) { entry in
                    chip(entry.loss, entry.projection)
                }
                if whatIf != nil {
                    Button("Show what is really there") {
                        withAnimation(.easeInOut(duration: 0.18)) { whatIf = nil }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func chip(_ loss: ArchiveLoss, _ projection: LossProjection) -> some View {
        let selected = whatIf == loss
        let tint: Color = projection.lost > 0 ? .red : .secondary
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                whatIf = selected ? nil : loss
                // A hypothesis and an edit are two different things to be doing
                // to one row, and neither is legible while the other is on.
                if !selected { endEditing(); opened = nil }
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.failureName(loss))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(projection.lost > 0 ? projection.lost.formatted() : "nothing")
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(selected ? tint.opacity(0.18) : Color.secondary.opacity(0.08))
            )
            .overlay(
                Capsule().strokeBorder(
                    selected ? tint.opacity(0.6) : Color.secondary.opacity(0.25),
                    lineWidth: selected ? 1.5 : 1
                )
            )
        }
        .buttonStyle(.plain)
        .help(chipExplanation(loss, projection))
    }

    private func chipExplanation(_ loss: ArchiveLoss, _ projection: LossProjection) -> String {
        projection.lost > 0
            ? "\(Formatters.count(projection.lost, "photo")) would have no copy left anywhere."
            : "Nothing would be lost — every photo involved is also somewhere else."
    }

    /// What the failure would actually mean, in words, above the picture of it.
    @ViewBuilder
    private func consequence(of loss: ArchiveLoss) -> some View {
        let projection = store.lossByFailure[loss] ?? LossProjection()
        let tint: Color = projection.lost > 0 ? .red : .green
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: projection.lost > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline(loss, projection))
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(consequenceNotes(loss, projection), id: \.self) { note in
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private func headline(_ loss: ArchiveLoss, _ projection: LossProjection) -> String {
        let name = store.failureName(loss)
        if projection.lost > 0 {
            return "\(Formatters.count(projection.lost, "photo")) would be gone if you lost \(name)."
        }
        return "Nothing would be lost if you lost \(name)."
    }

    private func consequenceNotes(_ loss: ArchiveLoss, _ projection: LossProjection) -> [String] {
        var notes: [String] = []
        if projection.reducedToOneCopy > 0 {
            notes.append("\(Formatters.count(projection.reducedToOneCopy, "photo")) would be left on a single copy until you replaced it.")
        }
        switch loss {
        case .downloadsEverywhere:
            // The distinction the number depends on, and the one somebody is
            // most likely to get wrong while holding a delete key.
            notes.append("These are counted inside the download files rather than copied out, and those are the same files on each device — so one deletion takes every copy. Deleting them from one device only loses nothing.")
        case .device(let id) where store.targetsByID[id]?.kind == .hostDevice:
            // The cost the grid structurally cannot show: there is no cell for
            // the catalog, and answering "no photos lost" alone would be true
            // and dangerously incomplete.
            let snapshot = store.catalogSnapshots
                .filter { $0.key != id }
                .flatMap(\.value)
                .max { $0.createdAt < $1.createdAt }
            notes.append(
                snapshot.map {
                    "Everything the app knows — where copies are, what was verified, the albums and people read out of your exports — comes back from the catalog snapshot written \(Formatters.relative($0.createdAt)) on \($0.targetID.flatMap { store.targetsByID[$0]?.name } ?? "a drive")."
                } ?? "No catalog snapshot exists on another device yet, so everything the app knows about these photos would have to be rebuilt by importing them again."
            )
        default:
            break
        }
        if projection.alreadyUnprotected > 0 {
            notes.append("\(Formatters.count(projection.alreadyUnprotected, "photo")) already has no copy anywhere, whatever happens to this.")
        }
        return notes
    }

    /// How many of a cell's photos would survive the failure being played out.
    private func surviving(_ entry: AppStore.GroupPlaceCell, on place: ArchivePlace, under loss: ArchiveLoss) -> Int {
        switch loss {
        case .device(let id):
            return place.target?.id == id ? 0 : entry.photos
        case .downloadsEverywhere:
            return entry.photos - entry.insideDownload
        case .downloadsOn(let id):
            return place.target?.id == id ? entry.photos - entry.insideDownload : entry.photos
        }
    }

    // MARK: - The table

    /// Every cell already has an explicit width, so this is stacks rather than
    /// a `Grid`.
    ///
    /// It was a `Grid`, with the open panel as a cell spanning every column.
    /// A spanning cell inside a grid inside a horizontally scrolling view sized
    /// itself to something far taller than its contents — the panel ran on for
    /// a couple of hundred empty points and pushed every group below it off the
    /// screen. `Grid` was buying nothing here: it aligns columns by measuring
    /// them, and these are `rowHeaderWidth` and `cellWidth`, decided in advance.
    private var grid: some View {
        // Horizontally scrollable rather than compressed: a cell narrower than
        // its number is a cell that cannot be read, and there is no useful
        // abbreviation of "21,117".
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 6) {
                    Color.clear.frame(width: rowHeaderWidth, height: 1)
                    ForEach(places) { columnHeader($0) }
                }
                // A device's panel opens against the header row it came from,
                // which is the only place in the table a column is named.
                if case .place(let id) = opened, let target = store.targetsByID[id] {
                    panel(
                        symbol: target.kind == .hostDevice ? "laptopcomputer" : "externaldrive.fill",
                        title: target.name
                    ) {
                        DriveCard(drive: target, drawsContainer: false, onForget: { onForget(target) })
                    }
                }
                ForEach(groups) { group in
                    HStack(alignment: .center, spacing: 6) {
                        rowHeader(group)
                        ForEach(places) { place in
                            cell(group: group, place: place)
                        }
                    }
                    // Directly under its own row, not under the table. With one
                    // group the difference is cosmetic; with twenty it is the
                    // difference between reading a group's detail beside the
                    // row you opened and scrolling past nineteen others to
                    // find it, then scrolling back to act on it.
                    if opened == .group(group.id) {
                        panel(
                            symbol: "square.stack.3d.up",
                            // No title: this opens directly beneath the row
                            // bearing the same name, one line up.
                            title: nil,
                            trailing: {
                                // Editing is a mode you ask for. Cells that
                                // could be dragged at any moment would make
                                // every glance at the table a chance to move an
                                // archive by accident.
                                if draft?.groupID != group.id {
                                    Button("Edit") { beginEditing(group) }
                                        .font(.caption)
                                        .help("Move where this group is kept, and how many copies it keeps.")
                                }
                            }
                        ) {
                            if draft?.groupID == group.id {
                                editor(group)
                            } else {
                                StorageGroupDetail(group: group)
                            }
                        }
                    }
                }
                Divider().frame(width: tableWidth)
                HStack(alignment: .top, spacing: 6) {
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

    /// Exactly as wide as the table above it, so an opened panel can never
    /// widen what scrolls.
    private var tableWidth: CGFloat {
        rowHeaderWidth + CGFloat(places.count) * (cellWidth + 6)
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
                endEditing()
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
                        .strikethrough(whatIf == place.target.map { ArchiveLoss.device($0.id) })
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
                // Opening something else ends an edit in progress. A draft that
                // survives out of sight is a change somebody stops being able
                // to see and still applies.
                if draft?.groupID != group.id { endEditing() }
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
                        // Under a hypothesis the row answers the hypothesis.
                        // Its usual subtitle describes an arrangement that
                        // would no longer exist, and printing both invites the
                        // reader to work out which one is true.
                        if let loss = whatIf {
                            let gone = store.lossByFailure[loss]?.lostByGroup[group.id] ?? 0
                            Text(gone > 0
                                 ? "\(gone.formatted()) of \(Formatters.count(counts[group.id] ?? 0, "photo")) would be gone"
                                 : "none of these would be lost")
                                .font(.caption2)
                                .foregroundStyle(gone > 0 ? Color.red : Color.green)
                                .lineLimit(1)
                        } else {
                            Text(rowSubtitle(group, short: short))
                                .font(.caption2)
                                .foregroundStyle(short > 0 || !group.isSatisfiable ? Color.orange : .secondary)
                                .lineLimit(1)
                        }
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
                // No "Edit where it is kept" here. The panel this row opens has
                // an Edit button, and two doors to one editor is how they come
                // to behave differently.
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
            // Under a hypothesis this has to answer the hypothesis. "21,401
            // held · nothing only here" is true of the archive that exists and
            // false of the one being drawn above it, and the two sitting in one
            // column is precisely the confusion a what-if mode risks.
            if let loss = whatIf, place.target != nil {
                let left = groups.reduce(0) { total, group in
                    guard let entry = place.target.flatMap({ store.cell(group: group.id, place: $0.id) })
                    else { return total }
                    return total + surviving(entry, on: place, under: loss)
                }
                Text(left == 1 ? "1 would be left" : "\(left.formatted()) would be left")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(left == 0 ? Color.red : .secondary)
            } else if place.target == nil {
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
        if draft?.groupID == group.id {
            editableCell(place)
        } else {
            readingCell(group: group, place: place)
        }
    }

    /// A row being edited: where the group is kept, as something you can pick
    /// up and put down.
    ///
    /// Retargeting was a sheet with a list of checkboxes — uncheck one device,
    /// check another, read a summary, save. That is four decisions to express
    /// one: *this goes there*. Dragging says it once, in the row that shows
    /// what moving it would mean.
    @ViewBuilder
    private func editableCell(_ place: ArchivePlace) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        let holds = place.target.map { draft?.destinations.contains($0.id) ?? false } ?? false

        Group {
            if let target = place.target, holds {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.caption2)
                    Text("kept here")
                        .font(.caption)
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { removeDestination(target.id) }
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Stop keeping this group on \(target.name)")
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .frame(width: cellWidth, alignment: .leading)
                .background(Color.accentColor.opacity(0.14), in: shape)
                .overlay(shape.strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
                .draggable(target.id.uuidString) {
                    Label("kept here", systemImage: "square.stack.3d.up.fill")
                        .padding(6)
                        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                .help("Drag this onto another device to move it there.")
            } else if let target = place.target {
                // A Button, not a tappable view. `dropDestination` swallows
                // `onTapGesture` — a cell built that way accepted drops and
                // ignored every click, which is the half nobody would report
                // because the other half looked fine.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { addDestination(target.id) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.circle").font(.caption2)
                        Text("keep here too").font(.caption)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .frame(width: cellWidth, alignment: .leading)
                    .contentShape(shape)
                    .background {
                        shape.strokeBorder(
                            Color.secondary.opacity(0.4),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                    }
                }
                .buttonStyle(.plain)
                .dropDestination(for: String.self) { items, _ in
                    move(from: items.first, to: target.id)
                }
                .help("Drop a placement here, or click to add \(target.name) as another home.")
            } else {
                // A device that is not set up cannot be given anything. Drawn
                // all the same, because the column exists and a gap with no
                // explanation reads as a bug.
                Text("not set up")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .frame(width: cellWidth, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func readingCell(group: StorageGroup, place: ArchivePlace) -> some View {
        let entry = place.target.flatMap { store.cell(group: group.id, place: $0.id) }
        let named = place.target.map { group.destinationTargetIDs.contains($0.id) } ?? false
        let shape = RoundedRectangle(cornerRadius: 6)

        Group {
            if let entry, !entry.isEmpty, let loss = whatIf {
                // The hypothesis, drawn over the same cell: what is left, with
                // what it was struck through beneath it. Showing only the
                // survivor would make a wiped-out cell indistinguishable from a
                // device the group never used.
                let left = surviving(entry, on: place, under: loss)
                let tint: Color = left == 0 ? .red : left < entry.photos ? .orange : .secondary
                VStack(alignment: .leading, spacing: 2) {
                    Text(left.formatted())
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(tint)
                    if left < entry.photos {
                        Text(entry.photos.formatted())
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .strikethrough()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(width: cellWidth, alignment: .leading)
                .background(tint.opacity(left < entry.photos ? 0.12 : 0.05), in: shape)
            } else if let entry, !entry.isEmpty {
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

    // MARK: - Editing a row

    private func move(from raw: String?, to targetID: UUID) -> Bool {
        guard let raw, let from = UUID(uuidString: raw), var next = draft else { return false }
        guard next.move(from: from, to: targetID) else { return false }
        withAnimation(.easeInOut(duration: 0.15)) { draft = next }
        refreshPlanForDraft()
        return true
    }

    private func addDestination(_ targetID: UUID) {
        guard var next = draft, next.add(targetID) else { return }
        draft = next
        refreshPlanForDraft()
    }

    private func removeDestination(_ targetID: UUID) {
        guard var next = draft, next.remove(targetID) else { return }
        draft = next
        refreshPlanForDraft()
    }

    private func beginEditing(_ group: StorageGroup) {
        withAnimation(.easeInOut(duration: 0.18)) {
            opened = .group(group.id)
            draft = StoragePlacementDraft(group: group)
        }
        refreshPlan(for: group)
    }

    private func endEditing() {
        withAnimation(.easeInOut(duration: 0.18)) { draft = nil }
        plan = nil
    }

    /// The plan walks every asset in the group, so it is recomputed when the
    /// draft changes rather than read from a body that runs on every redraw.
    private func refreshPlan(for group: StorageGroup) {
        guard let draft else { plan = nil; return }
        plan = store.retargetPlan(
            for: group, newDestinations: draft.destinations, newCopies: draft.copies
        )
    }

    private func refreshPlanForDraft() {
        guard let draft, let group = store.storageGroups.first(where: { $0.id == draft.groupID })
        else { return }
        refreshPlan(for: group)
    }

    /// The row's editor: the count, what the change would do, and one way out
    /// in each direction.
    @ViewBuilder
    private func editor(_ group: StorageGroup) -> some View {
        if let draft, draft.groupID == group.id {
            let issue = draft.problem
            let changed = draft.differs(from: group)

            VStack(alignment: .leading, spacing: 12) {
                // What the arrangement means, in words, updating as it changes.
                //
                // The tick list and the number sat side by side with nothing
                // between them, so three devices and two copies read as a
                // contradiction rather than as a spare. It is the one thing
                // here somebody cannot work out by looking.
                Text(draft.rule { store.targetsByID[$0]?.name ?? "a device" })
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Drag **kept here** onto another device to move it. Click a dashed cell to add one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Stepper(value: Binding(
                        get: { self.draft?.copies ?? group.desiredCopies },
                        set: { new in
                            guard var next = self.draft else { return }
                            next.copies = new
                            self.draft = next
                            refreshPlan(for: group)
                        }
                    ), in: 1...max(1, draft.destinations.count)) {
                        HStack(spacing: 6) {
                            Text("Keep")
                                .font(.callout)
                            Text("\(draft.copies)")
                                .font(.title3.monospacedDigit().weight(.medium))
                                .frame(minWidth: 18)
                            Text(draft.copies == 1 ? "copy of every photo" : "copies of every photo")
                                .font(.callout)
                        }
                    }
                    .fixedSize()
                    Spacer(minLength: 0)
                }

                if draft.mode == .automatic {
                    Label(
                        "This group works out its own devices. Moving one fixes it to the devices you name.",
                        systemImage: "wand.and.stars"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let issue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if changed, let plan, !plan.isEmpty {
                    Divider()
                    RetargetSummary(plan: plan)
                } else if changed {
                    Label("Nothing to copy or delete — the photos are already where this puts them.",
                          systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Cancel") { endEditing() }
                    Spacer()
                    Button(plan?.isNonDestructive == false ? "Apply and move…" : "Apply") {
                        if plan?.isNonDestructive == false { confirmingApply = true } else { apply(group) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(issue != nil || !changed)
                }
                .font(.callout)
            }
            .confirmationDialog(
                "Move \(group.label)?",
                isPresented: $confirmingApply,
                titleVisibility: .visible
            ) {
                Button("Copy now, delete later", role: .destructive) { apply(group) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(Formatters.count(plan?.totalToCopy ?? 0, "photo")) will be copied first. Only once every new copy has been read back and matched will the \(Formatters.count(plan?.totalToDelete ?? 0, "copy", "copies")) the app wrote elsewhere be deleted. Nothing you put on those disks yourself is touched.")
            }
        }
    }

    private func apply(_ group: StorageGroup) {
        guard let draft, draft.canBeSaved else { return }
        store.applyStorageGroupSettings(
            group,
            desiredCopies: draft.copies,
            destinations: draft.destinations,
            mode: draft.mode
        )
        endEditing()
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

    // MARK: - What opens inside the grid

    /// The container both panels sit in. It names what it is about, because
    /// the thing that opened it can now be several rows away — a column header
    /// at the top of the table, or a group row above nineteen others.
    @ViewBuilder
    private func panel<Content: View, Trailing: View>(
        symbol: String,
        title: String?,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let title {
                    Image(systemName: symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.callout.weight(.semibold))
                }
                Spacer(minLength: 8)
                trailing()
                Button {
                    endEditing()
                    withAnimation(.easeInOut(duration: 0.18)) { opened = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            if title != nil { Divider() }
            content()
        }
        .padding(12)
        .frame(width: tableWidth, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
        .transition(.opacity)
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
            // Straight into the editor, because a group whose devices nobody
            // has chosen keeps nothing.
            if let made = store.createStorageGroup(label: "New group") { beginEditing(made) }
        } label: {
            Label("New group", systemImage: "plus")
                .font(.callout)
        }
        .buttonStyle(.link)
    }
}
