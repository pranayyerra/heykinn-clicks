import Foundation

enum ZipTools {
    /// All file entry paths in a zip (directories excluded).
    static func listEntries(inZip zipURL: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", zipURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let listing = String(data: data, encoding: .utf8) else {
            return []
        }
        return listing.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") }
    }

    /// Extracts the entries matching a pattern into a directory.
    ///
    /// Uses `tar` — libarchive — rather than `unzip`, which cannot do this
    /// correctly on a real Google export.
    ///
    /// A Mac screenshot exported by Google carries a narrow no-break space in
    /// its name: `Image 10-10-24 at 4.54 PM.jpg`. `unzip` mangles every
    /// non-ASCII byte to a literal `?` — in its *listing* as well as on disk —
    /// and then aborts mid-archive with a "disk full" error that has nothing
    /// to do with the disk, taking every entry after it. On one real part that
    /// was 4,673 of 6,660 sidecars lost, silently, with a zero exit path that
    /// looked like success.
    ///
    /// Reading each entry to stdout instead does not help: the only name to
    /// ask for comes from that same mangled listing, and the `?` it contains
    /// is unzip's own single-character wildcard, so the round trip either
    /// matches by luck or not at all.
    ///
    /// `tar` handles the name, extracts it, and exits 0. Names then come from
    /// the filesystem, which is the one place they are certainly right.
    ///
    /// Returns the extracted file paths relative to `destination`, so the
    /// caller can reconstruct where each sat inside the archive.
    @discardableResult
    static func extractEntries(
        matching pattern: String, inZip zipURL: URL, to destination: URL
    ) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", zipURL.path, "-C", destination.path, "--include", pattern]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()

        // Whatever landed is worth having. A part-way failure used to discard
        // everything it had already written, which turned a partial read into
        // no read at all — so the listing below is the answer, not the status.
        guard let walker = FileManager.default.enumerator(
            at: destination, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var found: [String] = []
        let prefix = destination.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let path = url.standardizedFileURL.path
            found.append(path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path)
        }
        return found
    }

    /// Escapes unzip's wildcard characters so a literal path can be passed as
    /// an include pattern.
    static func escapePattern(_ path: String) -> String {
        var escaped = ""
        for character in path {
            if character == "*" || character == "?" || character == "[" || character == "]" || character == "\\" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
