import Foundation

/// Numbers, sizes and lists as a person reads them.
///
/// **Moved out of `UI/Components.swift`, which imports SwiftUI and AppKit.**
/// Three files in `Domain/` already called it, so the portable half of the app
/// depended on a file that only compiles on Apple platforms — and the test
/// guarding portability did not notice, because it read each file's `import`
/// lines and this was a reference, not an import. Nothing here needs either
/// framework; it was only ever here because the first caller was a view.
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
    /// read differently on two devices.
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
