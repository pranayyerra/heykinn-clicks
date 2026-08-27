import SwiftUI

/// A section title, with what it means tucked behind a mark.
///
/// Explanations used to sit under every heading in full. They are written for
/// the first minute of somebody's first day and then read a thousand more
/// times by someone who already knows — at which point a paragraph between the
/// title and the answer is a tax on every visit. Worse, a screen made mostly of
/// explanation reads as complicated, which is the opposite of what the
/// explaining was for.
///
/// So the words stay, one keystroke of curiosity away: hover for the tooltip,
/// click for a popover that stays put while it is read.
///
/// **Descriptions go behind the mark; findings never do.** "Each group says how
/// many copies to keep" describes the furniture. "Most of them are inside
/// your Google Takeout files" is something true about this archive right now,
/// and hiding it would be hiding the answer rather than the instructions.
struct SectionHeading<Trailing: View>: View {
    let title: String
    let help: String?
    var font: Font = .headline
    @ViewBuilder var trailing: Trailing

    init(
        _ title: String,
        help: String? = nil,
        font: Font = .headline,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.help = help
        self.font = font
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(font)
            if let help {
                ExplainerMark(subject: title, help: help)
            }
            trailing
            Spacer(minLength: 0)
        }
    }
}

/// A switch, with what it does behind an ⓘ rather than under it.
///
/// Settings was the densest prose in the app: five switches each trailing a
/// paragraph, so the page read as an essay with controls in it. The words are
/// worth keeping — a switch's consequence is not guessable, and "Free up space
/// once your drives hold a photo" could plausibly mean several things — but
/// they are read once and scrolled past for ever after.
struct ExplainedToggle: View {
    let title: String
    @Binding var isOn: Bool
    let help: String

    init(_ title: String, isOn: Binding<Bool>, help: String) {
        self.title = title
        self._isOn = isOn
        self.help = help
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 6) {
                Text(title)
                ExplainerMark(subject: title, help: help)
            }
        }
    }
}

/// The ⓘ itself: hover for a tooltip, click for a popover that stays put.
///
/// Written three times before this existed — once in `SectionHeading`, once in
/// `CardBox`, once in `ExplainedToggle` — which is three places for the width,
/// the font and the accessibility label to drift apart.
struct ExplainerMark: View {
    let subject: String
    let help: String

    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("What \(subject) means")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            Text(help)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 330, alignment: .leading)
                .padding(14)
        }
    }
}
