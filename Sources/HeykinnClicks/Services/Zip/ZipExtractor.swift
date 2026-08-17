import Foundation

/// Writes entries out of a zip onto disk, without running another program.
///
/// **Why this is the last piece rather than a tidy-up.** `unzip`, `tar` and
/// `ditto` do not exist on Windows or Android, and 21,380 of the 21,401
/// photographs in this archive arrive through this path — a client that cannot
/// extract sees almost nothing. It is hazard H3 in `MULTI_DEVICE_STATE.md`, the
/// one thing standing between the format and a second platform.
///
/// The hard part was never here. `ZipContainer` parses the container and the
/// platform supplies inflate; what was left was writing bytes to files, which is
/// the same everywhere.
enum ZipExtractor {

    enum ExtractionError: Error, LocalizedError {
        case unsafeEntryName(String)

        var errorDescription: String? {
            switch self {
            case .unsafeEntryName(let name):
                return "This archive holds an entry with an unusable path: \(name)"
            }
        }
    }

    /// What one extraction did. Reported rather than thrown, because a Takeout
    /// part with one unreadable entry is still worth the other 6,659.
    struct Outcome {
        /// Paths written, relative to the destination.
        var written: [String] = []
        /// Entry name → why it did not land. An entry that fails is skipped, not
        /// guessed at: half a photograph is not a photograph.
        var failures: [String: String] = [:]
    }

    /// Writes the named entries into `destination`, recreating the directory
    /// structure the archive records.
    ///
    /// One reader, opened once. The container is parsed on `init`, so extracting
    /// 6,000 entries reads the central directory once rather than 6,000 times —
    /// which is the whole reason a worker is given a list rather than called per
    /// entry.
    @discardableResult
    static func extract(
        entries names: some Sequence<String>, from zipURL: URL, into destination: URL
    ) throws -> Outcome {
        let reader = try ZipReader(url: zipURL)
        defer { reader.close() }

        var byName: [String: ZipContainer.Entry] = [:]
        for entry in reader.entries { byName[entry.name] = entry }

        var outcome = Outcome()
        for name in names {
            guard let entry = byName[name] else {
                outcome.failures[name] = "not in this archive"
                continue
            }
            do {
                try write(entry, from: reader, into: destination)
                outcome.written.append(entry.name)
            } catch {
                outcome.failures[name] = error.localizedDescription
            }
        }
        return outcome
    }

    /// Every entry in the archive.
    @discardableResult
    static func extractAll(from zipURL: URL, into destination: URL) throws -> Outcome {
        let reader = try ZipReader(url: zipURL)
        defer { reader.close() }

        var outcome = Outcome()
        for entry in reader.entries {
            do {
                try write(entry, from: reader, into: destination)
                outcome.written.append(entry.name)
            } catch {
                outcome.failures[entry.name] = error.localizedDescription
            }
        }
        return outcome
    }

    // MARK: - One entry

    private static func write(
        _ entry: ZipContainer.Entry, from reader: ZipReader, into destination: URL
    ) throws {
        let target = try resolve(entry.name, under: destination)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        // Written through a handle rather than accumulated and saved in one
        // piece: an entry here is a photograph or a video of any size, and
        // holding one whole is a memory ceiling nobody chose.
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        var closed = false
        defer { if !closed { try? handle.close() } }

        do {
            try reader.read(entry) { chunk in try handle.write(contentsOf: chunk) }
        } catch {
            // A partial file is worse than none. The caller records what landed,
            // and a file that is short would be recorded as a copy and later
            // verified as damaged — a slow, confusing way to find this out.
            try? handle.close()
            closed = true
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        try handle.close()
        closed = true
    }

    /// Where an entry may be written, refusing anything that would land outside
    /// `destination`.
    ///
    /// **A zip is untrusted input.** An entry named `../../.ssh/authorized_keys`
    /// is the oldest trick there is, and the subprocesses this replaces each
    /// refused it in their own way; doing the extraction here means owning that
    /// refusal rather than inheriting it. Checked by resolving the path and
    /// comparing prefixes, so `a/../../b` is caught as well as a leading `..`.
    static func resolve(_ name: String, under destination: URL) throws -> URL {
        // Absolute names and Windows-style roots are refused outright — they
        // cannot be made relative to anything, only guessed at.
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\0"),
              !(name.count > 1 && name[name.index(name.startIndex, offsetBy: 1)] == ":")
        else { throw ExtractionError.unsafeEntryName(name) }

        let root = destination.standardizedFileURL
        let target = name.split(separator: "/", omittingEmptySubsequences: true)
            .reduce(root) { $0.appendingPathComponent(String($1)) }
            .standardizedFileURL

        // The trailing separator matters: without it `/tmp/out-evil` passes a
        // prefix test against `/tmp/out`.
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw ExtractionError.unsafeEntryName(name)
        }
        return target
    }
}
