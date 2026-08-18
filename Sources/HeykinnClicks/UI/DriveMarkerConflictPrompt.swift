import SwiftUI

/// Shown when a drive being registered already names an archive this one does
/// not know.
///
/// **Both answers are reasonable, which is why this asks rather than refuses.**
/// A drive can genuinely carry a marker this archive should take over — a target
/// that was forgotten here leaves one behind, and so does an archive that no
/// longer exists. It can equally be another archive's drive, plugged in by
/// accident, in which case taking it costs that archive the ability to
/// recognise its own disk. Nothing on the drive distinguishes those two, and the
/// person holding it is the only one who can.
///
/// The default is the safe one: cancel, and nothing on the drive is touched.
struct DriveMarkerConflictPrompt: View {
    let conflict: DriveMarkerConflict
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Make \(conflict.name) yours?", systemImage: "externaldrive.badge.exclamationmark")
                .font(.title3)
                .bold()

            Text("This drive is somebody else's. The app leaves a small ID file on every drive it uses, and this one carries an ID it does not recognise.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text("Making it yours replaces that ID. Nothing on the drive is deleted and no photo is moved — but the other one stops recognising this drive, and can no longer tell you which of its photos are on it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Expected if this was your drive and you forgot it here earlier, or if the other one is something you no longer use.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") {
                    store.markerConflict = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Make it mine") {
                    store.takeOverDrive(conflict)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 460)
    }
}
