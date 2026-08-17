# SPEC — hashing and ordering

_Normative. Version 1._

Every value defined here is **recorded** — written into a catalog, a marker, or
(in future) a sync segment — and later **compared**. A second implementation
that computes any of them differently does not produce a bug that looks like a
bug. It produces an app that reports intact copies as damaged, groups one
photograph as two, or believes a replica is good when it is not.

So these are specified rather than left to whatever each platform's standard
library makes convenient. The reference implementation is Swift, under
`Sources/HeykinnClicks/Domain/Portability/`; it is not the authority. **This
document is the authority, and `Tests/HeykinnClicksTests/HashingConformanceTests.swift`
is how an implementation proves it agrees.**

---

## Notation

- `‖` — concatenation of byte strings.
- `SHA256(x)` — FIPS 180-4 SHA-256 over the bytes `x`, yielding 32 bytes.
- `hex(x)` — lowercase base-16, two characters per byte, no separators or
  prefix. **Uppercase does not compare equal to anything already stored.**
- Text is encoded as **UTF-8** with no byte-order mark.
- Integers written into a hash input are **decimal ASCII**, no sign, no padding,
  no separators.

---

## 1. String ordering

Wherever the order of strings affects a recorded value, they are ordered
**bytewise over their UTF-8 encodings**: compare byte by byte as unsigned
values; if one is a prefix of the other, the shorter sorts first.

This is stated because it is the rule most likely to be got wrong by accident.
Swift's `<` on `String`, Java and Kotlin's `compareTo`, and .NET's default
culture-aware comparison each do something else, and the differences only appear
outside ASCII — which means the mistake ships, and then surfaces years later on
one user's archive.

Two consequences worth stating outright:

- **Canonically equivalent strings are not interchangeable.** `"é"` as U+00E9
  and `"e"` + U+0301 are *equal* under Swift's `String` comparison and are
  *different* byte strings. Under this specification they are different.
- **Normalise before recording, never during comparison.** Any path or filename
  recorded anywhere is normalised to **NFC** at the moment it is recorded.
  macOS returns decomposed forms from some filesystem APIs where Windows and
  Android return composed ones, and a replica recorded under two normalisations
  is two replicas.

---

## 2. Content hash

The identity of a file's bytes. Stored as `assets.content_hash`.

```
content_hash = hex(SHA256(file contents))
```

**Contents only.** Never the filename, never the size, never modification
times, never extended attributes, resource forks, alternate data streams or
any other filesystem metadata. None of those survive a round trip through
exFAT, and none of them are the same on two platforms.

Implementations should stream rather than read whole files; the reference reads
in 1 MiB chunks, but chunk size does not affect the result.

---

## 3. Quick checksum

A deliberately partial fingerprint, for comparing large archive files without
reading every byte. Stored as `takeout_archives.quick_checksum`.

Matching quick checksums mean "almost certainly the same file". They never mean
"proven identical" — only the content hash says that. The design catches what
actually happens to archive copies: truncation, a partial transfer, the wrong
file under the right name, corruption at either end.

### Constants

| | |
|---|---|
| Edge window | 2 MiB (`2 097 152` bytes) |
| Interior window | 512 KiB (`524 288` bytes) |
| Interior probes | 6 |

These are **specification, not tuning**. Changing any one of them invalidates
every quick checksum already recorded.

### Algorithm

Let `L` be the file's length in bytes.

1. Absorb `decimal_ascii(L)`. The length goes first so a truncated copy differs
   even when every sampled window happens to match.
2. **If `L ≤ 2 × edge` (4 MiB)** — absorb the whole file, then stop. Sampling a
   file this small would cost more than it saves.
3. Otherwise:
   1. absorb the first `edge` bytes;
   2. for `i` = 1 … 6, absorb `interior` bytes starting at offset
      `floor(L × i / 7)`;
   3. absorb the last `edge` bytes, i.e. from offset `L − edge`.
4. `quick_checksum = hex(SHA256(everything absorbed, in that order))`.

A window that runs past the end of the file contributes the bytes it got.
Windows are absorbed in the order above and are **not** deduplicated if they
overlap — at sizes just above the boundary they can, and the overlap is part of
the defined input.

---

## 4. Merkle tree — withdrawn

**This section defined a format nothing writes, and has been removed.** The
construction is in git history if it is ever wanted again; it is not normative
and an implementation does not need it.

It compared what two targets held by comparing roots. The reason it went is that
both trees took their leaf digests from `asset.contentHash` — a value the
*catalog* recorded — so a shared asset carried an identical digest on both sides
by construction, and the comparison could only ever report which asset keys each
target held. Under k-of-n placement that difference is the design rather than a
fault. Every question it was reached for now has a better answer:

| Question | Answered by |
|---|---|
| Which targets should hold this asset? | The placement audit, off the same rows |
| Has anything moved on disk? | Anchor `stat`s — a handful of calls, whatever the archive's size |
| Has a file been edited under an intact path? | The observed size and modification date recorded per replica |

A tree over recorded hashes could never have answered the last two: it changes
only when the catalog changes, never when the disk does.

The section number is kept so §5 and §6 do not shift under references written
against them.

**One thing outlived it.** The tree sorted its leaves with Swift's `String <` —
Unicode collation, not byte order — which two platforms implement differently.
That hazard was real and its fix, `ByteOrdering`, is still used and still
specified in §1: `MetadataRecord.fingerprint` sorts JSON object keys with it, and
the hybrid logical clock breaks stamp ties with it.

---

## 5. Metadata schema fingerprint

Identifies the *shape* of a provider metadata payload, so a format change is
noticed. Stored as `metadata_schemas.fingerprint`.

1. Parse the payload as JSON. If it is not a JSON object, the fingerprint is the
   literal string `unparsed`.
2. Take the object's **top-level keys only** — not nested ones.
3. Sort them bytewise per §1.
4. Join with `,` (U+002C), no spaces.
5. ```
   fingerprint = first 16 characters of hex(SHA256(joined))
   ```

Truncated to 16 hex characters (64 bits) because this groups shapes for a
human to look at; it is not a security boundary.

---

## 6. Conformance

An implementation conforms when it reproduces every value in
`Tests/HeykinnClicksTests/HashingConformanceTests.swift`. That file is the
executable form of this document and covers, deliberately:

- the NIST SHA-256 vectors, and the 55/56/57-byte padding boundary
- agreement between an accelerated platform implementation and a plain one
- streaming in arbitrary chunk sizes matching a single-shot hash
- bytewise ordering **where it disagrees with the platform's native ordering**
- composed vs decomposed forms being distinct
- quick checksum at the 4 MiB boundary, on an empty file, under truncation, and
  under a single changed byte inside a sampled window

### Changing anything here

Every value defined above is already recorded in users' catalogs. A change is
therefore a **format break**, not a refactor, and needs:

1. a new version number on this document;
2. a `CatalogStore.schemaVersion` bump, so an older build refuses the catalog
   rather than writing to it (see `docs/MULTI_DEVICE_STATE.md` §9);
3. a migration that recomputes what changed, or a documented decision that the
   old values stay and both are understood.

"It would be tidier the other way" is not a reason.
