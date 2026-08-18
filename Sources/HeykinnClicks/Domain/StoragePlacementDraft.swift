import Foundation

/// A change to where a group is kept, composed before it is committed.
///
/// Editing storage used to be a sheet of checkboxes, where every intermediate
/// state was also a legal one because the sheet only ever offered legal moves.
/// Direct manipulation gives that up: picking a placement up off one device and
/// not yet having put it on another is a group with nowhere to live, and
/// turning the copy count past the number of devices named is a group asking
/// for more copies than it has homes. Both are reasonable things to be *in the
/// middle of* and neither is a reasonable thing to save.
///
/// So the draft holds the change, `problem` says whether it could be saved, and
/// only the caller's commit reaches the catalog. The rules live here rather
/// than in the view because they are the model's rules — and because a view
/// cannot be asked whether dragging the last device off a group is allowed.
struct StoragePlacementDraft: Equatable {
    let groupID: UUID
    var copies: Int
    var destinations: [UUID]
    var mode: StorageGroup.DestinationMode

    init(group: StorageGroup) {
        groupID = group.id
        copies = group.desiredCopies
        destinations = group.destinationTargetIDs
        mode = group.destinationMode
    }

    /// Moves a placement from one device to another.
    ///
    /// A replacement in place, not a remove and an append, so the order of a
    /// group's devices survives the move — `deviceNames` reads that order, and
    /// a group that reshuffles its own list whenever something is dragged looks
    /// like it did more than was asked.
    ///
    /// Returns false, changing nothing, when the move is meaningless: dragging
    /// from a device the group does not use, or onto one it already does.
    mutating func move(from: UUID, to: UUID) -> Bool {
        guard from != to, destinations.contains(from), !destinations.contains(to) else { return false }
        destinations = destinations.map { $0 == from ? to : $0 }
        // Dragging *is* naming devices. Left on "work it out for me", the app
        // would undo the move at the next resolve, so the drag has to mean what
        // it appears to mean.
        mode = .chosen
        return true
    }

    /// Whether every named device is meant to hold a copy.
    ///
    /// The difference the editor has to keep straight. Naming three devices and
    /// asking for two copies is not a mistake — it is k-of-n, and the third is
    /// a spare the planner falls back to when one of the first two is full,
    /// away, or already holds the photo. But somebody ticking a third device
    /// usually means "and this one too", and letting that silently demote it to
    /// a fallback is the kind of thing nobody notices until a drive is emptier
    /// than they expected.
    var keepsACopyEverywhere: Bool { copies >= destinations.count }

    /// Adds a device, keeping whichever arrangement was already in force.
    ///
    /// If every named device was holding a copy, the new one does too. If the
    /// group was already using spares, it gains another spare. Either way the
    /// count is not quietly left meaning something else.
    @discardableResult
    mutating func add(_ targetID: UUID) -> Bool {
        guard !destinations.contains(targetID) else { return false }
        let wasEverywhere = keepsACopyEverywhere
        destinations.append(targetID)
        if wasEverywhere { copies = destinations.count }
        mode = .chosen
        return true
    }

    /// Removes a device, keeping whichever arrangement was already in force.
    ///
    /// Dropping a device while "on all of them" was true would otherwise leave
    /// the count one above the devices — an error message about an arrangement
    /// the user never asked for, in response to the one thing they did.
    @discardableResult
    mutating func remove(_ targetID: UUID) -> Bool {
        guard destinations.contains(targetID) else { return false }
        let wasEverywhere = keepsACopyEverywhere
        destinations.removeAll { $0 == targetID }
        if wasEverywhere { copies = max(1, destinations.count) }
        mode = .chosen
        return true
    }

