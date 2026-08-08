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

    /// Extracts the entries matching a pattern into a directory, without
    /// touching the rest of the zip.
    ///
    /// One process per zip rather than one per entry. A Takeout part holds
    /// ~2,000 JSON sidecars of about 640 bytes each — spawning `unzip -p` for
    /// every one of them means 24,639 processes and re-seeking a 10 GB archive
    /// each time, where pulling them all out at once is a megabyte of writes
    /// and a single pass.
    ///
    /// Returns the extracted file paths, relative to `destination`, so the
    /// caller can reconstruct where each sat inside the archive.
    @discardableResult
    static func extractEntries(
        matching pattern: String, inZip zipURL: URL, to destination: URL
    ) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // -o overwrite, -q quiet, -d destination. A resumed run re-extracts
        // rather than trusting whatever a previous interrupted one left.
        process.arguments = ["-o", "-q", zipURL.path, pattern, "-d", destination.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()
        // unzip returns 11 when nothing matched, which is not a failure here.
        guard process.terminationStatus == 0 || process.terminationStatus == 11 else { return [] }

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
