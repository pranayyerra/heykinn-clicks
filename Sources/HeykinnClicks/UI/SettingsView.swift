import SwiftUI

/// Preferences live here, in the standard place (⌘,), so the working screens
/// can show what the archive *is* instead of half-explaining how it behaves.
struct SettingsView: View {
    var body: some View {
        TabView {
            AutomationSettings()
                .tabItem { Label("Automation", systemImage: "wand.and.stars") }
            SafetySettings()
                .tabItem { Label("Safety", systemImage: "checkmark.shield") }
            PoliciesView()
                .tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }
            AccessSettings()
                .tabItem { Label("Access", systemImage: "key") }
        }
        // Fixed rather than content-sized: the tabs differ in height, and a
        // window that resizes as you switch tabs reads as a glitch.
        .frame(width: 540, height: 440)
    }
}

private struct AutomationSettings: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section {
                ExplainedToggle(
                    "Sync a managed drive when it connects",
                    isOn: $store.autoSyncOnConnect,
                    help: "Plugging a drive in starts working through its queue — copies it is missing, checks it owes — without waiting to be asked."
                )
            }
            Section {
                ExplainedToggle(
                    "Bring Photos-library originals into the archive",
                    isOn: $store.importFromApplePhotos,
                    help: "Photos the app has found in the Photos library are visible but protected by nothing until it holds their bytes. With this on, their originals are copied in and queued for your drives like anything else; ones already held byte-for-byte are merged rather than stored twice. Connect and watch progress under Add photos."
                )
            }
            Section {
                ExplainedToggle(
                    "Handle Google exports found on a drive",
                    isOn: $store.autoManageTakeout,
                    help: "Finds exports on a connected drive, unpacks and imports what is new, and recognises copies the drive already holds instead of copying them again."
                )
            }
            Section {
                ExplainedToggle(
                    "Free up space once your drives hold a photo",
                    isOn: $store.reclaimStagingWhenSafe,
                    help: "Photos added from anywhere the app does not manage are copied onto this Mac first, so they are safe before any drive is plugged in. With this on, that working copy is released once your own drives hold the photo and have read it back to confirm it — the same standard the app uses to call a photo safe anywhere else. Your originals are never touched, and nothing is released while a photo is short of the copies you asked for."
                )
            }
        }
        .formStyle(.grouped)
    }
}

