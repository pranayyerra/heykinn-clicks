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

## 4. Merkle tree

Compares what two targets hold without reading either. Roots are compared, and
where they differ the tree is descended to find the responsible assets.

A matching root is never proof the bytes are good — it compares what the catalog
*recorded*, so a file whose bytes decayed while its recorded hash stayed put
leaves the root unchanged. Git has the same property, which is why `git fsck`
still reads every object.

### Construction

Input is a set of leaves, each a `(key, digest)` pair of strings. In this app
`key` is an asset id and `digest` is that asset's recorded content hash, but the
construction does not depend on that.

1. **Sort** the leaves by `key`, bytewise per §1. Duplicate keys are not
   permitted.
2. **Leaf digests** — for each leaf, in sorted order:
   ```
   leaf = SHA256("leaf:" ‖ key ‖ 0x1F ‖ digest)
   ```
   `"leaf:"` is the five ASCII bytes `6c 65 61 66 3a`. `0x1F` is the ASCII unit
   separator, and it is what stops `("ab", "c")` and `("a", "bc")` hashing alike.
3. **Levels** — while the current level holds more than one node, build the next
   by taking nodes in pairs, left to right:
   ```
   node = SHA256(0x01 ‖ left ‖ right)
   ```
   over the **raw 32-byte digests**, not their hex. A node left over at the end
   of an odd-length level is **promoted unchanged to the next level** — never
   paired with itself, which would make two different leaf sets hash alike.
4. **Root** — `hex()` of the single remaining node. A tree with no leaves has
   **no root**, which is distinct from a root over zero bytes.

The `"leaf:"` prefix and the `0x01` node tag are domain separation: they ensure
a leaf digest can never be mistaken for an interior node digest.

### Worked example

Leaves `("a","1111")`, `("b","2222")`, `("c","3333")`:

```
leaf a  = 5a2e0e20b862cea08c8fef167c5b3832a50d7aef99258f707320e7efe1adba65
leaf b  = fdf8df5f146387fe3f4a4b075dac5e3fd456d55fdc8a5bc728a2e58dc86e6efc
leaf c  = c8560758c930a76f22b7fe1d481d9da72a33eb99de64810eeeb6cff066da6264

node(a,b) = 35562d5b5bfa98191a350d9c30bc6b28dba777aa9afa6a5793f072f7f1c51dc8
            ── leaf c is promoted unchanged ──
root      = 5b2ac10a80b62d5006a6efe74844641a7ffa264c8b3bc0042ab60b5d948f76cb
```

An implementation that reproduces those five values is almost certainly correct.
One that reproduces only the root may still have the levels wrong.

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
- the Merkle worked example, order-independence, and odd-node promotion
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
