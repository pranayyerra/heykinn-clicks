import SwiftUI

/// One place a copy of the archive can live: a registered target, or somewhere
/// that could become one.
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
    /// Nil for places that are not targets yet.
    var target: ReplicationTarget?

    var holdsACopy: Bool {
        switch state {
        case .empty: return false
        case .complete, .filling, .damaged: return true
        }
    }

    var tint: Color {
        switch state {
        case .complete: return .green
        case .filling: return .orange
        case .damaged: return .red
        case .empty: return .secondary
        }
    }
}

/// The archive at the centre, and every place a copy of it lives around it.
///
/// The question this screen exists to answer is "where are my copies?", and a
/// list of device cards never quite says it: the cards describe drives, and the
/// user is asking about the *archive*. Drawing the archive once, with a line to
/// each place holding it, states the relationship the model is built on —
/// including the places holding nothing, which a list of targets leaves out
/// entirely.
struct ArchiveMapView: View {
    let photoCount: Int
    let fileCount: Int
    let byteCount: Int64
    let places: [ArchivePlace]
    @Binding var selection: UUID?
    var onActivateEmpty: (ArchivePlace) -> Void

    private let nodeSize = CGSize(width: 190, height: 74)
    private let hubSize = CGSize(width: 190, height: 96)

    var body: some View {
        GeometryReader { proxy in
            let centre = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let positions = layout(in: proxy.size, centre: centre)

            ZStack {
                ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                    connector(from: centre, to: positions[index], place: place)
                }
                hub
                    .frame(width: hubSize.width, height: hubSize.height)
                    .position(centre)
                ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                    node(place)
                        .frame(width: nodeSize.width, height: nodeSize.height)
                        .position(positions[index])
                }
            }
        }
        .frame(height: mapHeight)
    }

    private var mapHeight: CGFloat {
        places.count <= 2 ? 210 : 330
    }

    /// Two places read best facing each other across the hub; more than two go
    /// round it. Either way the hub stays in the middle, because the archive is
    /// the thing they all hold.
    ///
    /// The ring is an ellipse, not a circle: the boxes are far wider than they
    /// are tall, so one radius taken from the smaller dimension puts nodes on
    /// top of the hub. Each axis is sized against the boxes it has to keep
    /// apart, then clamped to what the view actually has room for.
    private func layout(in size: CGSize, centre: CGPoint) -> [CGPoint] {
        guard !places.isEmpty else { return [] }

        let gap: CGFloat = 28
        let maxX = max(size.width / 2 - nodeSize.width / 2 - 4, 0)
        let maxY = max(size.height / 2 - nodeSize.height / 2 - 4, 0)
        let radiusX = min((hubSize.width + nodeSize.width) / 2 + gap, maxX)
        let radiusY = min((hubSize.height + nodeSize.height) / 2 + gap, maxY)

        if places.count <= 2 {
            return places.indices.map { index in
                CGPoint(x: centre.x + (index == 0 ? -radiusX : radiusX), y: centre.y)
            }
        }
        return places.indices.map { index in
            let angle = (2 * .pi * Double(index) / Double(places.count)) - .pi / 2
            return CGPoint(
                x: centre.x + radiusX * CGFloat(cos(angle)),
                y: centre.y + radiusY * CGFloat(sin(angle))
            )
        }
    }

    /// The line carries the state: solid where a complete copy sits, dashed
    /// while one is still arriving, faint where there is no copy at all.
    private func connector(from centre: CGPoint, to point: CGPoint, place: ArchivePlace) -> some View {
        Path { path in
            path.move(to: centre)
            path.addLine(to: point)
        }
        .stroke(
            place.tint.opacity(place.isReachable ? 0.85 : 0.35),
            style: StrokeStyle(
                lineWidth: place.holdsACopy ? 3 : 1.5,
                lineCap: .round,
                dash: dash(for: place)
            )
        )
    }

    private func dash(for place: ArchivePlace) -> [CGFloat] {
        switch place.state {
        case .complete: return []
        case .filling, .damaged: return [7, 5]
        case .empty: return [3, 6]
        }
    }

    private var hub: some View {
        VStack(spacing: 3) {
            Image(systemName: "photo.stack")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("\(photoCount.formatted()) photos")
                .font(.headline)
                .monospacedDigit()
            Text("\(Formatters.bytes.string(fromByteCount: byteCount)) · \(fileCount.formatted()) files")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1.5)
        )
        .help("Every photo in the catalog. Files differ because a Live Photo is a still and a movie on disk, but one photo.")
    }

    private func node(_ place: ArchivePlace) -> some View {
        let isSelected = selection == place.id
        return Button {
            if place.target == nil {
                onActivateEmpty(place)
            } else {
                selection = isSelected ? nil : place.id
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: place.symbol)
                    .font(.title3)
                    .foregroundStyle(place.holdsACopy ? place.tint : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(place.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // Opaque, so the connector ends *at* the node rather than showing
            // through it and reading as a line that carries on past.
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(place.holdsACopy ? place.tint.opacity(0.12) : Color.secondary.opacity(0.08))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? Color.accentColor : place.tint.opacity(place.holdsACopy ? 0.35 : 0.2),
                        style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: place.holdsACopy ? [] : [4, 3])
                    )
            )
        }
        .buttonStyle(.plain)
        .help(place.target == nil ? "Not holding a copy — click to add one here" : "Click for detail")
    }
}
