import SwiftUI

/// What the app means by its own words.
///
/// The screens explain themselves as they go, and mostly that is enough — but
/// three ideas are load-bearing and none of them is obvious from a screen that
/// assumes you have already met it: a *target* is a device rather than a
/// folder, *residency* is one place rather than a list of places, and *safe*
/// is a claim about how many copies exist, which is not the same claim as
/// having read them. Somebody who has not met those reads the same numbers and
/// draws different conclusions.
///
/// So this is the missing Help menu, and it is deliberately short. It is not a
/// manual: everything here is a thing the app will otherwise be misunderstood
/// about, and nothing here is a description of a button.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Topic: Identifiable {
        /// The title, not a fresh UUID: a `let id = UUID()` on a value type
        /// stored in a view is a new identity every time the view is
        /// re-initialised, so `ForEach` rebuilds the whole list on each redraw.
        var id: String { title }
        let symbol: String
        let title: String
        let body: String
    }

    private static let topics: [Topic] = [
        Topic(
            symbol: "externaldrive.connected.to.line.below",
            title: "A target is a device, not a folder",
            body: """
            A target is somewhere a whole copy of your archive lives: either this Mac, \
            holding its copy in a folder you pick, or an external drive. Two folders on \
            the same disk are one target, not two, and the app refuses to register them \
            as two — a copy in each does not survive that disk failing, so counting them \
            as two copies would be a lie about how safe you are.

            A drive that is unplugged has not stopped being a target. It still holds what \
            it held; work for it queues up and runs when you next connect it.
            """
        ),
        Topic(
            symbol: "map",
            title: "Every photo lives in exactly one place",
            body: """
            A photo's residency is Local, Apple's cloud, or Google's — one of them, never \
            two. Being in two at once is the state you are paying twice for, so the app \
            treats it as something to review rather than as normal.

            Residency is where a photo lives. Presence is where copies of it happen to be. \
            They are different, and during a move they legitimately disagree; outside one, \
            a disagreement is a finding.
            """
        ),
        Topic(
            symbol: "checkmark.shield",
            title: "\u{201C}Safe\u{201D} means enough copies exist",
            body: """
            The big number on Overview is answering one question: do enough copies of this \
            photo exist to satisfy the policy you set? That is what the outer ring shows.

            Whether anybody has read those copies back is a second, weaker fact, and it has \
            its own ring inside the first. A freshly imported archive has every copy written \
            and almost none read — which is normal, and is why the app does not let a full \
            green circle imply more than it checked. Reading is the only thing that finds a \
            file quietly decaying on disk; comparing catalog entries never can.
            """
        ),
        Topic(
            symbol: "tray.and.arrow.down",
            title: "Sources are only ever read",
            body: """
            Pointing the app at a folder, a Photos library or a Google download copies what \
            it finds into the archive and leaves the original exactly as it was. Nothing is \
            moved, renamed or deleted at a source, ever.

            Photos arriving from anywhere the app does not manage land on this Mac first, so \
            they are safe before any drive is plugged in. That working copy is released only \
            once your own drives hold the photo and have read it back.
            """
        ),
        Topic(
            symbol: "hand.raised",
            title: "Nothing is fixed behind your back",
            body: """
            Findings are shown and never quietly resolved, because every fix here moves or \
            forgets somebody's photographs. A wrong capture date is left where the file \
            claims rather than corrected to a guess. Duplicates are listed, not merged.

            The catalog on this Mac is the authority for all of it — metadata, residency, \
            history — and verified snapshots of it are written to your drives, so losing the \
            Mac does not lose the record.
            """
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("How this app thinks")
                    .font(.title2)
                    .bold()
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Five ideas the rest of the app assumes you have met.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    ForEach(Self.topics) { topic in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: topic.symbol)
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .frame(width: 30)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(topic.title)
                                    .font(.headline)
                                Text(topic.body)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("If something goes wrong")
                            .font(.headline)
                        Text("File \u{2192} Save a Diagnostics Report writes what the app "
                             + "currently believes to a text file: counts, states and timings, "
                             + "with drive names and paths taken out. It is meant to be sent to "
                             + "somebody helping you.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 560)
    }
}
