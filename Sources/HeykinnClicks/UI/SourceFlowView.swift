import SwiftUI

/// One place photos come into the archive from, as the flow diagram sees it.
struct PhotoSource: Identifiable {
    enum State: Equatable {
        /// Nothing has been set up here yet — the app cannot see this place.
        case notSet
        /// Set up, and everything found here is in the archive.
        case allIn(count: Int)
        /// Set up, and some of what is here has not been brought in yet.
        case partlyIn(inArchive: Int, total: Int)
        /// Set up, looked, and there was nothing here.
        case nothingFound
        /// Something is stopping the app from reading this place.
        case blocked(String)
    }

    let id: String
    var name: String
    var symbol: String
    var state: State

    /// The plain sentence under the name. What this source *is*, when nothing
    /// has been set up; what it holds, once something has.
    var detail: String
    /// What this way in is, for the ⓘ beside its name.
    var help: String?

    var isSet: Bool {
        switch state {
        case .notSet, .blocked: return false
        case .allIn, .partlyIn, .nothingFound: return true
        }
    }

    var tint: Color {
        switch state {
        case .allIn: return .green
        case .partlyIn: return .orange
        case .blocked: return .red
        case .notSet, .nothingFound: return .secondary
        }
    }

    var status: String {
        switch state {
        case .notSet: return "Not set up"
        case .nothingFound: return "Nothing found here"
        case .blocked(let why): return why
        case .allIn(let count): return "All \(count.formatted()) in the archive"
        case .partlyIn(let inArchive, let total):
            return "\(inArchive.formatted()) of \(total.formatted()) in the archive"
        }
    }
}

/// Where photos come *in* from, drawn the way the drives screen draws where
/// copies are *held*.
///
/// The two screens answer opposite halves of one question and had nothing in
/// common to look at: the drives screen puts the archive in the middle with a
/// node for every place holding it, and Sources was a stack of cards whose
/// relationship to each other, and to the archive, the reader had to assemble
/// themselves. So this states it: every source on the left, the archive on the
/// right, and a bar on each source saying how much of it has made it across.
///
/// Left-to-right rather than another ring. The map's ring says "these all hold
/// the same thing"; direction is the whole point here, and a ring cannot show
/// it. A source that is not set up is drawn anyway, faint — a place the archive
/// is not being fed from is exactly what someone scanning this needs to see.
struct SourceFlowView<Detail: View>: View {
    let sources: [PhotoSource]
    /// Sources whose detail is showing, so a node can say it is the one open
    /// rather than leaving the reader to match a panel to a box by position.
    var opened: Set<String> = []
    var onSelect: (PhotoSource) -> Void
    /// Drawn inside the row it belongs to, like the places and the groups.
    @ViewBuilder var detail: (PhotoSource) -> Detail
    /// The one thing this row is for, on the row itself.
    ///
    /// "Choose a folder…" and "Connect Photos…" were inside the fold. Somebody
    /// who has just installed this looks at three collapsed rows and sees no
    /// way to add a photo — the actions are one click away, behind a row that
    /// gives no sign it is hiding the only thing they came to do.
    var action: (PhotoSource) -> (title: String, symbol: String, run: () -> Void)?

    @ViewBuilder
    private func actionButton(
        _ action: (title: String, symbol: String, run: () -> Void),
        prominent: Bool
    ) -> some View {
        Group {
            if prominent {
                Button(action: action.run) {
                    Label(action.title, systemImage: action.symbol)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: action.run) {
                    Label(action.title, systemImage: action.symbol)
                }
                .buttonStyle(.bordered)
            }
        }
        .font(.caption)
        .controlSize(.small)
        .tint(.accentColor)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(spacing: 8) {
                ForEach(sources) { source in
                    // Row and detail inside one card, not a card followed by a
                    // loose panel. The border was drawn around the row alone,
                    // so opening it put the detail outside the very outline
                    // that said which source it belonged to.
                    let isOpen = opened.contains(source.id)
                    VStack(alignment: .leading, spacing: 0) {
                        node(source)
                        if isOpen {
                            detail(source)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        .background.opacity(source.isSet ? 1 : 0.5),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isOpen ? Color.accentColor.opacity(0.55)
                                    : source.isSet ? source.tint.opacity(0.35)
                                    : Color.secondary.opacity(0.25),
                                style: StrokeStyle(
                                    lineWidth: 1,
                                    dash: source.isSet ? [] : [4, 4]
                                )
                            )
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func node(_ source: PhotoSource) -> some View {
        let isOpen = opened.contains(source.id)
        return Button {
            onSelect(source)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: source.symbol)
                    .font(.title3)
                    .frame(width: 22)
                    .foregroundStyle(source.isSet ? source.tint : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(source.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let help = source.help {
                            ExplainerMark(subject: source.name, help: help)
                        }
                    }
                    // Yields when the row is open: what this line summarises is
                    // spelled out directly underneath, and saying it twice a
                    // line apart is the thing inline detail was meant to stop.
                    if !isOpen {
                        Text(source.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // A `ProgressView` sat here showing how much of this
                    // source was in the archive. Every import on a settled
                    // device finished long ago, so it was a bar pinned at
                    // 100% for ever — chrome that reads as live status. The
                    // status line below already says the same thing in words.
                    Text(source.status)
                        .font(.caption2)
                        .foregroundStyle(source.isSet ? source.tint : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let action = action(source) {
                    // Filled while the source has never been set up, outlined
                    // once it has. On a first run this is three invitations;
                    // afterwards it is three quiet ways back in.
                    //
                    // No trailing "…" either. The convention says an ellipsis
                    // means "this opens something that asks for more", which is
                    // true of all three and useful on none of them: every one
                    // of these obviously opens a picker, and three ellipses in
                    // a column read as hesitation rather than as a rule.
                    actionButton(action, prominent: !source.isSet)
                }
                // Rotates rather than swapping glyph, so it reads as the
                // same control moving — the same chevron the places and the
                // groups use.
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(source.name). \(source.detail). \(source.status).")
    }
}
