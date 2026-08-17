import Foundation

/// SHA-256 in plain Swift, depending on nothing but the standard library.
///
/// **Why this exists when CryptoKit does.** Every hash this app records — a
/// content hash, a quick checksum, a Merkle root — is a fact that has to mean
/// the same thing on every platform the archive is ever read from. CryptoKit is
/// Apple-only, so a domain that reaches for it is a domain that cannot be
/// lifted anywhere else. This is the fallback that makes the portable layer
/// actually portable: on Apple platforms `Digest256` routes to CryptoKit and
/// this is never called, and everywhere else it is what runs.
///
/// It is also the thing that proves the two agree. `Digest256Tests` hashes the
/// same inputs both ways and requires identical output, which is the check that
/// would catch a future divergence between the accelerated path and the
/// specified one.
///
/// FIPS 180-4. Written out rather than taken from a package because it is a
/// hundred lines of published constants with canonical test vectors, and a
/// dependency here would add supply-chain risk to replace code smaller than the
/// tests covering it — the same reasoning `MerkleTree` records for itself.
struct SHA256Reference {

    /// First 32 bits of the fractional parts of the cube roots of the first 64
    /// primes. FIPS 180-4 §4.2.2.
    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    /// First 32 bits of the fractional parts of the square roots of the first 8
    /// primes. FIPS 180-4 §5.3.3.
    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    /// Bytes not yet part of a whole 64-byte block.
    private var pending: [UInt8] = []
    /// Every byte absorbed, for the length appended during padding.
    private var totalBytes: UInt64 = 0

    init() {
        pending.reserveCapacity(64)
    }

    // MARK: - Absorbing

    mutating func update(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            pending.append(byte)
            totalBytes &+= 1
            if pending.count == 64 {
                compress(pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
    }

    // MARK: - Finishing

    /// The 32-byte digest. Consumes the hasher's state, so it is taken `mutating`
    /// rather than pretending a finished hash can go on absorbing.
    mutating func finalize() -> [UInt8] {
        // FIPS 180-4 §5.1.1: a single 1 bit, then zeros, then the message
        // length in bits as a 64-bit big-endian integer, so the whole thing is
        // a multiple of 64 bytes.
        let bitLength = totalBytes &* 8
        update([0x80])
        while pending.count != 56 {
            update([0x00])
        }
        // Appended directly: routing it through `update` would count these
        // eight bytes into a length that has already been decided.
        var lengthBlock = pending
        for shift in stride(from: 56, through: 0, by: -8) {
            lengthBlock.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }
        compress(lengthBlock)
        pending.removeAll(keepingCapacity: true)

        var digest: [UInt8] = []
        digest.reserveCapacity(32)
        for word in state {
            digest.append(UInt8((word >> 24) & 0xff))
            digest.append(UInt8((word >> 16) & 0xff))
            digest.append(UInt8((word >> 8) & 0xff))
            digest.append(UInt8(word & 0xff))
        }
        return digest
    }

    // MARK: - One-shot

    static func hash(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        var hasher = SHA256Reference()
        hasher.update(bytes)
        return hasher.finalize()
    }

    // MARK: - The round function

    private static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    private mutating func compress(_ block: [UInt8]) {
        var schedule = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let base = index * 4
            schedule[index] =
                (UInt32(block[base]) << 24) |
                (UInt32(block[base + 1]) << 16) |
                (UInt32(block[base + 2]) << 8) |
                UInt32(block[base + 3])
        }
        for index in 16..<64 {
            let s0 = Self.rotr(schedule[index - 15], 7)
                ^ Self.rotr(schedule[index - 15], 18)
                ^ (schedule[index - 15] >> 3)
            let s1 = Self.rotr(schedule[index - 2], 17)
                ^ Self.rotr(schedule[index - 2], 19)
                ^ (schedule[index - 2] >> 10)
            schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
        }

        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]

        for index in 0..<64 {
            let s1 = Self.rotr(e, 6) ^ Self.rotr(e, 11) ^ Self.rotr(e, 25)
            let choice = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ choice &+ Self.roundConstants[index] &+ schedule[index]
            let s0 = Self.rotr(a, 2) ^ Self.rotr(a, 13) ^ Self.rotr(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ majority

            h = g; g = f; f = e; e = d &+ temp1
            d = c; c = b; b = a; a = temp1 &+ temp2
        }

        state[0] = state[0] &+ a; state[1] = state[1] &+ b
        state[2] = state[2] &+ c; state[3] = state[3] &+ d
        state[4] = state[4] &+ e; state[5] = state[5] &+ f
        state[6] = state[6] &+ g; state[7] = state[7] &+ h
    }
}
