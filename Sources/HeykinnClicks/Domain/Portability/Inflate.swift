#if canImport(Compression)
import Compression
#endif
import Foundation

/// **The import is guarded, which it was not.** Every *use* of Compression here
/// already sat behind `#if canImport`, and the `.unavailable` failure below was
/// written for a platform that has no decoder — so the design anticipated the
/// move all along and the import at the top would still have refused to
/// compile. The same shape as `Digest256`, which guards CryptoKit and falls
/// back to `SHA256Reference`.
///
/// Moved beside `ZipContainer` for the same reason that one is here: reading a
/// zip is what a client on another platform needs before it can show anybody a
/// photograph, because nearly every photograph in a Google export is inside
/// one. The container format and the decompression are one job.

/// Raw DEFLATE, from whatever the platform already has.
///
/// Zip stores raw DEFLATE — RFC 1951, with no zlib wrapper — which is exactly
/// what Apple's `COMPRESSION_ZLIB` decodes. No dependency is added by this.
enum Inflate {

    enum Failure: Error, LocalizedError {
        case unavailable
        case corrupt

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "This platform has no DEFLATE decoder wired up."
            case .corrupt:
                return "The compressed data in this archive could not be read."
            }
        }
    }

    /// Pulls compressed bytes from `reading` and hands decompressed ones to
    /// `into`, without holding either whole.
    static func stream(
        reading next: (Int) throws -> Data,
        compressedSize: UInt64,
        into receive: (Data) throws -> Void
    ) throws {
        #if canImport(Compression)
        let bufferSize = 1 << 16
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        var streamBox = compression_stream(
            dst_ptr: destination, dst_size: bufferSize, src_ptr: destination, src_size: 0,
            state: nil
        )
        guard compression_stream_init(
            &streamBox, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB
        ) == COMPRESSION_STATUS_OK else { throw Failure.corrupt }
        defer { compression_stream_destroy(&streamBox) }

        streamBox.dst_ptr = destination
        streamBox.dst_size = bufferSize

        var remaining = compressedSize
        var input = Data()
        /// How much of `input` the decoder has taken.
        ///
        /// Tracked explicitly rather than trusting `src_ptr` to survive. The
        /// pointer is only valid inside `withUnsafeBytes`, so each pass has to
        /// hand over a fresh one — and handing over the *whole* buffer again
        /// would re-feed bytes already consumed. In practice the decoder drains
        /// its input every call and this stays zero; relying on that would make
        /// the failure a silently wrong hash, which is the one kind this app
        /// must not have.
        var consumed = 0
        var finished = false

        while !finished {
            if consumed >= input.count, remaining > 0 {
                let want = Int(min(remaining, UInt64(bufferSize)))
                input = try next(want)
                consumed = 0
                if input.isEmpty { remaining = 0 } else { remaining -= UInt64(input.count) }
            }

            let pending = input.count - consumed
            let status: compression_status = pending <= 0
                ? processEmpty(&streamBox, finalising: remaining == 0)
                : input.withUnsafeBytes { raw -> compression_status in
                    let base = raw.bindMemory(to: UInt8.self).baseAddress! + consumed
                    streamBox.src_ptr = base
                    streamBox.src_size = pending
                    let result = compression_stream_process(
                        &streamBox, remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    )
                    // Whatever it did not take, it will be offered again from
                    // exactly where it stopped.
                    consumed += pending - streamBox.src_size
                    return result
                }

            let produced = bufferSize - streamBox.dst_size
            if produced > 0 {
                try receive(Data(bytes: destination, count: produced))
                streamBox.dst_ptr = destination
                streamBox.dst_size = bufferSize
            }

            switch status {
            case COMPRESSION_STATUS_END:
                finished = true
            case COMPRESSION_STATUS_OK:
                // Nothing left to give it and nothing more coming out: the
                // archive claimed more bytes than the stream actually holds.
                if remaining == 0, consumed >= input.count, produced == 0 { finished = true }
            default:
                throw Failure.corrupt
            }
        }
        #else
        // Windows supplies zlib, Android `java.util.zip.Inflater`. Neither is
        // wired up here, and failing loudly is better than a silent empty read
        // that a caller would record as a verified copy of nothing.
        throw Failure.unavailable
        #endif
    }

    #if canImport(Compression)
    private static func processEmpty(
        _ stream: inout compression_stream, finalising: Bool
    ) -> compression_status {
        stream.src_size = 0
        return compression_stream_process(
            &stream, finalising ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
        )
    }
    #endif
}
