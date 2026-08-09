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

    @discardableResult
    mutating func add(_ targetID: UUID) -> Bool {
        guard !destinations.contains(targetID) else { return false }
        destinations.append(targetID)
        mode = .chosen
        return true
    }

    @discardableResult
    mutating func remove(_ targetID: UUID) -> Bool {
        guard destinations.contains(targetID) else { return false }
        destinations.removeAll { $0 == targetID }
        mode = .chosen
        return true
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
