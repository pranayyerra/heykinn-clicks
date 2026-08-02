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
