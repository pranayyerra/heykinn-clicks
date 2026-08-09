import SwiftUI

/// Choosing how many copies of a source to keep, and which devices keep them.
///
/// One control used twice — once when a source is added, once when its settings
/// change — because they are the same question and answering them in two
/// different-looking places is how a person ends up unsure whether they mean
/// the same thing.
///
/// The copy count and the device list are shown together and validated against
/// each other, since the failure people actually hit is asking for two copies
/// with one device ticked, and a stepper that cannot see the checkboxes has no
/// way to say so.
struct SourceSettingsPicker: View {
    @EnvironmentObject private var store: AppStore
    @Binding var desiredCopies: Int
    @Binding var destinationTargetIDs: [UUID]
    @Binding var destinationMode: StorageGroup.DestinationMode

    /// Open once the reader has asked for it, and stays open for a set that
    /// already names its own drives — hiding a choice somebody made is worse
    /// than showing a control they will not use.
    @State private var isPickingDrives = false

    private var chosen: Set<UUID> { Set(destinationTargetIDs) }

    private func toggle(_ targetID: UUID) {
        // Touching the list *is* the choice. It is the only signal there is:
        // picking one drive for a one-copy set produces exactly what working
        // it out produces, so the devices cannot be read back afterwards to
        // tell which happened.
        destinationMode = .chosen
        if let index = destinationTargetIDs.firstIndex(of: targetID) {
            destinationTargetIDs.remove(at: index)
        } else {
            // Appended rather than inserted in registration order: the order
            // devices are ticked is the order they are named, and the first one
            // is the one the user thinks of as primary.
            destinationTargetIDs.append(targetID)
        }
    }