    /// What this arrangement means, in the words somebody would use.
    ///
    /// The editor showed a tick list and a number with nothing between them, so
    /// "three devices, two copies" looked like a contradiction rather than a
    /// spare. Written out, it is neither surprising nor a thing to work out.
    ///
    /// **A worked-out group names its devices and says why.** It used to say
    /// "on devices the app works out", which repeated the label underneath it
    /// and answered neither *which* nor *why* — fine when the answer was
    /// "whichever were registered first", and not something worth admitting.
    /// Now that placement has a reason a person would accept, the sentence can
    /// give it.
    func rule(choseFrom candidates: Int, naming names: (UUID) -> String) -> String {
        Self.rule(
            copies: copies, destinations: destinations, mode: mode,
            choseFrom: candidates, naming: names
        )
    }

    /// The same sentence, for callers holding the three values without a draft
    /// around them — the add-photos sheet, which is describing a group that
    /// does not exist yet.
    ///
    /// **Shared rather than reimplemented.** The sheet and the storage editor
    /// are saying the same thing about the same arrangement, and two copies of
    /// a sentence are two sentences that will disagree by the end of the year.
    /// `candidates` is how many devices the arrangement was picked *from*.
    ///
    /// **Only a real choice earns a reason.** "The ones with the most room" is
    /// true when some drive was passed over and false when none was: taking
    /// both of two drives is not a judgement about room, and a fresh install
    /// with no drive at all falls back to this device, where the claim would be
    /// flatly untrue — it was not the roomiest of anything, it was the only
    /// place there was. Saying so anyway is the failure R0 names, arrived at
    /// through a sentence rather than through data.
    static func rule(
        copies: Int,
        destinations: [UUID],
        mode: StorageGroup.DestinationMode,
        choseFrom candidates: Int = 0,
        naming names: (UUID) -> String
    ) -> String {
        guard !destinations.isEmpty else { return "Nowhere to keep them yet." }
        let listed = destinations.map(names)
        if mode == .automatic {
            let named = Formatters.list(listed)
            // Fewer devices than copies, which `problem` deliberately stays
            // quiet about for a worked-out group — so this is the only place it
            // is said, and it says it without calling the default an error.
            guard destinations.count >= copies else {
                return "Every photo on \(named). That is \(Formatters.copies(destinations.count)), "
                    + "not the \(Formatters.copies(copies)) you asked for — register another device "
                    + "and the rest follow."
            }
            guard candidates > destinations.count else {
                // Nothing was passed over, so there is no reason to give.
                return "Every photo on \(named)."
            }
            return destinations.count == 1
                ? "Every photo on \(named) — the device with the most room."
                : "Every photo on \(named) — the devices with the most room."
        }
        if destinations.count == 1 {
            return "Every photo on \(listed[0]), and nowhere else."
        }
        if copies >= destinations.count {
            return "Every photo on all \(destinations.count) — \(Formatters.list(listed))."
        }
        let primary = Array(listed.prefix(copies))
        let spares = Array(listed.dropFirst(copies))
        return "Every photo on \(Formatters.copies(copies)) — \(Formatters.list(primary)) first, "
            + "and \(Formatters.list(spares)) when one of those is full, away, or already has it."
    }

    /// What is wrong with this draft right now, or nil when it could be saved.
    ///
    /// Stated rather than prevented. Refusing the drag that empties a group, or
    /// silently clamping the count as devices are removed, hides the rule and
    /// leaves somebody guessing why the app fought them. Letting the draft be
    /// wrong and saying so is the whole reason it is a draft.
    var problem: String? {
        if destinations.isEmpty {
            return "Nowhere to keep them. Give this group at least one device."
        }
        if copies < 1 {
            return "A group has to keep at least one copy."
        }
        // Only when the devices are named. A group working out its own devices
        // is short of nothing until it is resolved, and saying otherwise would
        // put a warning on the default arrangement.
        if mode == .chosen, copies > destinations.count {
            let short = copies - destinations.count
            return "\(Formatters.copies(copies)) on \(Formatters.count(destinations.count, "device")) — \(Formatters.count(short, "more device")) needed, or fewer copies."
        }
        return nil
    }

    var canBeSaved: Bool { problem == nil }

    func differs(from group: StorageGroup) -> Bool {
        copies != group.desiredCopies
            || destinations != group.destinationTargetIDs
            || mode != group.destinationMode
    }
}
