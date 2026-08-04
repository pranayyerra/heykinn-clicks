import SwiftUI

/// Shown when an unmanaged external volume mounts: offer to adopt it as
/// managed local storage, or just sweep it for Takeout archives.
struct DriveConnectPrompt: View {
    let volume: VolumeInfo
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private var canRegister: Bool { store.targets.count < 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(volume.name, systemImage: "externaldrive.badge.plus")
                .font(.title3)
                .bold()
            Text("An external drive was connected (\(volume.url.path)). What should it be?")
                .font(.callout)

            VStack(alignment: .leading, spacing: 10) {
                if canRegister {
                    Button {
                        store.registerVolumeTarget(volume: volume, name: volume.name)
                        store.connectPrompt = nil
                        dismiss()
                    } label: {
                        Label("Use as managed local storage", systemImage: "externaldrive.fill.badge.checkmark")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Registers it as one of the two Local-domain replica targets: a marker file anchors its identity, and all Local assets queue for replication to it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Both managed drive slots are in use, so this drive can't become local storage — but it can still be scanned.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    store.scanForTakeout(rootURL: volume.url, targetID: nil)
                    store.connectPrompt = nil
                    dismiss()
                } label: {
                    Label("Scan it for Google Takeout archives", systemImage: "shippingbox")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            HStack {
                Button("Don't ask again for this drive") {
                    store.ignoreVolumePermanently(volume)
                    dismiss()
                }
                Spacer()
                Button("Not now") {
                    store.connectPrompt = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