    /// Where a worked-out set lands, given what it is asking for now.
    private var workedOut: [UUID] {
        StorageGroup.automaticDestinations(
            copies: desiredCopies, among: store.automaticEligibleDeviceIDs
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper(
                "Keep \(Formatters.count(desiredCopies, "copy", "copies")) of every photo",
                value: $desiredCopies,
                in: 1...max(store.automaticEligibleDeviceIDs.count, 1)
            )
            .font(.callout)
            .onChange(of: desiredCopies) { _, _ in
                guard destinationMode == .automatic else { return }
                destinationTargetIDs = workedOut
            }

            if store.targets.isEmpty {
                Label(
                    "No devices are set up yet. Add one under Keep safe, then come back.",
                    systemImage: "externaldrive.badge.plus"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                // The number is the question. Where those copies go is stated,
                // not asked — with two drives and two copies there has only
                // ever been one answer, and a picker with one answer teaches
                // the reader nothing while making them responsible for it.
                if destinationMode == .automatic, !isPickingDrives {
                    Text(destinationTargetIDs.isEmpty
                         ? "Nowhere to keep them yet."
                         : "On \(store.deviceNames(destinationTargetIDs)).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if idleDrives > 0 {
                        Text("You have \(Formatters.count(store.automaticEligibleDeviceIDs.count, "drive")) and keep \(Formatters.count(desiredCopies, "copy", "copies")), so \(idleDrives == 1 ? "one holds" : "\(idleDrives) hold") none of this.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Choose the drives myself…") { isPickingDrives = true }
                        .buttonStyle(.link)
                        .font(.caption)
                } else {
                    Text("On these devices")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.targets) { target in
                            deviceRow(target)
                        }
                    }
                    if destinationMode == .chosen {
                        Button("Let the app work it out") {
                            destinationMode = .automatic
                            destinationTargetIDs = workedOut
                            isPickingDrives = false
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }

            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { isPickingDrives = destinationMode == .chosen }
    }

    /// Drives holding none of this set because it asks for fewer copies than
    /// there are drives. The one case where a drive bought later has nothing to
    /// do, and the reader should hear it from the app rather than notice it.
    private var idleDrives: Int {
        max(0, store.automaticEligibleDeviceIDs.count - destinationTargetIDs.count)
    }

    /// Said before the choice is made rather than reported as a shortfall
    /// afterwards. Asking for more copies than there are devices to hold them
    /// is not something a sync will ever resolve.
    private var warning: String? {
        guard !store.targets.isEmpty else { return nil }
        if destinationTargetIDs.isEmpty {
            return "Pick at least one device, or these photos will be kept nowhere."
        }
        if destinationTargetIDs.count < desiredCopies {
            return destinationMode == .automatic
                ? "\(Formatters.count(desiredCopies, "copy", "copies")) needs \(desiredCopies) drives, and there \(store.automaticEligibleDeviceIDs.count == 1 ? "is" : "are") \(store.automaticEligibleDeviceIDs.count). Add another and this fills itself in."
                : "\(Formatters.count(desiredCopies, "copy", "copies")) needs \(desiredCopies) devices, and \(destinationTargetIDs.count) is chosen. Photos will stop short until another is picked."
        }
        // Said here, where the choice is made, rather than only afterwards.
        //
        // This picker counted devices and the screen that judges the result
        // counts drives, so picking a drive and this Mac satisfied "two copies"
        // in silence and then came back as an orange "12 photos are on one
        // drive only". The app let somebody build the one arrangement it goes
        // on to complain about, and said nothing at the moment it could have
        // been useful.
        //
        // A warning, not a refusal: the Mac is a real second place, and
        // somebody with one drive is better off using it than not. It just is
        // not a second *drive*, and that is what the copy count implies.
        let drivesChosen = destinationTargetIDs
            .filter { store.targetsByID[$0]?.kind == .externalVolume }
            .count
        if drivesChosen < desiredCopies {
            return "Only \(Formatters.count(drivesChosen, "of these is a drive", "of these are drives")). This Mac is the machine your drives exist to survive, so a copy here is not a second drive — these photos would read as being on \(Formatters.count(drivesChosen, "drive"))."
        }
        return nil
    }

    private func deviceRow(_ target: ReplicationTarget) -> some View {
        let isOn = chosen.contains(target.id)
        let reachable = store.reachablePaths[target.id] != nil
        let free = store.reachablePaths[target.id]
            .flatMap { TakeoutExtractor.availableCapacity(onVolumeOf: $0) }
        return Button {
            toggle(target.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Image(systemName: target.kind == .hostDevice ? "laptopcomputer" : "externaldrive.fill")
                    .foregroundStyle(Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.name)
                        .font(.callout)
                    // Room and reachability where the decision is made. A
                    // device that is not plugged in is still a valid choice —
                    // the copy waits — but the reader should know which one
                    // they are picking.
                    Text(target.kind == .hostDevice
                         ? "This Mac — a real place, but not a second drive"
                         : detail(reachable: reachable, free: free))
                        .font(.caption2)
                        .foregroundStyle(target.kind == .hostDevice ? Color.orange : Color.secondary)
                }
                Spacer(minLength: 0)
                if isOn, let position = destinationTargetIDs.firstIndex(of: target.id) {
                    Text(position == 0 ? "first choice" : "then")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detail(reachable: Bool, free: Int64?) -> String {
        guard reachable else { return "Not connected — copies wait until it is" }
        guard let free else { return "Connected" }
        return "Connected · \(Formatters.bytes.string(fromByteCount: free)) free"
    }
}

/// Shown when a folder is picked, before anything is read.
struct AddSourceSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var setup: AppStore.PendingSourceSetup

    init(setup: AppStore.PendingSourceSetup) {
        _setup = State(initialValue: setup)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add \(setup.label)")
                    .font(.title3)
                    .bold()
                Text(setup.urls.count == 1
                     ? setup.urls[0].path
                     : "\(setup.urls.count) folders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
            }

            SourceSettingsPicker(
                desiredCopies: $setup.desiredCopies,
                destinationTargetIDs: $setup.destinationTargetIDs,
                destinationMode: $setup.destinationMode
            )

            Text("The folder is only ever read. Photos already on a device you pick are counted where they are rather than copied again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") {
                    store.pendingSourceSetup = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add and start reading") {
                    store.confirmAddingSource(setup)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(setup.destinationTargetIDs.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Changing an existing source, with the consequences stated before they happen.
struct EditStorageGroupSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let group: StorageGroup
    @State private var desiredCopies: Int
    @State private var destinationTargetIDs: [UUID]
    @State private var destinationMode: StorageGroup.DestinationMode
    @State private var confirming = false

    init(group: StorageGroup) {
        self.group = group
        _desiredCopies = State(initialValue: group.desiredCopies)
        _destinationTargetIDs = State(initialValue: group.destinationTargetIDs)
        _destinationMode = State(initialValue: group.destinationMode)
    }

    /// Recomputed only when the choice changes, not on every redraw.
    ///
    /// The plan walks every asset of the source; on a 24,000-photo archive a
    /// computed property read four times per body evaluation is four full
    /// passes per keystroke on the stepper.
    @State private var plan = RetargetPlan(
        sourceID: UUID(), sourceLabel: "", arriving: [], departing: []
    )

    private func recomputePlan() {
        plan = store.retargetPlan(
            for: group, newDestinations: destinationTargetIDs, newCopies: desiredCopies
        )
    }

    private var hasChanges: Bool {
        desiredCopies != group.desiredCopies
            || destinationTargetIDs != group.destinationTargetIDs
            || destinationMode != group.destinationMode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.label)
                    .font(.title3)
                    .bold()
                if let path = store.originPath(forStorageGroup: group.id) {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.head)
                }
            }

            SourceSettingsPicker(
                desiredCopies: $desiredCopies,
                destinationTargetIDs: $destinationTargetIDs,
                destinationMode: $destinationMode
            )

            if hasChanges, !plan.isEmpty {
                Divider()
                RetargetSummary(plan: plan)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(plan.isNonDestructive ? "Save" : "Save and move…") {
                    if plan.isNonDestructive {
                        apply()
                    } else {
                        confirming = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges || destinationTargetIDs.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { recomputePlan() }
        .onChange(of: destinationTargetIDs) { _, _ in recomputePlan() }
        .onChange(of: desiredCopies) { _, _ in recomputePlan() }
        .confirmationDialog(
            "Move \(group.label)?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Copy now, delete later", role: .destructive) { apply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(Formatters.count(plan.totalToCopy, "photo")) will be copied first. Only once every new copy has been read back and matched will the \(Formatters.count(plan.totalToDelete, "copy", "copies")) the app wrote elsewhere be deleted. Nothing you put on those disks yourself is touched.")
        }
    }

    private func apply() {
        store.applyStorageGroupSettings(
            group,
            desiredCopies: desiredCopies,
            destinations: destinationTargetIDs,
            mode: destinationMode
        )
        dismiss()
    }
}

/// What a retarget will do, split by whose bytes are involved.
struct RetargetSummary: View {
    let plan: RetargetPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What this changes")
                .font(.callout.weight(.medium))

            ForEach(plan.arriving) { change in
                Label(
                    "\(change.name) receives \(Formatters.count(change.toCopy, "photo")) — \(Formatters.bytes.string(fromByteCount: change.bytesToCopy))\(change.isReachable ? "" : ", once it is connected")",
                    systemImage: "arrow.down.circle"
                )
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(plan.departing) { change in
                VStack(alignment: .leading, spacing: 3) {
                    if change.toDelete > 0 {
                        // Stated as conditional, because it is: nothing is
                        // removed until the new copies have been read back.
                        Label(
                            "\(change.name): \(Formatters.count(change.toDelete, "copy", "copies")) the app wrote will be deleted once the new copies are verified — frees \(Formatters.bytes.string(fromByteCount: change.bytesFreed))",
                            systemImage: "trash"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if change.toRelease > 0 {
                        // The distinction the whole sheet exists for.
                        Label(
                            "\(change.name): \(Formatters.count(change.toRelease, "photo")) are your own files there. They stay exactly where they are and simply stop counting as a copy.",
                            systemImage: "hand.raised"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if change.toDelete == 0 && change.toRelease == 0 {
                        Label(
                            "\(change.name) holds none of this group, so nothing changes there.",
                            systemImage: "checkmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
