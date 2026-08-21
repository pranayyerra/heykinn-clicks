import Foundation

/// Which cached thumbnails to drop when the tier outgrows its budget.
///
/// **The only part of thumbnailing that is not the platform's.** Rendering a
/// photograph into a small image genuinely needs ImageIO, AVFoundation and
/// somewhere to put the pixels — unlike the other seams drawn for step 8, where
/// the Apple half turned out to be a fraction of the file. Pretending otherwise
/// here would be ceremony.
///
/// What is *not* the platform's is deciding what to throw away, and that had no
/// test: exercising it meant writing real JPEGs to a real directory and
/// measuring what survived. The rule is one sentence and two ways to get it
/// subtly wrong — evicting one file too few and staying over budget for ever,
/// or evicting when already under it.
enum ThumbnailEviction {

    /// A cached file, as much of it as the decision needs.
    struct Entry: Equatable, Hashable {
        var url: URL
        var size: Int64
        /// When it was last used. Modification date stands in for this, since
        /// a cache hit rewrites the file.
        var lastUsed: Date
    }

    /// The entries to remove, oldest first, stopping the moment the rest fit.
    ///
    /// Returns nothing at all when the tier is already within budget —
    /// including when it is exactly at it. A cache sitting on its limit is
    /// working, not overflowing, and evicting there would throw away a
    /// thumbnail every time one was added for ever.
    static func choose(from entries: [Entry], budget: Int64) -> [Entry] {
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > budget else { return [] }

        var evicted: [Entry] = []
        // Oldest first, and ties broken by path so two files stamped in the
        // same second do not evict in whatever order the filesystem listed
        // them — the same archive should shed the same thumbnails twice.
        for entry in entries.sorted(by: {
            $0.lastUsed != $1.lastUsed ? $0.lastUsed < $1.lastUsed : $0.url.path < $1.url.path
        }) {
            guard total > budget else { break }
            evicted.append(entry)
            total -= entry.size
        }
        return evicted
    }
}
