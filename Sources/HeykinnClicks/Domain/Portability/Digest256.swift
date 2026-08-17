#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// SHA-256, reached the fastest way each platform offers.
///
/// This is the seam that lets `Domain/` be portable without giving up hardware
/// acceleration on the platform the app actually ships on. Apple platforms get
/// CryptoKit, which uses the ARMv8 SHA extensions; anywhere else falls to
/// `SHA256Reference`. Callers never say which, and the answer is identical
/// either way — `Digest256Tests` requires it of both.
///
/// The rule this encodes, from `docs/MULTI_DEVICE_STATE.md`: a platform may
/// change how fast a fact is reached, never what the fact is.
enum Digest256 {

    /// The 32-byte digest of `data`.
    static func hash(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(CryptoKit.SHA256.hash(data: data))
        #else
        return Data(SHA256Reference.hash(data))
        #endif
    }

    /// Lowercase hex, which is how every digest this app records is written
    /// down — in the catalog, in a marker, in a log.
    ///
    /// Stated as one function because the encoding is part of the specification
    /// rather than a formatting choice: uppercase hex would compare unequal to
    /// every hash already stored.
    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        var result = ""
        result.reserveCapacity(64)
        for byte in bytes {
            result.append(Self.hexDigits[Int(byte >> 4)])
            result.append(Self.hexDigits[Int(byte & 0x0f)])
        }
        return result
    }

    private static let hexDigits: [Character] = Array("0123456789abcdef")

    /// A hasher fed in pieces, for input too large to hold — a file being read
    /// a megabyte at a time, or a zip entry arriving as a stream.
    struct Streaming {
        #if canImport(CryptoKit)
        private var backing = CryptoKit.SHA256()
        #else
        private var backing = SHA256Reference()
        #endif

        init() {}

        mutating func update(_ data: Data) {
            #if canImport(CryptoKit)
            backing.update(data: data)
            #else
            backing.update(data)
            #endif
        }

        mutating func finalize() -> Data {
            #if canImport(CryptoKit)
            return Data(backing.finalize())
            #else
            return Data(backing.finalize())
            #endif
        }

        /// Finishes and formats in one step, since every caller here wants hex.
        mutating func finalizeHex() -> String {
            Digest256.hex(finalize())
        }
    }
}
