import Foundation

/// When something happened, in a way several devices can agree on without a
/// server.
///
/// **Why not a plain timestamp.** Conflicts are resolved by taking the later
/// write (`docs/MULTI_DEVICE_STATE.md` §6.3), so "later" has to mean something
/// every device computes identically. Wall clocks do not provide that: two devices
/// disagree by seconds routinely and by hours when a timezone is set wrong, and
/// with no server there is nothing to arbitrate. A device five minutes fast
/// would win every conflict forever, and nobody would ever see why.
///
/// A hybrid logical clock keeps a counter beside the wall time. The wall time
/// keeps stamps roughly meaningful to a human and roughly ordered against the
/// real world; the counter gives a total order when wall times tie or go
/// backwards. Ties beyond that break on device id, so the order is total,
/// deterministic, and identical everywhere — without any clock being authoritative.
///
/// **Drives make this matter more, not less.** A drive can deliver a change
/// written weeks ago, so stamps routinely arrive far out of wall-clock order.
/// That is the ordinary case here rather than an anomaly.
struct HLCTimestamp: Hashable, Comparable, Codable, CustomStringConvertible {

    /// Milliseconds since the Unix epoch. Milliseconds rather than seconds
    /// because a batch import produces many changes per second, and rather than
    /// nanoseconds because the counter already handles ties and a narrower
    /// field keeps the encoding short.
    let wallMillis: Int64
    /// Distinguishes events sharing a wall millisecond, and carries the order
    /// forward when a clock stands still or moves backwards.
    let counter: UInt32
    /// Breaks the remaining ties, so two devices that genuinely stamped the
    /// same instant still order deterministically. Compared bytewise, per
    /// `ByteOrdering`.
    let deviceID: String

    init(wallMillis: Int64, counter: UInt32, deviceID: String) {
        self.wallMillis = wallMillis
        self.counter = counter
        self.deviceID = deviceID
    }

    // MARK: - Ordering

    /// Total order: wall time, then counter, then device id.
    ///
    /// Device id last and never omitted — without it two devices can produce
    /// equal stamps for different events, and "later wins" stops being a
    /// function. It is arbitrary which device wins such a tie; what matters is
    /// that every device makes the *same* arbitrary choice.
    static func < (lhs: HLCTimestamp, rhs: HLCTimestamp) -> Bool {
        if lhs.wallMillis != rhs.wallMillis { return lhs.wallMillis < rhs.wallMillis }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return ByteOrdering.precedes(lhs.deviceID, rhs.deviceID)
    }

    // MARK: - Encoding

    /// Digits in the wall-time field. 15 covers milliseconds to the year 33658,
    /// which is enough that the field never needs to widen — and a field that
    /// changes width stops sorting as text.
    static let wallDigits = 15
    /// Digits in the counter field, giving 999,999 events in one millisecond
    /// before it carries.
    static let counterDigits = 6

    /// Fixed-width and lexicographically sortable, so a plain string comparison
    /// — in SQL, in a sort, in another language — gives the same answer as `<`
    /// above for the two numeric fields.
    ///
    /// Zero-padded for exactly that reason: `"9"` sorts after `"10"` as text,
    /// and this format exists to be compared as text by implementations that
    /// may never parse it.
    var encoded: String {
        let wall = String(format: "%0\(Self.wallDigits)lld", max(wallMillis, 0))
        let count = String(format: "%0\(Self.counterDigits)u", counter)
        return "\(wall)-\(count)-\(deviceID)"
    }

    var description: String { encoded }

    /// Parses `encoded`. Returns nil rather than throwing: a malformed stamp
    /// arrives from a file on a drive, where the caller's decision is to skip
    /// the record, not to fail the merge.
    static func decode(_ text: String) -> HLCTimestamp? {
        // Split on the first two separators only — a device id is free to
        // contain a hyphen, and UUIDs do.
        let parts = text.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == wallDigits,
              parts[1].count == counterDigits,
              let wall = Int64(parts[0]),
              let counter = UInt32(parts[1]),
              !parts[2].isEmpty
        else { return nil }
        return HLCTimestamp(wallMillis: wall, counter: counter, deviceID: String(parts[2]))
    }

    // MARK: - Codable

    /// Encoded as its string form, never as a keyed object, so a stamp written
    /// into a change record is the same text everywhere and stays sortable.
    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = HLCTimestamp.decode(text) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Not a hybrid logical clock stamp: \(text)"
            )
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encoded)
    }
}

/// Issues stamps for this device, and takes account of stamps seen from others.
///
/// One per archive. The state it carries is the last stamp it issued, and that
/// **must outlive the process** — see `persistedState`. A generator that starts
/// fresh after a relaunch can reissue a stamp it has already used, and two
/// different changes sharing one stamp is the one thing the order cannot
/// survive.
final class HybridLogicalClock {