/// Every disk the app has been given a standing answer about, and the way to
/// take that answer back.
///
/// This is the other half of the connect prompt's "remember this". Shipping
/// the remembering without the revoking is how somebody ends up with a drive
/// the app silently refuses to ask about and no screen that admits it exists —
/// which is what the previous `ignoredVolumeKeys` preference did.
private struct AccessSettings: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmingRevokeAll = false

    /// Through the store's mirror, not `accessGrants` directly: views observe
    /// `AppStore`, so reading the grant store straight would render once and
    /// never update — a revoked row would stay on screen.
    private var grants: [AccessGrant] { store.accessGrantList }

    var body: some View {
        Form {
            Section {
                Text("When you answer for a drive, the answer is kept so you are not asked again each time you plug it in. Everything kept is listed here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(
                    "Forgetting an answer changes nothing on the disk and unregisters nothing. The app simply asks about it again next time.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Disks you have answered for") {
                if grants.isEmpty {
                    Text("None yet. Connect a drive and the app will ask what it should be.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(grants) { grant in
                        row(grant)
                    }
                }
            }

            if !grants.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        Button("Forget all answers", role: .destructive) {
                            confirmingRevokeAll = true
                        }
                    }
                    .confirmationDialog(
                        "Forget every remembered answer?",
                        isPresented: $confirmingRevokeAll,
                        titleVisibility: .visible
                    ) {
                        Button("Forget all", role: .destructive) { store.revokeAllAccessGrants() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Nothing on any disk is changed and no registered device is unregistered. Each drive will be asked about again the next time it is connected.")
                    }
                }
            }

            Section("If macOS keeps asking as well") {
                Text("macOS has its own permission for reading external drives, separate from anything here. It is tied to the app's signature, so a build you compiled yourself is treated as a new app each time and macOS asks again. A signed release is not. Check System Settings → Privacy & Security → Files and Folders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ grant: AccessGrant) -> some View {
        let reachable = store.isAccessGrantReachable(grant)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: grant.decision.symbol)
                .foregroundStyle(reachable ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(grant.displayName)
                        .font(.callout.weight(.medium))
                    Text(reachable ? "Connected" : "Not connected")
                        .font(.caption2)
                        .foregroundStyle(reachable ? Color.green : Color.secondary)
                }
                Text(grant.decision.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The path even when the disk is absent: it is the only thing
                // that tells two identically-named drives apart, and a disk
                // being unplugged is exactly when someone wants to know which
                // one this row is about.
                if let path = grant.lastKnownPath {
                    Text(reachable ? path : "Last seen at \(path)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Text("Decided \(Formatters.relative(grant.decidedAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button("Forget") { store.revokeAccessGrant(grant.volumeKey) }
                .buttonStyle(.link)
                .font(.callout)
        }
        .padding(.vertical, 2)
    }
}

private struct SafetySettings: View {
    @EnvironmentObject private var store: AppStore
    @State private var isRestoring = false

    var body: some View {
        Form {
            Section("How many copies") {
                Label(
                    "Each group of photos says how many copies to keep. Change that under Keep safe, next to the photos it governs — there is no single setting for the whole archive.",
                    systemImage: "square.stack.3d.up"
                )
                .font(.callout)
            }
            Section("Background checking") {
                ExplainedToggle(
                    "Read a few files in the background",
                    isOn: $store.backgroundRotPatrol,
                    help: "Every half hour, on an idle drive, the app re-reads up to forty files — the ones longest unread, and only those nothing has read in the last month, so a small archive is checked once and then left alone. Reading is the only thing that finds bit rot — comparing what the catalog recorded can never see a file decay on disk. Photos counted inside a Google export are left to the export's own checks: they have no file of their own to read, and confirming the export is still on the disk is not reading anything. It yields to imports and syncs, and skips a target that has work waiting."
                )
            }
            Section("Catalog backup") {
                Text("The photos survive on the drives, but everything this app knows about them lives only in the catalog: which drives hold what, how copies were verified, how duplicates were grouped, and the descriptions, albums and people read out of your exports — that last part only exists here now. Verified snapshots ride along on each connected drive, so losing the Mac does not lose any of it. The newest \(CatalogBackupService.retainCount) are kept on each drive.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    if let latest = store.latestCatalogSnapshot {
                        Label(
                            "Last snapshot \(Formatters.relative(latest.createdAt))",
                            systemImage: "checkmark.shield"
                        )
                        .foregroundStyle(.green)
                    } else {
                        Label("No snapshot yet", systemImage: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Back up now") { store.backupCatalog(force: true) }
                        .disabled(store.reachablePaths.isEmpty)
                }
                .font(.callout)
                // The other half. Snapshots were written and verified from the
                // first release and there was no way to read one back inside
                // the app: recovery meant quitting, finding a file on a drive
                // and copying it over the catalog by hand. A backup nobody can
                // restore is a promise, not a safeguard.
                HStack {
                    Text("If this Mac's catalog is lost or goes wrong, restore it from one of these.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Restore…") { isRestoring = true }
                        .disabled(store.reachablePaths.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isRestoring) { RestoreCatalogSheet() }
    }
}

/// Choosing a snapshot to go back to.
///
/// Deliberately not a file picker. A picker would ask somebody to find a
/// `.sqlite` file inside an app folder on a drive and would happily accept the
/// wrong one; this lists what the app itself wrote, says what each holds, and
/// declines to show any it cannot read back.
private struct RestoreCatalogSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var choice: AppStore.RestorableSnapshot?
    @State private var confirming: AppStore.RestorableSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore the catalog")
                .font(.title2).bold()
            Text("This replaces what the app knows about your photos — which drives hold what, how copies were checked, and the albums and people read out of your exports. It changes nothing on any drive, and the catalog it replaces is kept rather than deleted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let snapshots = store.restorableSnapshots()
            if let blocker = store.catalogRestoreBlocker {
                Label("Not while \(blocker). Let it finish and open this again.", systemImage: "clock")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if snapshots.isEmpty {
                // Both nothings want different sentences: no drive attached is
                // a different problem from a drive with nothing on it.
                ContentUnavailableView(
                    store.reachablePaths.isEmpty ? "No drive connected" : "No snapshot to go back to",
                    systemImage: store.reachablePaths.isEmpty ? "externaldrive.badge.questionmark" : "clock.badge.exclamationmark",
                    description: Text(
                        store.reachablePaths.isEmpty
                            ? "Connect a drive that holds this archive and its snapshots will be listed here."
                            : "The connected drives carry no snapshot this app can read back. \u{201C}Back up now\u{201D} writes one."
                    )
                )
                .frame(maxHeight: 180)
            } else {
                List(snapshots, selection: Binding(
                    get: { choice?.id },
                    set: { id in choice = snapshots.first { $0.id == id } }
                )) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Formatters.relative(entry.snapshot.createdAt))
                            .font(.callout.weight(.medium))
                        Text("\(Formatters.count(entry.contents.assetCount, "photo")) · \(entry.contents.tablesWithRows) kinds of record · on \(entry.driveName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(entry.id)
                    .contentShape(Rectangle())
                    .onTapGesture { choice = entry }
                }
                .frame(minHeight: 160)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Restore…") { confirming = choice }
                    .buttonStyle(.borderedProminent)
                    .disabled(choice == nil || store.catalogRestoreBlocker != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .confirmationDialog(
            "Replace the catalog with this snapshot?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                if let confirming { store.restoreCatalog(from: confirming.snapshot) }
                confirming = nil
                dismiss()
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            if let confirming {
                Text("The archive currently records \(Formatters.count(store.countedPhotoTotal, "photo")); this snapshot records \(Formatters.count(confirming.contents.assetCount, "photo")) and was taken \(Formatters.relative(confirming.snapshot.createdAt)). Anything imported since then will not be in it, and the photos themselves are untouched either way.")
            }
        }
    }
}
