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
    /// The devices this group's photos are kept on. Placement writes here and
    /// nowhere else.
    ///
    /// Ordered rather than a set so the UI lists them the way they were chosen,
    /// and so a diff between old and new destinations during a retarget is
    /// stable to read.
    ///
    /// Always the *resolved* answer, whichever way it was arrived at — see
    /// `destinationMode` for which. Storing the resolution rather than deriving
    /// it at every read keeps a record of what the app actually decided, which
    /// is the thing an audit line has to be able to quote.
    var destinationTargetIDs: [UUID]
    /// How the devices above were arrived at.
    var destinationMode: DestinationMode = .chosen
    var createdAt: Date

    /// Whether the devices were worked out or picked.
    ///
    /// This distinction did not exist, and its absence was a bug rather than a
    /// simplification. A bare list cannot tell "the user named these two" from
    /// "these were all the drives on the day the group was made" — so when a
    /// third drive was registered, nothing could decide whether to start using
    /// it. Nothing did: every group kept its two devices, the new drive held
    /// nothing, and no screen said why.
    enum DestinationMode: String, Codable, Hashable {
        /// Worked out: the longest-registered devices, as many as
        /// `desiredCopies` asks for. Re-resolved when the devices change, so a
        /// drive that is forgotten is replaced and copies are made to fill the
        /// gap. Never deletes anything to do it.
        case automatic
        /// Picked, and left alone. The advanced case, and the reason it must be
        /// recorded: someone who deliberately keeps a group off the drive they
        /// travel with has a reason the app has no access to, and quietly
        /// adding a device back would overrule it.
        case chosen
    }

    /// The devices `.automatic` resolves to, given everything registered.
    ///
    /// **Longest-registered first, never by free space.** Free space is a
    /// tempting tiebreak and it points exactly the wrong way: the reason to
    /// keep fewer copies than you have drives is almost always that one of them
    /// lives somewhere else, and free space would happily put both copies on
    /// whichever drive is emptier — one building, two copies, and a screen
    /// saying you are safe. Space still validates a plan; it never picks one.
    ///
    /// Eligibility is *registered and not forgotten*. Whether a drive happens
    /// to be plugged in is deliberately not consulted — on one cable it never
    /// is, and a policy that changed with the cable would be no policy at all
    /// (invariant 12).
    static func automaticDestinations(
        copies: Int,
        among eligible: [UUID]
    ) -> [UUID] {
        Array(eligible.prefix(max(0, copies)))
    }

    /// Whether this group's settings can currently be satisfied at all. Fewer
    /// devices named than copies wanted is not an error to refuse — the user
    /// may be about to plug in the second drive — but it is a state the UI has
    /// to be able to say out loud rather than reporting the photos as simply
    /// behind.
    var isSatisfiable: Bool { destinationTargetIDs.count >= desiredCopies }

    /// Whether adding another device would change what this group does.
    ///
    /// True only for a worked-out group that wants more copies than it has
    /// devices — the one case where a newly registered drive has something to
    /// do. A picked group is left alone by design, and a group already holding
    /// as many copies as it asked for has nothing to gain.
    func wouldUse(additionalDeviceCount count: Int) -> Bool {
        destinationMode == .automatic && destinationTargetIDs.count < desiredCopies && count > 0
    }

    /// The settings a new group starts with: the last ones used.
    ///
    /// Remembered rather than asked fresh each time, because the common case is
    /// ten folders going to the same two devices, and asking that question ten
    /// times is how a considered choice turns into a reflex click.
    struct Defaults: Codable, Hashable {
        var desiredCopies: Int
        var destinationTargetIDs: [UUID]
        /// Defaults to `chosen` so that naming devices here means them.
        /// Constructing a `Defaults` with a list of devices is an explicit act
        /// and the list must not be thrown away; the remembered settings say
        /// `automatic` for themselves.
        var destinationMode: DestinationMode = .chosen

        static let initial = Defaults(desiredCopies: 2, destinationTargetIDs: [])

        /// Tolerates settings stored before the mode existed rather than
        /// failing the decode — a failed decode silently resets a preference
        /// the user set, which looks like the app forgetting things.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            desiredCopies = try container.decode(Int.self, forKey: .desiredCopies)
            destinationTargetIDs = try container.decode([UUID].self, forKey: .destinationTargetIDs)
            destinationMode = try container.decodeIfPresent(
                DestinationMode.self, forKey: .destinationMode
            ) ?? .automatic
        }

        init(
            desiredCopies: Int,
            destinationTargetIDs: [UUID],
            destinationMode: DestinationMode = .chosen
        ) {
            self.desiredCopies = desiredCopies
            self.destinationTargetIDs = destinationTargetIDs
            self.destinationMode = destinationMode
        }
    }
}

/// How one source's photos sit in storage groups.
///
/// Purely descriptive: what a source's card *reports*, never a decision about
/// what it may change. A source does not own a group — its photos merely happen
/// to be in one — and while the card could edit, it had to work out whether
/// doing so was safe, and got it wrong when a group held another export's
/// photos too. There is one editing surface now, so the only job left here is
/// saying what is true.
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

    /// The one group this source's photos are in, when there is exactly one and
    /// it holds nothing else. For describing, not for granting an edit.
    var soleGroup: StorageGroup? {
        if case .exclusive(let group) = self { return group }
        return nil
    }
}