    /// How far ahead of this device's own clock a received stamp may be before
    /// its wall time is refused.
    ///
    /// **This bound is why one broken clock cannot poison the archive.** A
    /// hybrid logical clock advances to the highest wall time it has seen, so a
    /// device whose clock reads 2099 would drag every other device's stamps to
    /// 2099 too — permanently, and thereafter every conflict would be resolved
    /// in favour of whoever was wrong. Without a bound that is unrecoverable.
    ///
    /// Twenty-four hours because the failure is asymmetric. Too tight, and
    /// stamps from a device with a mis-set timezone get their ordering clamped
    /// — the data still merges, some ordering is wrong. Too loose, and the
    /// archive's clock is captured for good. A day absorbs timezone and DST
    /// mistakes and modest drift, and refuses anything that is really a wrong
    /// clock rather than an inaccurate one.
    static let maximumDriftMillis: Int64 = 24 * 60 * 60 * 1000

    private let deviceID: String
    private let physicalNow: () -> Int64
    private var lastWallMillis: Int64
    private var lastCounter: UInt32

    /// Stamps refused for being implausibly far ahead. Surfaced rather than
    /// swallowed: the honest report is "that device's clock is wrong", which is
    /// something a person can fix, and silence here looks like ordering that is
    /// merely inexplicable.
    private(set) var refusedFutureStamps: [HLCTimestamp] = []

    /// - Parameters:
    ///   - deviceID: stable per installation, not per device name.
    ///   - resuming: the last stamp this device issued, from storage. Passing
    ///     nil is correct only on a genuinely first run.
    ///   - physicalNow: milliseconds since the Unix epoch. Injectable because
    ///     every interesting case here is a clock behaving badly, and a test
    ///     that cannot move the clock cannot cover any of them.
    init(
        deviceID: String,
        resuming: HLCTimestamp? = nil,
        physicalNow: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.deviceID = deviceID
        self.physicalNow = physicalNow
        self.lastWallMillis = resuming?.wallMillis ?? 0
        self.lastCounter = resuming?.counter ?? 0
    }

    /// The last stamp issued, to be stored and handed back to `resuming:` on
    /// the next launch.
    var persistedState: HLCTimestamp {
        HLCTimestamp(wallMillis: lastWallMillis, counter: lastCounter, deviceID: deviceID)
    }

    /// A stamp for something happening on this device now.
    ///
    /// Never goes backwards, even when the device's clock does — an NTP
    /// correction, a manual change, a dual boot. The wall time simply stands
    /// still and the counter carries the order until real time catches up.
    @discardableResult
    func now() -> HLCTimestamp {
        let physical = physicalNow()
        if physical > lastWallMillis {
            lastWallMillis = physical
            lastCounter = 0
        } else {
            advanceCounter()
        }
        return HLCTimestamp(wallMillis: lastWallMillis, counter: lastCounter, deviceID: deviceID)
    }

    /// Takes account of a stamp from another device, then issues one that is
    /// ordered after it.
    ///
    /// This is what makes the order *causal* rather than merely total: having
    /// seen a remote change, everything this device does next sorts after it,
    /// whatever the two wall clocks say.
    @discardableResult
    func observe(_ remote: HLCTimestamp) -> HLCTimestamp {
        let physical = physicalNow()

        // Refuse a wall time that cannot be honest. The record is still
        // accepted by the caller — only its claim about *when* is discounted,
        // because believing it would move this device's clock permanently.
        if remote.wallMillis > physical + Self.maximumDriftMillis {
            refusedFutureStamps.append(remote)
            return now()
        }

        let highest = max(max(lastWallMillis, remote.wallMillis), physical)
        if highest == lastWallMillis && highest == remote.wallMillis {
            lastCounter = max(lastCounter, remote.counter)
            advanceCounter()
        } else if highest == lastWallMillis {
            advanceCounter()
        } else if highest == remote.wallMillis {
            lastCounter = remote.counter
            advanceCounter()
        } else {
            lastCounter = 0
        }
        lastWallMillis = highest
        return HLCTimestamp(wallMillis: lastWallMillis, counter: lastCounter, deviceID: deviceID)
    }

    /// Bumps the counter, carrying into the wall time if it would overflow its
    /// field. Carrying rather than wrapping: a wrapped counter re-issues a
    /// stamp that has already been used, and the whole order rests on that
    /// never happening.
    private func advanceCounter() {
        let limit = UInt32(pow(10.0, Double(HLCTimestamp.counterDigits))) - 1
        if lastCounter >= limit {
            lastWallMillis += 1
            lastCounter = 0
        } else {
            lastCounter += 1
        }
    }
}
