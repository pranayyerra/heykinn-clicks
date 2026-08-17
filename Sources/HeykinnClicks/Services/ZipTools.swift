import Foundation

enum ZipTools {
    /// All file entry paths in a zip (directories excluded).
    ///
    /// **Read from the archive's own central directory, not from `unzip -Z1`.**
    ///
    /// This listing is the source every other zip operation draws from: the
    /// reconciler hashes each name to claim it as a copy, and the parallel
    /// extractor turns names into patterns. `unzip` replaces every non-ASCII
    /// byte in a name it prints with a literal `?` — and `?` is its own
    /// single-character wildcard, so asking for the entry back matched nothing.
    /// Measured on a real Google export: `unzip -p` with the correct name exits
    /// 0 and returns the bytes; with the name as `unzip -Z1` printed it, exit 11
    /// and no output.
    ///
    /// What that cost is not theoretical. A photograph whose name carries a
    /// narrow no-break space — every Mac screenshot Google exports — could not
    /// be claimed as a copy on the drive holding it, and the caller recorded it
    /// as `.missing`: the app reporting a photograph absent from a drive it was
    /// sitting on.
    static func listEntries(inZip zipURL: URL) -> [String] {
        guard let reader = try? ZipReader(url: zipURL) else { return [] }
        defer { reader.close() }
        return reader.names
    }

    /// Extracts the entries whose names match a glob into a directory.
    ///
    /// **The pattern is matched here, against the archive's own names**, rather
    /// than handed to a program that has its own idea of what a name is. That
    /// removes the class of bug this whole file exists because of: there is one
    /// listing, it comes from the central directory, and the same string is used
    /// to match and to write.
    ///
    /// Returns the extracted file paths relative to `destination`, so the caller
    /// can reconstruct where each sat inside the archive. Whatever landed is
    /// worth having — an entry that fails is skipped and the rest still arrive,
    /// because a Takeout part with one unreadable entry is still worth the other
    /// 6,659.
    @discardableResult
    static func extractEntries(
        matching pattern: String, inZip zipURL: URL, to destination: URL
    ) -> [String] {
        let wanted = listEntries(inZip: zipURL).filter { matches(pattern, $0) }
        guard !wanted.isEmpty else { return [] }
        return (try? ZipExtractor.extract(
            entries: wanted, from: zipURL, into: destination
        ))?.written ?? []
    }

    /// Glob matching: `*` spans any run of characters, `?` is exactly one, and
    /// `\` escapes either so it can be matched literally.
    ///
    /// **`*` crosses `/` on purpose.** That is what the callers already relied
    /// on from `unzip` and `tar`: a bucket pattern of `<prefix>/*` has to take
    /// everything beneath the prefix, and `*.json` has to reach a sidecar
    /// nested three directories down. A shell's rule — where `*` stops at a
    /// separator — would quietly extract nothing.
    ///
    /// **Character classes are not supported**, and that is not an omission.
    /// Nothing here builds one: patterns are either `escapePattern(prefix) +
    /// "/*"` or a literal like `*.json`, and `escapePattern` escapes brackets
    /// precisely so a name containing `[` is matched as itself. An unescaped
    /// bracket is therefore just a bracket, which is predictable and has no
    /// branch that real input never reaches.
    ///
    /// Compared over Unicode characters rather than bytes: patterns are built
    /// from names that came out of the same archive, so both sides are already
    /// in the archive's own normalisation.
    static func matches(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern), n = Array(name)
        // Iterative, remembering the last `*` to fall back to, rather than
        // recursive: a recursive matcher against a 6,000-entry listing is a
        // stack depth nobody measured.
        var pi = 0, ni = 0
        var starAt = -1, resumeAt = 0

        while ni < n.count {
            if pi < p.count, p[pi] == "\\", pi + 1 < p.count, p[pi + 1] == n[ni] {
                pi += 2
                ni += 1
            } else if pi < p.count, p[pi] == "?" || p[pi] == n[ni] {
                pi += 1
                ni += 1
            } else if pi < p.count, p[pi] == "*" {
                starAt = pi
                resumeAt = ni
                pi += 1
            } else if starAt >= 0 {
                // Back to the last `*` and let it swallow one more character.
                resumeAt += 1
                ni = resumeAt
                pi = starAt + 1
            } else {
                return false
            }
        }
        // Trailing `*`s may match nothing at all.
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Escapes the wildcard characters, so a literal path can be passed where a
    /// pattern is expected.
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
