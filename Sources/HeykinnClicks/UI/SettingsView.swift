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
                Toggle("Sync a managed drive when it connects", isOn: $store.autoSyncOnConnect)
                Text("Plugging a drive in starts working through its queue — copies it is missing, checks it owes — without waiting to be asked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Handle Google exports found on a drive", isOn: $store.autoManageTakeout)
                Text("Finds exports on a connected drive, unpacks and imports what is new, and recognises copies the drive already holds instead of copying them again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SafetySettings: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section("How many copies") {
                Label(
                    "Every Local photo is kept on \(store.redundancyPolicy.description). A photo counts as safe once that many drives hold it.",
                    systemImage: "square.stack.3d.up"
                )
                .font(.callout)
            }
            Section("Checking for damage") {
                Text("Checking re-reads files already on a drive and confirms they are still byte-for-byte what was imported. It catches silent corruption — bit rot, a bad cable, an accidental edit — while the other drive still holds a good copy to restore from. It reads every byte, so it runs in batches rather than all at once, from Drives & Health.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Catalog backup") {
                Text("The media survives on the drives, but residency, replica state, duplicate grouping, and import history exist only in the catalog. Verified snapshots are written to each connected drive so losing the Mac does not lose the metadata.")
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
                        .disabled(store.connectedMounts.isEmpty)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}
