import SwiftUI
import AppKit

enum Formatters {
    static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    static let monthYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    static func relative(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

extension ResidencyDomain {
    var tint: Color {
        switch self {
        case .local: return .blue
        case .appleCloud: return .gray
        case .googleCloud: return .orange
        }
    }

    var symbolName: String {
        switch self {
        case .local: return "externaldrive"
        case .appleCloud: return "applelogo"
        case .googleCloud: return "cloud"
        }
    }
}

extension ProtectionState {
    var tint: Color {
        switch self {
        case .fullyReplicated: return .green
        case .replicatedToOneDrive: return .yellow
        case .stagedOnly: return .orange
        case .driftDetected: return .red
        case .awaitingFirstCheck: return .teal
        case .verificationOverdue: return .purple
        case .notApplicable: return .secondary.opacity(0.5)
        }
    }

    var symbolName: String {
        switch self {
        case .fullyReplicated: return "checkmark.shield.fill"
        case .replicatedToOneDrive: return "shield.lefthalf.filled"
        case .stagedOnly: return "tray.fill"
        case .driftDetected: return "exclamationmark.triangle.fill"
        case .awaitingFirstCheck: return "clock.badge.questionmark"
        case .verificationOverdue: return "clock.badge.exclamationmark"
        case .notApplicable: return "minus"
        }
    }
}

struct ResidencyBadge: View {
    let domain: ResidencyDomain

    var body: some View {
        Label(domain.displayName, systemImage: domain.symbolName)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(domain.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(domain.tint)
    }
}

struct ProtectionBadge: View {
    let state: ProtectionState

    var body: some View {
        Label(state.displayName, systemImage: state.symbolName)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(state.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(state.tint)
    }
}

/// Loads a staged thumbnail off the main thread; falls back to a kind icon
/// for assets with no local bytes (cloud-resident).
struct AssetThumbnailView: View {
    let asset: Asset
    /// Off for tiny thumbnails (duplicate rows), where a video preview would
    /// be noise rather than help.
    var allowsHoverPreview: Bool = true
    @EnvironmentObject private var store: AppStore
    @State private var image: NSImage?
    @StateObject private var preview = HoverPreviewController()

    /// The moving file behind this cell: a video plays itself, a Live Photo
    /// plays its motion half. Nil when nothing is reachable — with the drive
    /// unplugged the still simply stays put.
    private var previewURL: URL? {
        guard allowsHoverPreview else { return nil }
        switch asset.kind {
        case .video:
            return store.localFileURL(for: asset)
        case .livePhoto:
            return store.livePhotoMotion(for: asset).flatMap { store.localFileURL(for: $0) }
        case .photo, .unknown:
            return nil
        }
    }

    private var placeholderSymbol: String {
        switch asset.kind {
        case .video: return "video"
        case .livePhoto: return "livephoto"
        case .photo, .unknown: return "photo"
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
            if let player = preview.player {
                HoverPreviewLayer(player: player)
                    .transition(.opacity)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                // The placeholder names the kind too, so a Live Photo is
                // identifiable before its thumbnail has loaded.
                Image(systemName: placeholderSymbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            if asset.kind == .livePhoto && image != nil && preview.player == nil {
                VStack {
                    HStack {
                        // Apple Photos marks a Live Photo with a glyph-and-word
                        // badge in this corner; matching it keeps the meaning
                        // obvious rather than relying on an unlabelled symbol.
                        HStack(spacing: 3) {
                            Image(systemName: "livephoto")
                            Text("LIVE")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(5)
                        Spacer()
                    }
                    Spacer()
                }
            }
            // Once videos have real frames they look like stills, so mark them.
            if asset.kind == .video && image != nil && preview.player == nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(5)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { inside in
            if inside {
                preview.hoverBegan(url: previewURL)
            } else {
                preview.hoverEnded()
            }
        }
        .onDisappear { preview.hoverEnded() }
        .animation(.easeInOut(duration: 0.15), value: preview.player == nil)
        .task(id: asset.id) {
            // A cached thumbnail is applied without a hop, so a cell scrolling
            // back into view shows immediately instead of flashing a placeholder.
            if let cached = store.thumbnails.cachedInMemory(asset.id) {
                image = cached
                return
            }
            image = await store.thumbnail(for: asset)
        }
    }
}

/// A population drawn as one proportional bar. Sizes speak before numbers do:
/// a mostly-green bar reads as "safe" without the user parsing a table.
struct SegmentedBar: View {
    struct Segment: Identifiable, Equatable {
        var label: String
        var count: Int
        var color: Color

        var id: String { label }
    }

    let segments: [Segment]
    var height: CGFloat = 12

    private var total: Int { segments.reduce(0) { $0 + $1.count } }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                if total == 0 {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                } else {
                    ForEach(segments.filter { $0.count > 0 }) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: proxy.size.width * CGFloat(segment.count) / CGFloat(total))
                            .help("\(segment.label): \(segment.count.formatted())")
                    }
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .animation(.easeInOut(duration: 0.25), value: segments)
    }
}

/// Names the colours in a `SegmentedBar` or `ProtectionDonut`. Empty buckets
/// are dropped: a legend line reading "0" is noise, not information.
struct SegmentLegend: View {
    let segments: [SegmentedBar.Segment]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(segments.filter { $0.count > 0 }) { segment in
                HStack(spacing: 7) {
                    Circle()
                        .fill(segment.color)
                        .frame(width: 8, height: 8)
                    Text(segment.label)
                        .font(.callout)
                    Spacer(minLength: 12)
                    Text(segment.count.formatted())
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The same buckets as a ring, with the single number that matters in the
/// middle. Used once, at the top of the app, to answer "are my photos safe?".
struct ProtectionDonut: View {
    private struct Arc: Identifiable {
        let id: Int
        let start: CGFloat
        let end: CGFloat
        let color: Color
    }

    let segments: [SegmentedBar.Segment]
    let headline: String
    let caption: String
    var lineWidth: CGFloat = 16
    var diameter: CGFloat = 140

    private var total: Int { segments.reduce(0) { $0 + $1.count } }

    private var arcs: [Arc] {
        guard total > 0 else { return [] }
        var result: [Arc] = []
        var cursor: CGFloat = 0
        for (index, segment) in segments.enumerated() where segment.count > 0 {
            let fraction = CGFloat(segment.count) / CGFloat(total)
            result.append(Arc(id: index, start: cursor, end: min(cursor + fraction, 1), color: segment.color))
            cursor += fraction
        }
        return result
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: lineWidth)
            ForEach(arcs) { arc in
                Circle()
                    .trim(from: arc.start, to: arc.end)
                    .stroke(arc.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 1) {
                Text(headline)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(lineWidth + 8)
            .multilineTextAlignment(.center)
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeInOut(duration: 0.3), value: segments)
    }
}

/// One number worth acting on, sized to be read across the room and clickable
/// straight through to the screen that resolves it.
struct StatTile: View {
    let symbol: String
    let value: String
    let title: String
    let tint: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
            .padding(12)
            .background(tint.opacity(isHovering ? 0.20 : 0.10), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}

/// A titled panel. Lighter than `GroupBox` so a screen of them reads as a
/// dashboard rather than as a preferences window.
struct CardBox<Content: View>: View {
    let title: String
    var systemImage: String?
    var accessory: AnyView?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label {
                    Text(title)
                        .font(.headline)
                } icon: {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let accessory {
                    accessory
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Free/used space for a mounted volume. Nil when the volume is gone, which is
/// the normal case for a drive that has just been unplugged.
enum VolumeCapacity {
    static func read(_ url: URL) -> (total: Int64, available: Int64)? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        // The "important usage" figure is the honest one — it accounts for
        // purgeable space — but it is unavailable on plenty of external
        // filesystems, where it comes back nil or zero rather than as an error.
        let important = values.volumeAvailableCapacityForImportantUsage ?? 0
        let plain = Int64(values.volumeAvailableCapacity ?? 0)
        let available = important > 0 ? important : plain
        guard available > 0 else { return nil }
        return (Int64(total), available)
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }
}
