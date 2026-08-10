import SwiftUI
import AppKit

enum Formatters {

    /// "A, B and C" — the way a person lists things.
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }


    /// "1 file", "12 files" — never "12 file(s)".
    ///
    /// The parenthesised plural was in twenty-odd strings across the app and
    /// the audit log, and it reads as a template somebody forgot to finish. It
    /// also gets it wrong in the only case that matters: "1 file(s)" is exactly
    /// where a person notices.
    static func count(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        let word = number == 1 ? singular : (plural ?? singular + "s")
        return "\(number.formatted()) \(word)"
    }

    /// The same, for a number already spelled out elsewhere in the sentence.
    static func pluralise(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        number == 1 ? singular : (plural ?? singular + "s")
    }

    /// "one copy", "two copies", "3 copies" — how a number of copies is said
    /// wherever the app explains what a source asks for.
    ///
    /// Words for the two numbers that appear in ordinary sentences, digits
    /// beyond them. This used to be `LocalRedundancyPolicy.description`, back
    /// when there was a single number for the whole archive; the phrasing was
    /// worth keeping when the number moved onto each source.
    static func copies(_ count: Int) -> String {
        switch count {
        case 1: return "one copy"
        case 2: return "two copies"
        default: return "\(count) copies"
        }
    }

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

    /// A day the provider recorded, printed as the provider recorded it.
    ///
    /// Google timestamps an album in UTC and prints the UTC day beside it
    /// (`"Jul 15, 2015, 8:29:47 PM UTC"`). Rendering that instant in the
    /// viewer's timezone moves the day: an album titled "Wednesday night in
    /// Northgate" came out as Thursday 16 July, because 8:29 PM UTC is already
    /// the small hours anywhere far enough east. Worse, the same album would
    /// read differently on two machines.
    ///
    /// So a provider's day is shown as the provider's day, in step with the
    /// timeline's promise to show dates where the files claim, unchanged.
    static let providerDateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(identifier: "UTC")
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

    /// A gap between two dates, in its own right rather than relative to now.
    static func span(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.year, .month, .day]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter.string(from: abs(interval)) ?? ""
    }
}

extension ImpossibleCaptureDate {
    /// Worded once, so the timeline header and the asset detail cannot drift
    /// apart about what is wrong or about what the app did with it.
    static let headline = "Dated after it was imported"
    static let symbolName = "calendar.badge.exclamationmark"

    /// The finding, with both dates named so the user can check it. Worded
    /// without naming a source — the row above already says which one — so it
    /// stays true whether the date came from EXIF or from a sidecar.
    var finding: String {
        """
        The recorded capture date is \(Formatters.dateTime.string(from: claimed)), but \
        this archive imported the file on \(Formatters.dateTime.string(from: imported)) — \
        \(Formatters.span(ahead)) earlier. A photograph cannot be taken after it has been \
        copied, so the camera's clock was wrong. A clock that was never set is the usual \
        cause, and when it is, every file from that card carries the same offset.
        """
    }

    /// What the app did about it, which is deliberately nothing.
    var restraint: String {
        """
        The date is left exactly as it was found, and the timeline shows it where the \
        file claims rather than where it belongs. Correcting it here would put a guess \
        in place of a known-wrong fact, and a guess must never read as though it came \
        from the camera.
        """
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

extension ProtectionVerdict {
    var tint: Color {
        switch self {
        case .meetsPolicy: return .green
        case .shortOfPolicy: return .orange
        case .diverged: return .red
        case .notLocal: return .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .meetsPolicy: return "checkmark.shield.fill"
        case .shortOfPolicy: return "shield.lefthalf.filled"
        case .diverged: return "exclamationmark.triangle.fill"
        case .notLocal: return "minus"
        }
    }

    /// - Parameter copies: what this photo's own source asks for. Passed in
    ///   rather than read from a global, because there is no longer an
    ///   archive-wide answer and two photos side by side in the Library can
    ///   legitimately want different numbers.
    func displayName(copies: Int) -> String {
        switch self {
        case .meetsPolicy: return "Safe on \(Formatters.copies(copies))"
        case .shortOfPolicy: return "Not yet on \(Formatters.copies(copies))"
        case .diverged: return "A copy no longer matches"
        case .notLocal: return "—"
        }
    }
}

extension CheckStanding {
    /// The evidence behind the verdict, said quietly. Never a verdict itself:
    /// a check that has gone stale is not a copy that has gone missing.
    var note: String? {
        switch self {
        case .neverRead: return "not read back yet"
        case .stale: return "not read back recently"
        case .disagreed: return "content no longer matches"
        case .fresh, .notApplicable: return nil
        }
    }
}

/// The one protection answer the user is given, with the evidence behind it as
/// a footnote rather than a competing state.
struct ProtectionBadge: View {
    let state: ProtectionState
    /// What the photo's own source asks for.
    var copies: Int = 2

    var body: some View {
        let verdict = state.verdict
        HStack(spacing: 6) {
            Label(verdict.displayName(copies: copies), systemImage: verdict.symbolName)
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(verdict.tint.opacity(0.15), in: Capsule())
                .foregroundStyle(verdict.tint)
            if let note = state.checkStanding.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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
        // One element, named. Left as-is a cell read out as an unlabelled
        // image inside a button inside a link — three announcements, none of
        // them the photograph.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(asset.kind.displayName), \(asset.originalFilename)")
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
        // A bar built of coloured rectangles has nothing to read out. The
        // tooltips carry the numbers for a pointer; this carries them for
        // everyone else.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
        .animation(.easeInOut(duration: 0.25), value: segments)
    }

    private var spokenSummary: String {
        let filled = segments.filter { $0.count > 0 }
        guard !filled.isEmpty else { return "Nothing to show" }
        return filled
            .map { "\($0.label): \($0.count.formatted())" }
            .joined(separator: ", ")
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
        // "12" then "sets of identical files" as two separate announcements
        // gives the number before the noun and makes the reader hold it.
        // A label only — flattening a Button into an ignored-children element
        // takes its activation with it.
        .accessibilityLabel("\(value) \(title)")
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}

/// A titled panel. Lighter than `GroupBox` so a screen of them reads as a
/// dashboard rather than as a preferences window.
struct CardBox<Content: View>: View {
    let title: String
    var systemImage: String?
    /// What this card is for, behind an ⓘ rather than printed under the title.
    /// See `SectionHeading` for why.
    var help: String?
    var accessory: AnyView?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.headline)
                        if let help {
                            ExplainerMark(subject: title, help: help)
                        }
                    }
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
    /// Shortens a long value to one line *in the layout*, keeping the whole of
    /// it selectable. Truncating the string instead means the reader copies
    /// the ellipsis too, which is worse than a wrapped line.
    var truncates = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .lineLimit(truncates ? 1 : nil)
                .truncationMode(.middle)
                .help(truncates ? value : "")
            Spacer()
        }
        .font(.callout)
    }
}
