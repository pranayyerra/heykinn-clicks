import Foundation

/// What an album says about itself.
///
/// Read back out of the `metadata.json` Google writes into an album's folder,
/// and otherwise invisible: the title is already the tag, but the date and the
/// places were captured and shown nowhere.
struct AlbumDetail: Hashable {
    /// A place Google attached to the album, as it named it.
    struct Place: Hashable {
        /// "Elm Park".
        var name: String
        /// "Northgate" — Google's own subtitle for the place, not a guess.
        var locality: String?
    }

    /// A trip the album records, origin to destination.
    ///
    /// Google files this beside the places but it is not one — "Northgate →
    /// Seaside" is a journey, and flattening it into two more pins would lose
    /// the only part that means anything.
    struct Journey: Hashable {
        var from: Place
        var to: Place
    }

    var title: String
    /// When the album says it is from. Not the same as when its photos were
    /// taken, and not treated as such.
    var date: Date?
    var description: String?
    /// Places the album was enriched with. Empty for most; five of
    /// twenty-nine on a real archive, and the only record of them anywhere.
    var places: [Place] = []
    /// Trips the album records. Rarer still — one of twenty-nine.
    var journeys: [Journey] = []
}
