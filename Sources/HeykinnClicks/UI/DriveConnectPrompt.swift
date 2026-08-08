import SwiftUI

/// Shown when an unmanaged external volume mounts: offer to adopt it as
/// managed local storage, or just sweep it for Takeout archives.
///
/// Every answer here can be remembered against the disk's identity, so the
/// question is asked once rather than at every mount. The previous version
/// could only remember one answer — "never ask again" — which meant somebody
/// who chose "scan it" answered the same prompt forever, and somebody who
/// chose "never" had no way back: the key went into preferences and no screen
/// could remove it. Remembering and revoking are one feature, and the other
/// half of it is Settings → Access.
struct DriveConnectPrompt: View {
    let volume: VolumeInfo
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    /// On by default, because being asked twice about the same disk is the
    /// complaint this exists to answer. Unchecking is the escape, and it means
    /// exactly what it says: the choice happens and is not written down.
    @AppStorage("rememberVolumeChoiceDefault") private var remember = true

    /// There is no cap. `desiredCopies` says how many devices hold each photo,
    /// not how many devices may exist — a sixth drive is another place copies
    /// can land, and refusing it because the policy asks for two copies was
    /// the two ideas being confused.
    private var canRegister: Bool { true }

    private func choose(_ decision: VolumeDecision) {
        store.decide(decision, for: volume, remember: remember)
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(volume.name, systemImage: "externaldrive.badge.plus")
                .font(.title3)
                .bold()
            Text("A drive was connected (\(volume.url.path)). What should it be?")
                .font(.callout)

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    choose(.manage)
                } label: {
                    Label("Use as storage for the archive", systemImage: "externaldrive.fill.badge.checkmark")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                // Says what actually happens now: it becomes another place
                // copies can land, and it takes a share rather than a
                // duplicate of the whole archive.
                Text("Makes it one of the devices your photos can be kept on. A marker file anchors its identity, so it is recognised wherever it is plugged in. Nothing is copied to it yet: a group that works out its own drives will use this one as soon as it asks for more copies than it has drives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    choose(.scan)
                } label: {
                    Label("Search it for Google downloads", systemImage: "shippingbox")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            Toggle("Remember this for \(volume.name)", isOn: $remember)
                .font(.callout)
            Text(remember
                 ? "This drive will not be asked about again. You can change or undo it in Settings → Access."
                 : "You will be asked again the next time this drive is connected.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Leave it alone") { choose(.ignore) }
                Spacer()
                Button("Not now") {
                    // Deliberately not a decision: nothing is recorded even
                    // with the box ticked, because "not now" is the answer
                    // "ask me later" and remembering it would be the opposite.
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
