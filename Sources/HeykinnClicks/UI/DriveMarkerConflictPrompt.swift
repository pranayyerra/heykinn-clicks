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
            Label("\(conflict.name) already belongs to an archive", systemImage: "externaldrive.badge.exclamationmark")
                .font(.title3)
                .bold()

            Text("This drive is already being used by another Heykinn Clicks archive — one this app does not recognise. Each archive leaves a small ID file on its drives so it knows which ones are its own.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text("If you use it here, that ID is replaced. Nothing on the drive is deleted and no photo is moved — but the other archive will stop recognising this drive, and will no longer be able to tell you which of its copies are on it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("This is expected if you forgot this drive here earlier, or if the other archive is one you no longer use — a test archive, or one on a device you have replaced.")
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

                Button("Use this drive here") {
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
