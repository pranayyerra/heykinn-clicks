import SwiftUI

/// Shown when somebody imports from a drive the app does not manage, while a
/// target slot is still free.
///
/// Not a warning — both answers are reasonable, and the drive may genuinely be
/// something they are about to give back. It exists because the two answers
/// cost wildly different amounts and the difference is invisible: one copies
/// every file onto the Mac and keeps it there, the other copies nothing. And
/// the choice is only available now. Once the import has run, the app has
/// decided where those bytes live and re-deciding means reading all of them
/// again.
struct UnmanagedSourcePrompt: View {
    let offer: UnmanagedSourceOffer
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("That folder is on \(offer.name)", systemImage: "externaldrive.badge.questionmark")
                .font(.title3)
                .bold()

            Text("This drive is not one of the places the app keeps your archive, so it will copy everything you import onto this Mac and keep it there.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text("If you plan to keep this drive, making it one of your archive's drives first is free: the app records the photos exactly where they already are instead of copying them anywhere. Your files stay where they are and keep their own names either way.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    store.registerAndImport(offer)
                    dismiss()
                } label: {
                    Label("Keep this drive, and add its photos", systemImage: "externaldrive.fill.badge.checkmark")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    let urls = offer.urls
                    store.unmanagedSourceOffer = nil
                    store.importFolders(urls, offeringRegistration: false)
                    dismiss()
                } label: {
                    Label("Just copy the photos in", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Button("Don't ask again for this drive") {
                    let urls = offer.urls
                    store.ignoreVolumePermanently(offer.volume)
                    store.unmanagedSourceOffer = nil
                    store.importFolders(urls, offeringRegistration: false)
                    dismiss()
                }
                Spacer()
                Button("Cancel") {
                    store.unmanagedSourceOffer = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
