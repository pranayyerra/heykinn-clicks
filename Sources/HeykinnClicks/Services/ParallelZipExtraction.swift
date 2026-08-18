import Foundation

/// Extracts a zip with several concurrent in-process readers, each owning a
/// disjoint slice of the entry tree. Worker count adapts to the device's core
/// count AND the destination disk: SSDs benefit from many parallel workers,
/// while spinning/USB targets are kept at low concurrency because parallel
/// writes there cause seek-thrashing that is slower than serial extraction.
enum ParallelZipExtraction {

    enum ExtractionError: Error, LocalizedError {
        case emptyListing(String)
        case workerFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyListing(let path):
                return "Could not read the entry listing of \(path)"
            case .workerFailed(let message):
                return "Parallel extraction worker failed: \(message)"
            }
        }
    }

    /// Cores-and-disk-aware worker count for a given destination, ≥ 1.
    static func recommendedWorkerCount(destination: URL) -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        switch isSolidState(volumeContaining: destination) {
        case .some(true): return max(1, min(cores, 8))
        case .some(false): return 2
        case .none: return max(1, min(cores, 4))
        }
    }

    /// Whether the volume holding `url` is solid-state, via diskutil; nil when
    /// it can't say (e.g. network volumes).
    static func isSolidState(volumeContaining url: URL) -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let solidState = plist["SolidState"] as? Bool
        else { return nil }
        return solidState
    }

    /// Extracts every entry of the zip into `destination` using up to
    /// `workers` concurrent readers. Throws on any worker failure; the caller
    /// owns cleanup of the destination.
    ///
    /// **No subprocess.** This used to run `unzip` once per bucket, which is why
    /// buckets used to be *patterns* rather than names: an argument list has a
    /// length limit and 6,660 names do not fit in one. Reading the archive in
    /// process removes both the limit and the pattern language, so a worker is
    /// handed the exact entries it owns and nothing has to be escaped, quoted or
    /// matched. It also removes the reason a name could ever be misunderstood
    /// between listing and extracting: there is only one listing now, and it is
    /// the archive's own.
    static func extract(zipURL: URL, into destination: URL, workers: Int) throws {
        let entries = ZipTools.listEntries(inZip: zipURL)
        guard !entries.isEmpty else {
            throw ExtractionError.emptyListing(zipURL.path)
        }
        let buckets = partition(entries: entries, workers: max(1, workers))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Each worker opens its own reader, so each has its own file handle and
        // its own position in the archive. Sharing one would serialise them on
        // every seek, which is the opposite of the point.
        let failures = Mutex<[String: String]>([:])
        let thrown = Mutex<Error?>(nil)

        DispatchQueue.concurrentPerform(iterations: buckets.count) { index in
            do {
                let outcome = try ZipExtractor.extract(
                    entries: buckets[index], from: zipURL, into: destination
                )
                if !outcome.failures.isEmpty {
                    failures.withLock { $0.merge(outcome.failures) { first, _ in first } }
                }
            } catch {
                thrown.withLock { $0 = $0 ?? error }
            }
        }

        if let error = thrown.withLock({ $0 }) { throw error }
        let unwritten = failures.withLock { $0 }
        guard unwritten.isEmpty else {
            // Named, up to a point — a listing of 4,000 lines is not a message.
            let sample = unwritten.sorted { $0.key < $1.key }.prefix(3)
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "; ")
            throw ExtractionError.workerFailed(
                unwritten.count <= 3 ? sample : "\(sample); and \(unwritten.count - 3) more"
            )
        }
    }

    /// Splits entries into ≤ `workers` buckets, each owning whole directories.
    ///
    /// Entries are grouped by their first three path components (Takeout /
    /// product / album-or-year), so buckets are disjoint *directories* and no
    /// two workers ever create the same intermediate folder — which is the one
    /// thing concurrent extraction can race on. Shallow entries are kept
    /// together as one group. Groups are balanced across buckets largest-first.
    static func partition(entries: [String], workers: Int) -> [[String]] {
        var groups: [String: [String]] = [:]

        for entry in entries {
            let components = entry.split(separator: "/", omittingEmptySubsequences: false)
            // "" collects the shallow ones; no real prefix is empty.
            let key = components.count > 3 ? components[0...2].joined(separator: "/") : ""
            groups[key, default: []].append(entry)
        }

        let bucketCount = min(max(1, workers), max(1, groups.count))
        var buckets: [[String]] = Array(repeating: [], count: bucketCount)
        var bucketLoads = Array(repeating: 0, count: bucketCount)

        for group in groups.values.sorted(by: { $0.count > $1.count }) {
            let lightest = bucketLoads.enumerated().min(by: { $0.element < $1.element })!.offset
            buckets[lightest].append(contentsOf: group)
            bucketLoads[lightest] += group.count
        }
        return buckets.filter { !$0.isEmpty }
    }
}

/// The smallest possible lock around a value.
///
/// Here because `concurrentPerform` hands back results from several threads and
/// there is nothing else in this codebase that needs one — the rest of the app
/// is actor-isolated. Deliberately not a general utility.
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
