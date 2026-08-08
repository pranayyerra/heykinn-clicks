import Foundation

/// A set of photos kept the same way: how many copies, and on which devices.
///
/// Split out of `PhotoArchiveSource`, which carried two different facts in one
/// row — *where these came from* and *where they should be kept*. That worked
/// while every group was born from an import and never changed. It stops
/// working the moment ten photos are pulled out of an export into their own
/// group: the new group has no provenance to speak of, and inventing one ("came
/// from the March 2026 export, sort of") would be a lie the app then reasons
/// with. Provenance is history and cannot change; policy is a decision and must
/// be able to.
///
/// Membership lives here rather than on the source, and stays a strict
/// partition — one group per asset. A policy needs one answer: "this photo is
/// in three groups naming three different devices" has none.
struct StorageGroup: Identifiable, Hashable {
    let id: UUID
    /// What to call it on screen. Starts as the name of whatever it was made
    /// from, and is the user's to change — unlike a source's label, which is a
    /// record of what happened.
    var label: String
    /// How many devices should hold each of this group's photos.
    var desiredCopies: Int
    /// The devices the user named. Placement writes here and nowhere else.
    ///
    /// Ordered rather than a set so the UI lists them the way they were chosen,
    /// and so a diff between old and new destinations during a retarget is
    /// stable to read.
    var destinationTargetIDs: [UUID]
    var createdAt: Date

    /// Whether this group's settings can currently be satisfied at all. Fewer
    /// devices named than copies wanted is not an error to refuse — the user
    /// may be about to plug in the second drive — but it is a state the UI has
    /// to be able to say out loud rather than reporting the photos as simply
    /// behind.
    var isSatisfiable: Bool { destinationTargetIDs.count >= desiredCopies }

    /// The settings a new group starts with: the last ones used.
    ///
    /// Remembered rather than asked fresh each time, because the common case is
    /// ten folders going to the same two devices, and asking that question ten
    /// times is how a considered choice turns into a reflex click.
    struct Defaults: Codable, Hashable {
        var desiredCopies: Int
        var destinationTargetIDs: [UUID]

        static let initial = Defaults(desiredCopies: 2, destinationTargetIDs: [])
    }
}

/// How one source's photos sit in storage groups.
///
/// The question a source's card has to answer before it offers to change
/// anything. A source does not *own* a group — its photos merely happen to be
/// in one — and the card was treating the two as the same thing. Once some
/// photos had moved, "change where these are kept" on an export's card could
/// reach a group holding a different export's photos and change those too.
enum SourceGroupPlacement {
    /// Every photo of this source is in one group, and that group holds
    /// nothing else. Changing it here changes exactly these photos and no
    /// others, so the card can offer it inline.
    case exclusive(StorageGroup)
    /// All in one group, but the group holds other photos as well. Changing it
    /// from here would silently change theirs too, so the card says whose
    /// company they are in and sends the user to the group itself.
    case shared(group: StorageGroup, otherPhotos: Int)
    /// Spread across several groups. There is no single setting to show, and
    /// picking one to present would misdescribe the rest.
    case split(groups: [StorageGroup], photoCount: Int)
    /// Nothing of this source is in the archive yet.
    case none

    /// The group to edit when doing so affects only this source's photos.
    var exclusiveGroup: StorageGroup? {
        if case .exclusive(let group) = self { return group }
        return nil
    }
}
