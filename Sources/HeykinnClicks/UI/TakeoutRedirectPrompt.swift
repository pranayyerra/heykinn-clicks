import SwiftUI

/// Shown when somebody picks a Google export as if it were a folder of photos.
///
/// It is the same content either way, so the app cannot refuse on the grounds
/// that it is wrong — only on the grounds that it is expensive, and the size of
/// the difference is the whole argument. Said in what it costs the reader
/// rather than in the app's own words for its internals: they do not need to
/// know what a replica is to understand "one file, or fifty thousand".
struct TakeoutRedirectPrompt: View {
    let redirect: TakeoutRedirect
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("That looks like a Google Photos download", systemImage: "shippingbox")
                .font(.title3)
                .bold()

            Text("\(redirect.name) is one of the exports Google sends you, not an ordinary folder of pictures.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text("The app can bring it in whole: your drives keep the download's own files, and one check confirms everything inside them. Adding it as a folder instead copies every photo separately, so a drive ends up holding tens of thousands of files where a handful would have done — and every future check has to read them all.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                let url = redirect.url
                let access = redirect.access
                store.takeoutRedirect = nil
                store.scanForTakeout(rootURL: url, targetID: nil, retaining: access)
                dismiss()
            } label: {
                Label("Bring it in as a download", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)

            HStack {
                Spacer()
                Button("Cancel") {
                    store.takeoutRedirect = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
