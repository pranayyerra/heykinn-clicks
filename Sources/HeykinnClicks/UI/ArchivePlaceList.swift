import SwiftUI

/// One place a copy of the archive lives, or could.
///
/// Covers both a registered device and a slot that is not one yet, because
/// "nothing is here" is as much of an answer as "everything is here" — a place
/// left out of the list cannot be noticed as missing.
struct ArchivePlace: Identifiable {
    enum State: Equatable {
        /// Registered and holding every photo the archive has.
        case complete
        /// Registered, still filling — or holding damaged copies.
        case filling(photosHeld: Int, photosExpected: Int)
        case damaged(count: Int)
        /// Not a target yet. The slot is drawn empty rather than hidden, so a
        /// place that holds nothing is visibly a place that holds nothing.
        case empty
    }

    let id: UUID
    var name: String
    var symbol: String
    var state: State
    var isReachable: Bool
    var detail: String
    /// What it actually holds, and how much of that has been proven.
    var heldPhotos: Int = 0
    var heldBytes: Int64 = 0
    var neverCheckedPhotos: Int = 0
    /// Nil for places that are not targets yet.
    var target: ReplicationTarget?

    var holdsACopy: Bool {
        switch state {
        case .empty: return false
        case .complete, .filling, .damaged: return true
        }
    }
}

/// The archive at the centre, and every place a copy of it lives around it.
///
/// The question this screen exists to answer is "where are my copies?", and a
/// list of device cards never quite says it: the cards describe drives, and the
/// user is asking about the *archive*. Drawing the archive once, with a line to
/// each place holding it, states the relationship the model is built on —

/// Everywhere a copy of the archive lives, one row each.
///
/// Replaced a hub-and-spoke diagram that drew the same places around a centre
/// node. The picture said one true thing well — these are copies of one archive
/// rather than three archives — and then had nowhere to put what each place
/// actually holds, which is the question the screen exists to answer. A spoke
/// has room for a name and a state; a row has room for the numbers.
struct ArchivePlaceList<Detail: View>: View {
    var places: [ArchivePlace]
    @Binding var selection: UUID?
    var onActivateEmpty: (ArchivePlace) -> Void
    /// What a place shows when it is opened, drawn inside the row rather than
    /// under the list. The same pattern the groups use: the row is the header,
    /// so the detail does not have to repeat the name to make sense.
    @ViewBuilder var detail: (ArchivePlace) -> Detail

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                if index > 0 { Divider() }
                row(place)
                if selection == place.id {
                    detail(place)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
            }
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func row(_ place: ArchivePlace) -> some View {
        Button {
            if place.target == nil {
                onActivateEmpty(place)
            } else {
                // Toggles. A row that opens and will not close is a row that
                // has to be closed by opening something else, which is not
                // closing it — it is moving the problem.
                selection = selection == place.id ? nil : place.id
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: place.symbol)
                    .foregroundStyle(place.holdsACopy ? Color.green : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .fontWeight(selection == place.id ? .semibold : .regular)
                    Text(holdings(place))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(place.target == nil ? "not set up"
                     : place.isReachable ? "connected" : "away")
                    .font(.caption)
                    .foregroundStyle(place.isReachable ? Color.green : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selection == place.id ? Color.accentColor.opacity(0.12) : .clear)
    }

    /// What the place holds, and how much of that has been read back.
    ///
    /// Held and proven are separate sentences on purpose. They were one number
    /// before, which let a drive nothing had ever been verified on look exactly
    /// like one where everything had.
    private func holdings(_ place: ArchivePlace) -> String {
        // A slot that is not a device yet has no holdings to describe; its
        // detail is the invitation to make it one.
        guard place.target != nil else { return place.detail }
        // A registered device holding nothing says so. Its `detail` reports
        // whether it is plugged in, which this row already shows on the right —
        // and "Connected / connected" twice on one line answers a question
        // nobody asked while leaving the real one unanswered.
        guard place.heldPhotos > 0 else {
            return "Holds nothing — no group needs enough copies to use it"
        }

        var parts = [
            "\(place.heldPhotos.formatted()) photos",
            Formatters.bytes.string(fromByteCount: place.heldBytes),
        ]
        switch place.state {
        case .damaged(let count):
            parts.append("\(count.formatted()) no longer match")
        case .filling(let held, let expected):
            parts.append("\((expected - held).formatted()) still to arrive")
        case .complete, .empty:
            parts.append(
                place.neverCheckedPhotos == 0
                    ? "all read back"
                    : "\(place.neverCheckedPhotos.formatted()) never read back"
            )
        }
        return parts.joined(separator: " · ")
    }
}
