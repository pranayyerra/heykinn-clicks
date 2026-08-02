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
