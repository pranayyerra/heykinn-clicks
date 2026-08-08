import SwiftUI

/// Every set of photos that is kept its own way, and the controls to change it.
///
/// Groups existed before this screen and could only be reached sideways — from
/// the card of the source they happened to be born with. That was fine while
/// every group *was* an import, and stopped being fine the moment one could be
/// made by hand: a group with no source behind it had no way in at all.
struct StorageGroupsList: View {
    @EnvironmentObject private var store: AppStore
    @State private var editing: StorageGroup?
    @State private var renaming: StorageGroup?
    @State private var renameText = ""
    @State private var deleting: StorageGroup?
    @State private var moveDestination: UUID?

    private var counts: [UUID: Int] { store.photoCountByStorageGroup }

    var body: some View {
        Section {
            ForEach(store.storageGroups.sorted(by: { $0.createdAt < $1.createdAt })) { group in
                row(group)
            }
            if store.storageGroups.isEmpty {
                Text("No groups yet. One is made for you each time you add photos.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button {
                let made = store.createStorageGroup(label: "New group")
                // Straight into the settings, because a group whose devices
                // nobody has chosen keeps nothing.
                if let made { editing = made }
            } label: {
                Label("New group", systemImage: "plus")
                    .font(.callout)
            }
            .buttonStyle(.link)
        } header: {
            Text("How many copies of each set of photos to keep, and which devices hold them. A photo is in exactly one group.")
                .fixedSize(horizontal: false, vertical: true)
                .textCase(nil)
        }
        .sheet(item: $editing) { EditStorageGroupSheet(group: $0) }
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

    private func row(_ group: StorageGroup) -> some View {
        let held = counts[group.id] ?? 0
        return HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.label)
                    .font(.callout.weight(.medium))
                // What it asks for and where, in one line, because those two
                // are the whole of what a group is.
                Text("\(Formatters.copies(group.desiredCopies)) on \(store.deviceNames(group.destinationTargetIDs))")
                    .font(.caption)
                    .foregroundStyle(group.isSatisfiable ? Color.secondary : Color.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(Formatters.count(held, "photo"))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Change…") { editing = group }
                .buttonStyle(.link)
                .font(.caption)
            Menu {
                Button("Rename…") {
                    renameText = group.label
                    renaming = group
                }
                Button("Remove…", role: .destructive) {
                    moveDestination = nil
                    deleting = group
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }
}

/// Removing a group, and saying where its photos go.
///
/// A group is how the app knows where a photo belongs. Dropping one that still
/// holds photos would leave them answering to whatever the add sheet last
/// remembered — so somewhere has to be named, and the sheet says how many are
/// moving rather than making the user work it out.
struct RemoveStorageGroupSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let group: StorageGroup
    let photoCount: Int
    @State private var destination: UUID?

    private var others: [StorageGroup] {
        store.storageGroups.filter { $0.id != group.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove \(group.label)?")
                .font(.title3)
                .bold()

            if photoCount == 0 {
                Text("It holds no photos, so nothing moves and nothing is deleted.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if others.isEmpty {
                Text("It holds \(Formatters.count(photoCount, "photo")) and there is nowhere else to put them. Make another group first.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Its \(Formatters.count(photoCount, "photo")) move to another group. No photo is deleted, and nothing already on a device is removed until the new copies have been read back and matched.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Move them to", selection: $destination) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(others) { other in
                        Text("\(other.label) — \(Formatters.copies(other.desiredCopies)) on \(store.deviceNames(other.destinationTargetIDs))")
                            .tag(UUID?.some(other.id))
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Remove", role: .destructive) {
                    store.deleteStorageGroup(group.id, movingPhotosTo: destination)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(photoCount > 0 && destination == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Moving a selection of photos into a group.
///
/// The action the storage model was built for and could not offer: a group made
/// by hand had no way to gain members. What it asks is deliberately narrow —
/// which group — because the group already carries how many copies and where,
/// and asking those again here would be a second place to set them.
struct MoveToStorageGroupSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let assetIDs: [UUID]
    /// How many actually moved, so the caller can clear its selection.
    var onMove: (Int) -> Void = { _ in }

    @State private var destination: UUID?
    @State private var newGroupName = ""
    @State private var makingNew = false

    /// Where these photos are now. Named, because moving 200 photos out of a
    /// group is worth seeing stated before it happens.
    private var currentGroups: [StorageGroup] {
        let ids = Set(assetIDs.compactMap { store.storageGroupIDByAsset[$0] })
        return store.storageGroups.filter { ids.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move \(Formatters.count(assetIDs.count, "photo"))")
                .font(.title3)
                .bold()

            if !currentGroups.isEmpty {
                Text(currentGroups.count == 1
                     ? "They are in \(currentGroups[0].label)."
                     : "They are spread across \(Formatters.count(currentGroups.count, "group")).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if makingNew {
                TextField("Name for the new group", text: $newGroupName)
                    .textFieldStyle(.roundedBorder)
                Text("It starts with the settings you last chose. Change them under Policies once it exists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Move them to", selection: $destination) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(store.storageGroups) { group in
                        Text("\(group.label) — \(Formatters.copies(group.desiredCopies)) on \(store.deviceNames(group.destinationTargetIDs))")
                            .tag(UUID?.some(group.id))
                    }
                }
                Button("New group instead…") {
                    makingNew = true
                    newGroupName = ""
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            // Says what will happen to the bytes, which is the part a person
            // wants before agreeing to it.
            Text("Copies to any device the new group names are queued. Nothing already on a device is deleted until the new copies have been read back and matched.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Move") { move() }
                    .buttonStyle(.borderedProminent)
                    .disabled(makingNew
                              ? newGroupName.trimmingCharacters(in: .whitespaces).isEmpty
                              : destination == nil)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func move() {
        let targetID: UUID?
        if makingNew {
            targetID = store.createStorageGroup(label: newGroupName)?.id
        } else {
            targetID = destination
        }
        guard let targetID else { return }
        onMove(store.moveToStorageGroup(targetID, assetIDs: assetIDs))
        dismiss()
    }
}
