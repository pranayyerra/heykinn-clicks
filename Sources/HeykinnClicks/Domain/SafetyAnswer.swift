import Foundation

/// The one answer to "are my photos safe", in the one wording both screens use.
///
/// **It was written twice.** `OverviewView` and `DrivesView` each computed a
/// headline from the same archive and did not agree. Both files carry comments
/// pleading with whoever edits one to edit the other — which is what a codebase
/// says when it knows two things must match and has no way to make them.
///
/// They had already drifted. A photograph with a damaged copy is not
/// *satisfied*, so Overview swept it into the count of photos "not yet on all
/// the drives they are meant to be on" — the sentence for work still in
/// progress. Keep safe said "a copy no longer matches". Same archive, same
/// question, and the screen a person opens first gave the reassuring answer to
/// a photograph that was rotting.
///
/// So the order below is the whole point: it is decided once, here, and both
/// screens read it. Worst first, because the headline is one sentence and the
/// worst true thing is the one worth saying.
enum SafetyAnswer {

    /// Everything the answer depends on, gathered by the caller.
    ///
    /// Plain numbers rather than the store, so the ordering can be tested
    /// without an archive on disk — which is what let the drift go unnoticed:
    /// neither headline could be reached from a test at all.
    struct Facts: Equatable {
        /// Photographs the app is looking after.
        var photos: Int = 0
        /// Places registered to hold copies, whether or not plugged in.
        var places: Int = 0
        /// Photographs with a copy that no longer matches what was recorded.
        var damaged: Int = 0
        /// Photographs with fewer copies than they are meant to have.
        var short: Int = 0
        /// Copies still to make, which can exceed `short` — one photograph can
        /// be one copy short or three, and "412 photos short" reads the same
        /// either way.
        var copiesShort: Int = 0
        /// The fewest places any one photograph is held in. Nil when there is
        /// nothing to count.
        var fewestPlaces: Int?
        /// How many photographs are held in only `fewestPlaces` places.
        var photosAtFewest: Int = 0
        /// Sets of photos asking for more copies than they name places to hold
        /// them — which no amount of copying can fix.
        var unsatisfiable: [String] = []
    }

    /// Whether the archive is in good order: enough copies, none damaged, and
    /// every copy read back at least once.
    static func isSound(_ facts: Facts, everythingRead: Bool) -> Bool {
        everythingRead && facts.damaged == 0 && (facts.fewestPlaces ?? 0) >= 2
    }

    static func headline(_ facts: Facts) -> String {
        if facts.photos == 0 {
            return "Nothing in the archive yet."
        }
        if facts.places == 0 {
            return "\(facts.photos.formatted()) photos have nowhere to go yet — no drive is set up. Add one and the copies start being made."
        }
        // Above being short, because damage is not slow progress. This is the
        // ordering that was wrong on one of the two screens.
        if facts.damaged > 0 {
            return "\(Formatters.count(facts.damaged, "photo")) \(facts.damaged == 1 ? "has" : "have") a copy that no longer matches."
        }
        // Also above being short, and for the same reason: "in no place at all"
        // is both worse and more specific than "behind".
        if facts.fewestPlaces == 0 {
            return "\(Formatters.count(facts.photosAtFewest, "photo")) \(facts.photosAtFewest == 1 ? "is" : "are") in no place at all."
        }
        // Named, because "some photos" is not something anybody can act on, and
        // no amount of waiting fixes this one.
        if !facts.unsatisfiable.isEmpty {
            let named = facts.unsatisfiable.prefix(2).joined(separator: " and ")
            let rest = facts.unsatisfiable.count > 2
                ? " and \(facts.unsatisfiable.count - 2) more"
                : ""
            let asks = facts.unsatisfiable.count > 1 ? "ask" : "asks"
            return "\(named)\(rest) \(asks) for more copies than there are drives to hold them. Name another drive, or ask for fewer, under Keep safe."
        }
        if facts.short > 0 {
            let detail = facts.copiesShort > facts.short
                ? " That is \(Formatters.count(facts.copiesShort, "copy", "copies")) still to make."
                : ""
            return "\(facts.short.formatted()) of \(facts.photos.formatted()) photos are not yet on all the drives they are meant to be on.\(detail)"
        }
        if facts.fewestPlaces == 1 {
            return "\(Formatters.count(facts.photosAtFewest, "photo")) \(facts.photosAtFewest == 1 ? "is" : "are") in one place only."
        }
        guard let fewest = facts.fewestPlaces else {
            return "Every photo is on all the drives it is meant to be on."
        }
        return "Every photo is in \(Formatters.count(fewest, "place"))."
    }
}
