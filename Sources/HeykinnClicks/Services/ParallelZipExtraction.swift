import Foundation

/// Extracts a zip with multiple concurrent unzip workers, each owning a
/// disjoint slice of the entry tree. Worker count adapts to the Mac's core
/// count AND the destination disk: SSDs benefit from many parallel workers,
/// while spinning/USB drives are kept at low concurrency because parallel
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
    /// `workers` concurrent unzip processes. Throws on any worker failure;
    /// the caller owns cleanup of the destination.
    static func extract(zipURL: URL, into destination: URL, workers: Int) throws {
        let entries = ZipTools.listEntries(inZip: zipURL)
        guard !entries.isEmpty else {
            throw ExtractionError.emptyListing(zipURL.path)
        }
        let buckets = partition(entries: entries, workers: max(1, workers))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var processes: [(Process, Pipe)] = []
        for bucket in buckets {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-qq", "-o", zipURL.path] + bucket + ["-d", destination.path]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = Pipe()
            try process.run()
            processes.append((process, errorPipe))
        }

        var failureMessages: [String] = []
        for (process, errorPipe) in processes {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let message = String(data: errorData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
                failureMessages.append(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        guard failureMessages.isEmpty else {
            throw ExtractionError.workerFailed(failureMessages.joined(separator: "; "))
        }
    }

    /// Splits entries into ≤ `workers` buckets of unzip include-patterns.
    /// Entries are grouped by their first three path components (Takeout /
    /// product / album-or-year) — sibling prefixes, so the resulting
    /// `<prefix>/*` patterns are mutually disjoint and no two workers ever
    /// touch the same file. Shallow entries are passed by exact (escaped)
    /// name. Groups are balanced across buckets largest-first.
    static func partition(entries: [String], workers: Int) -> [[String]] {
        struct Group {
            var pattern: String
            var entryCount: Int
        }
        var groupCounts: [String: Int] = [:]
        var exactNames: [String] = []

        for entry in entries {
            let components = entry.split(separator: "/", omittingEmptySubsequences: false)
            if components.count > 3 {
                let prefix = components[0...2].joined(separator: "/")
                groupCounts[prefix, default: 0] += 1
            } else {
                exactNames.append(entry)
            }
        }

        var groups = groupCounts.map { Group(pattern: ZipTools.escapePattern($0.key) + "/*", entryCount: $0.value) }
        if !exactNames.isEmpty {
            // Shallow files are few; keep them together as one group.
            groups.append(Group(
                pattern: "",
                entryCount: exactNames.count
            ))
        }

        let bucketCount = min(workers, max(1, groups.count))
        var buckets: [[String]] = Array(repeating: [], count: bucketCount)
        var bucketLoads = Array(repeating: 0, count: bucketCount)

        for group in groups.sorted(by: { $0.entryCount > $1.entryCount }) {
            let lightest = bucketLoads.enumerated().min(by: { $0.element < $1.element })!.offset
            if group.pattern.isEmpty {
                buckets[lightest].append(contentsOf: exactNames.map(ZipTools.escapePattern))
            } else {
                buckets[lightest].append(group.pattern)
            }
            bucketLoads[lightest] += group.entryCount
        }
        return buckets.filter { !$0.isEmpty }
    }
}
