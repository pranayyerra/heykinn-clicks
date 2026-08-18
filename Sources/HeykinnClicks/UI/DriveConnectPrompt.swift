import SwiftUI

/// Shown when a drive nobody has claimed is plugged in.
///
/// **One question, one button.** This used to offer three answers, a "remember
/// this" toggle and a "not now" — five things, for a drive somebody had just
/// plugged in. Most of them were not the same kind of thing as each other:
/// keeping photos on a drive is a lasting fact about whose it is, while looking
/// for a Google download on it is something you do once. Mixing an action into
/// a question about ownership is what made the list long.
///
/// So the action left. Getting photos off any drive already lives under Add
/// photos, works on a drive this app has never seen, and needs no registration
/// — checked, not assumed.
///
/// **Closing means no, and it is remembered.** There is no toggle because the
/// question does not come back: whose a drive is does not change on Tuesday.
/// Being asked the same thing at every mount is worse than having to turn it on
/// later, and later is one screen away.
///
/// This never appears for a drive that already belongs to somebody else. The
/// app can see that from the ID file, so there is nothing to ask — see
/// `AppStore.driveBelongsToSomebodyElse`.
struct DriveConnectPrompt: View {
    let volume: VolumeInfo
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var isDrivePickerPresented = false
    /// Whether the one button was pressed, so closing can mean what it says.
    @State private var accepted = false

    private func useIt() {
        // Sandboxed, the app cannot reach a volume nobody handed it. The panel
        // is how somebody hands it over, and it has to be the same disk.
        if TargetBookmarks.isSandboxed {
            isDrivePickerPresented = true
            return
        }
        accepted = true
        _ = store.decide(.manage, for: volume, remember: true)
        dismiss()
    }

    /// Closing the window is the other answer, and it is a real one.
    private func declineIfUnanswered() {
        guard !accepted else { return }
        _ = store.decide(.ignore, for: volume, remember: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(volume.name, systemImage: "externaldrive.badge.plus")
                    .font(.title3)
                    .bold()
                Spacer()
                // Closing is the other answer, so there has to be a way to
                // close. Written as a close control rather than a second
                // button on purpose: this is one decision with one action, and
                // a matching pair would put "no" on the same footing as "yes"
                // when the whole point is that most drives plugged in are ones
                // somebody means to use.
                //
                // It carries the escape key, which is what somebody reaches
                // for. Without it the panel had no way out at all — found by
                // opening it, not by reading it.
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .imageScale(.medium)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Do not use this drive")
                .accessibilityLabel("Do not use this drive")
            }

            Text("Use \(volume.name) for your photos?")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text("Copies of your photos will be kept on it, and read back to check they arrived. Nothing on it is changed, and nothing is copied yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Close this and it will not be used, and you will not be asked again. You can turn it on later under Keep safe.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Yes, use it") { useIt() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        // Escape closes it. `.keyboardShortcut(.cancelAction)` on the close
        // control did not take — tried, and the key did nothing — because a
        // plain-styled button is not what that modifier is looking for. This is
        // the macOS way of saying the same thing, and it works on the panel
        // rather than on any button in it.
        .onExitCommand { dismiss() }
        .onDisappear { declineIfUnanswered() }
        .fileImporter(
            isPresented: $isDrivePickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            guard let access = SecurityScopedAccess(url: url) else {
                store.lastError = "macOS did not grant access to \(url.lastPathComponent). Choose \(volume.name) itself and try again."
                return
            }
            guard let chosen = store.userSelectedVolume(at: url, matching: volume) else { return }
            accepted = true
            _ = withExtendedLifetime(access) {
                store.decide(.manage, for: chosen, remember: true, retaining: access)
            }
            dismiss()
        }
    }
}
