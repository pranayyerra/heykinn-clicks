# Multi-device state and platform independence

_Design document. Steps 1–7 of §10 are built and tested; the code is the source of truth for those. What remains open is marked as such._

The goal: somebody who owns several devices sees one archive, not one per
device. The same drives, the same groups, the same counts, the same answer to
"is this photo safe". macOS first, because that is what the app runs on; iOS,
Windows and Android are the same archive read from somewhere else.

**The drives are the transport.** Metadata travels the way the photographs
already do — on the drive the user plugs in. No account, no server, no cloud
required, no ecosystem to be locked into.

---

## 1. What platform independence means here

It does **not** mean a lowest-common-denominator app that ignores what each
platform is good at. Refusing PhotoKit on macOS, or the NTFS change journal on
Windows, would make a worse app on every platform in exchange for a tidiness
nobody can see.

It means one thing, stated as a rule:

> **Portable contract, native implementation.**
> What gets *written down* — on a drive, in the catalog, as a hash — is defined
> by specification and is identical everywhere. How a platform *arrives at* it
> is that platform's business, and it should use everything it has.

Which gives a test for any platform-specific optimisation:

> **Does using it change a recorded fact, or only how fast the fact was
> reached?**

APFS `clonefile` makes a copy on the same volume nearly free. The recorded
fact — a replica exists on this target, with this content hash, this size —
is byte-for-byte what a plain copy would have recorded. That is allowed, and
declining it would be silly. Windows' USN journal tells you which files changed
without a scan; the facts it leads you to are the same facts a scan would find.
Also allowed.

What is not allowed is a platform capability becoming load-bearing for
correctness: a hash that only Apple hardware can compute, an ordering that
depends on Foundation's collation, a drive layout that needs case-sensitivity,
a format only `NSKeyedArchiver` can read. Those turn "we used the platform" into
"we are the platform".

---

## 2. Layering, and where the code sits today

```
┌──────────────────────────────────────────────────────────┐
│  UI                                     native, per platform
│  SwiftUI · WinUI/WPF · Jetpack Compose                   │
├──────────────────────────────────────────────────────────┤
│  Adapters (ports)                       native, per platform
│  place handles · drive discovery · photo library ·        │
│  background scheduling · file watching · zip reading      │
├──────────────────────────────────────────────────────────┤
│  Application logic                      portable by design
│  replication planning · import · policy · projections     │
├──────────────────────────────────────────────────────────┤
│  Conformance kernel                     portable by SPEC   ← §3
│  hashing · Merkle · HLC · segment codec · merge rules ·    │
│  catalog schema · path normalisation                      │
└──────────────────────────────────────────────────────────┘
```

### The audit

I checked what the existing code actually depends on, rather than assuming.
**The result is much better than expected:**

- **`Domain/` imports nothing another platform would not have.** `Foundation`
  unconditionally; anything else only behind `#if canImport(...)` with a
  fallback that compiles without it — `Digest256` over `SHA256Reference` is the
  worked example, and is what CryptoKit became (hazard 4 below). The domain
  model — assets, targets, storage groups, policy, replication, residency,
  takeout — is portable. It was written that way before the goal was stated.

  Enforced by `DocumentedRulesTests`, not counted here: a tally of how many
  files comply is wrong the next time somebody adds one, and no reader can tell
  a stale tally from a true one.
- The Apple coupling is concentrated where it belongs: all of `UI/`, plus
  `Services/ApplePhotosConnector.swift` (`ApplePhotosVerifier`,
  `ApplePhotosConnectionState`), `TargetMonitor`, `ThumbnailCache`.

Five hazards were found in the kernel layer. **All five are now addressed.**

| | Hazard | Why it matters | State |
|---|---|---|---|
| **H1** | `HashingService.quickChecksum` was a bespoke algorithm defined only by its Swift implementation | A Windows client windowing the file differently gets a different checksum for an identical copy — good copies reported as damaged, or damaged as good. | **Fixed** — written down as [`SPEC-hashing.md`](SPEC-hashing.md) §3, pinned by `HashingConformanceTests`. |
| **H2** | `MerkleTree` sorted leaves with Swift's `String <` — Unicode collation, not byte order | Rust, Kotlin and C# order non-ASCII differently. Two platforms build different trees from identical content and permanently disagree about what diverged. | **Fixed** — `ByteOrdering`, bytewise over UTF-8. The tree itself has since been deleted as dead code, but the fix outlived it: `MetadataRecord.fingerprint` and the clock's tie-break both use it. |
| **H3** | Zip reading and extraction shelled out to `/usr/bin/unzip`, `tar` and `ditto` | Absent on Windows and Android. Needs a real zip reader, not a shim. | **Fixed** — `ZipContainer`, `ZipReader`, `ZipExtractor`. Also fixed a live name-mangling defect; see below. |
| **H4** | `CryptoKit` in `Domain/MerkleTree.swift` and `Domain/MetadataRecord.swift` | The only thing keeping two otherwise-portable domain files Apple-only. | **Fixed** — `Digest256` seam; CryptoKit on Apple, `SHA256Reference` elsewhere. |
| **H5** | Foundation's default `Date`/`Codable` encoding in a written format | `Date` encodes as seconds-since-2001. A non-Apple reader is 31 years wrong, silently. | **Not a live bug.** Everything through `encodeJSON` is UUIDs and strings, `SQLValue.date` already uses Unix epoch, and `TargetMarker` carries no dates. Stays a *rule for the segment format*, not a fix. |

H2 turned out to have a second site nobody had looked at:
`MetadataRecord.fingerprint` sorted **JSON object keys** the same way, and those
are provider-supplied and not guaranteed ASCII. That fingerprint is stored in
`metadata_schemas`, so two platforms could have fingerprinted one schema as two.
Fixed with the same rule.

Neither H1 nor H2 bit anything today — Merkle keys are UUIDs, and for ASCII the
two orderings agree. Both would have bitten the first time a key was a filename,
by which point years of roots and checksums would have been recorded under an
unwritten rule. That is why these were done first rather than at porting time.

### H3, and why it turned out to be smaller than it looked

It was load-bearing rather than a corner: all but a couple of dozen photographs
in this archive live inside Takeout zips on the drives, so a client that cannot
read them sees almost nothing. (21,380 of 21,401, when it was counted in
August 2026 — a reading of one archive on one day, which is what the benchmark
tables below extrapolate from and the only reason a figure appears at all.) And it could not be a shim — what a second
platform needs is entry contents that are **byte-identical**, because the hash of
those bytes is a recorded fact.

The estimate assumed the hard part was inflate, and it was not. Zip stores raw
DEFLATE (RFC 1951), which every target platform already has: `Compression` on
Apple, zlib on Windows, `java.util.zip.Inflater` on Android. What actually had to
be written was the **container parse** — end of central directory, zip64, central
directory, local headers — which is a few hundred lines of ordinary byte reading
with no algorithm in it at all.

Doing it also fixed a live defect rather than only unblocking a port. `unzip`
replaces every non-ASCII byte in a name it prints with a literal `?`, and `?` is
its own wildcard, so asking for the entry back matched nothing: a photograph
whose name carried a narrow no-break space — every screenshot Google exports —
was recorded as absent from the drive it was sitting on.

**State: closed.** `ZipContainer` parses, `ZipReader` reads, `ZipExtractor`
writes to disk, and `ParallelZipExtraction` runs several readers concurrently
instead of several `unzip` processes. `diskutil` remains, and is allowed to:
it only picks a worker count, which is a speed hint and not a recorded fact —
exactly the distinction §1 draws.

---

## 3. The conformance kernel

The set of things that must be **bit-identical on every platform**, or the app
silently corrupts its own understanding of what is safe.

This set is deliberately small. Not everything needs to be shared — a wrong
count on a screen is visible and fixable, while a wrong content hash can end
with the app deleting the last copy of a photograph because it believed a
replica was good. **The kernel is scoped by blast radius, not by convenience.**

| Must be identical | Because divergence means |
|---|---|
| Content hash (SHA-256, hex, lowercase) | False duplicates, or a copy believed good that is not |
| Quick checksum (H1) | Copies compared across platforms disagree |
| Bytewise string ordering (H2) | Two devices order the same keys differently and hash them differently |
| HLC encoding and comparison | Conflicts resolve differently on different devices — divergence that never heals |
| Segment format and parse rules | A client cannot read another's log, or reads it wrong |
| Merge/LWW rules and tombstone semantics | The archives never converge |
| Catalog schema for global tables | Fields silently dropped across platforms |
| Path and filename normalisation | The same replica seen as two, or two as one |

Everything else — the replication planner, import, projections, the UI,
duplicate presentation — can be reimplemented natively. Those produce visible,
correctable results.

### Specifying, not just sharing

The mechanism is a written spec plus **conformance test vectors** — fixed inputs
and their required outputs, committed to the repo, reproduced by every
implementation on every platform. The hashing half now exists:

| | |
|---|---|
| [`docs/SPEC-hashing.md`](SPEC-hashing.md) | content hash, quick checksum, Merkle, schema fingerprint, string ordering |
| `Tests/…/HashingConformanceTests.swift` | 17 vectors, the executable form of it |
| [`docs/SPEC-format.md`](SPEC-format.md) §1 | the hybrid logical clock — value, ordering, encoding, drift bound |
| `Tests/…/HybridLogicalClockTests.swift` | 16 vectors |
| `docs/SPEC-format.md` §2–4 | *not yet written* — change record, segment format, on-drive layout |

Everything in the vectors is a **fixed expected value**, never a round trip. A
test that hashes something and compares it to itself passes on every platform
and proves nothing.

The Merkle root vector was derived independently — by applying the written rules
with `shasum` in a shell — rather than copied out of the Swift. That is what
makes it a check of the implementation against the specification instead of
against itself, and it is the standard the remaining vectors should meet.

Deliberately covered: the 55/56/57-byte SHA-256 padding boundary, agreement
between the accelerated and reference implementations, the 4 MiB quick-checksum
boundary, an empty file, truncation, a single byte changed inside a sampled
window, odd-node promotion, and ordering **where bytes disagree with the
platform's native collation**.

### The algorithms, as they stand

Written out because "read the Swift" is not a specification, and because these
are already load-bearing.

**Content hash.** Streaming SHA-256 of file contents, lowercase hex. Contents
only — never resource forks, extended attributes, or any filesystem metadata.
Those do not survive a round trip through exFAT and are not the same on any two
platforms.

**Quick checksum** — a deliberately partial fingerprint, SHA-256 over:

1. the file's byte length, as decimal ASCII
2. if length ≤ 4 MiB: the whole file, and stop
3. otherwise: the first 2 MiB
4. then, for `i` in 1…6: 512 KiB at offset `floor(length × i / 7)`
5. then the last 2 MiB

Lowercase hex. Reads that run short at EOF contribute what they got. The
constants are the specification, not tuning parameters — changing one
invalidates every stored checksum.

**Merkle tree.**

- `leaf = SHA-256("leaf:" ‖ key ‖ 0x1F ‖ digest)`, key and digest as UTF-8
- `node = SHA-256(0x01 ‖ left ‖ right)` over raw 32-byte digests
- an odd node at a level is **promoted unchanged**, never paired with itself
- leaves sorted by key — **to be specified as bytewise over UTF-8** (H2), which
  matches today's behaviour for the ASCII keys in use
- root rendered lowercase hex only at the boundary

The domain separation (`"leaf:"`, `0x01`) is already right and should be stated
as required, not incidental.

### Which language for the kernel

Not a decision that has to be made now, and the spec-plus-vectors approach is
what makes deferring it safe. When it arrives:

- **Reimplement per platform against the vectors.** No FFI, no build complexity,
  fully native everywhere. The vectors carry the risk. Viable precisely because
  the kernel is small.
- **Shared core in Rust via UniFFI.** The textbook answer — generates idiomatic
  Swift and Kotlin — and what Signal, 1Password and Mozilla do. Costs a rewrite
  of the kernel and the project's first dependency.
- **Swift everywhere.** Swift on Windows is real; Swift on Android is improving
  but not yet something to bet a product on. Worth re-checking when a client is
  actually being built rather than ruling in or out today.

The order matters: **write the spec and vectors first, choose the language
later.** Doing it the other way round means the format is whatever the chosen
language made convenient.

---

## 4. Using each platform to advantage

Encouraged, under §1's rule. Concretely, and none of it load-bearing:

| Platform | Worth using | For |
|---|---|---|
| **macOS** | DiskArbitration, FSEvents | Instant mount notification; change detection without scanning |
| | APFS `clonefile` | Near-free replica copies within a volume |
| | `F_FULLSYNC` | Real durability before a segment is declared written |
| | PhotoKit | The Photos library |
| | Spotlight exclusion | Keeping the replica folder out of the index |
| **iOS/iPadOS** | Files / document picker, PhotoKit | Drive access and library access |
| **Windows** | **NTFS USN journal** | Cheap, exact "what changed since" — better than anything on macOS for this app |
| | `WM_DEVICECHANGE` | Mount notification |
| | ReFS block cloning, VSS | Cheap copies; consistent snapshots |
| **Android** | Storage Access Framework, MediaStore | Drive access, media library |
| | WorkManager | Background sync when a drive is attached |

The pattern to hold to: each of these is an **adapter behind a port**, and every
port has a portable fallback. A platform with nothing special still works by
scanning and copying — slower, identical results. That fallback is not dead
code; it is what proves the optimisation did not change a fact, and it is worth
testing on every platform even where the fast path exists.

---

## 5. Permissions: the place handle

The abstraction that makes drive access portable, and the one that reframes what
looked like an Apple problem.

Every sandboxed platform has the same concept: **a durable handle to a place the
user granted access to, which survives relaunch and cannot be transferred.**

| Platform | Mechanism | Transferable? |
|---|---|---|
| macOS / iOS | Security-scoped bookmark | No — bound to device **and code signing identity** |
| Android | SAF persisted URI permission | No — bound to the app on that device |
| Windows | A path. No mechanism needed | n/a |
| Linux | A path | n/a |

So the port is:

```
PlaceHandle
  grant(from user choice) -> Handle
  resolve(Handle)         -> path, or "not attached"
  release(Handle)
```

macOS and iOS implement it with bookmarks, Android with
`takePersistableUriPermission`, Windows and Linux with a stored path.

**This reframes §6.1 usefully.** "The user must point at each drive on each
device" is not an Apple quirk to be worked around — it is how sandboxed
platforms work, and Android will impose exactly the same requirement. Windows is
the exception that gets it free. Designing the onboarding around a per-device
grant is designing for the majority case, not conceding to one vendor.

And the constraint stays absolute: **a place handle never goes on a drive, in
the catalog, or through a courier.** It is meaningless anywhere but where it was
minted. `TargetBookmarks` already says so:

> **Deliberately not stored in the catalog.** […] a bookmark is meaningful only
> to the device — and the code identity — that made it.

What *can* be shared is the knowledge that a place exists — its name, marker
token, and what it holds. That is what lets a new device show a checklist it
understands instead of an empty app. And drive-carried sync does this better
than a cloud could: plugging in Drive 1 both grants access to it *and* delivers
the knowledge that Drives 2 and 3 exist. One action.

---

## 6. What travels, and the write model

### 6.1 The state split

Roughly a third of what drives the UI is a statement about *this device, right
now*. Syncing it would be actively wrong.

**This classification now lives in code**, as
[`CatalogScope`](../Sources/HeykinnClicks/Persistence/CatalogScope.swift), with
a test that fails when a table exists in the schema and is not classified. A
list that lives only in prose is a list somebody forgets to add to, and the
question is cheap to answer while writing a table and awkward to answer for
sixteen tables at once, later.

| Kind | Tables / values | Why |
|---|---|---|
| **Global** | `assets`, `sources`, `storage_groups`, `policy_rules`, `metadata_records`, `metadata_schemas`, `asset_tags`, `takeout_archives`, `import_batches`, `migration_jobs`, `export_capture_versions` | True regardless of which device asks. This is what "one archive" means. |
| **Global, locally observed** | `replica_states`, `drives` | A property of (asset, drive), not of a device. Only one device sees a drive at a time, so writes rarely contend — but still need ordering. |
| **Append-only** | `audit_events` | Free. The union of two logs is a valid log. |
| **Irreducibly local** | place handles, `AccessGrants`, **`drive_local_state`**, reachability, the archive lock, test-mode flag | Meaningless elsewhere. `/Volumes/My Passport` is not a fact about another device — and on Android it would not even be a path. |
| **Cache** | `import_scan_memo` | Already documented as "Cache, not record — losing it costs time and nothing else." Keyed by local path; never travels. |
| **Local queue** | `replication_tasks` | An intention to copy bytes onto a drive *this device can reach*. Each device derives its own from shared `replica_states`. |

The bottom three rows are why "put the catalog on the drive" cannot work even
setting concurrency aside: device-local state was interleaved with global state
in the same tables. **This is a schema split, not just a sync layer.**

### The `drives` split, done

`drives` held both kinds at once. `last_seen_at`, `last_mount_path` and
`configured_path` moved to `drive_local_state`; identity — `name`,
`marker_token`, `replica_root`, `volume_uuid`, `kind`, `registered_at` — stayed.

`configured_path` moved for an extra reason beyond being useless elsewhere: a
host-device target belongs to exactly one device, so another device resolving
its folder would be reaching for a path that exists there under a different
owner. Actively misleading rather than merely inert.

Two decisions worth recording:

- **`ReplicationTarget` did not change.** The split is a storage boundary, not a
  domain one — every screen still wants the name and the mount path together.
  `fetchTargets` LEFT JOINs, so a target registered on another device comes
  back listed with no path, which is the truthful answer and exactly the state
  such a target will arrive in once targets travel.
- **The old columns are still written, and no longer read.** A build predating
  the split is installed right now and reads them there. Reads come only from
  the new table, so the two cannot disagree about which is authoritative, and
  the three bindings come out once no such build is in use.

### 6.2 Whole-row upserts are the blocker

Device A marks a photo verified on My Passport. Device B, from a copy loaded at
launch, moves it to a different storage group. Both write whole rows —
[`CatalogStore.swift:329`](../Sources/HeykinnClicks/Persistence/CatalogStore.swift)
rewrites all 27 asset columns on conflict, and fifteen upserts across
`Persistence/` share the shape. Whoever writes second erases the other silently,
and the catalog stays perfectly readable while describing something untrue.

[`ArchiveLock`](../Sources/HeykinnClicks/App/ArchiveLock.swift) makes this
impossible today by allowing one process per archive — its own comment gives the
reason. `flock` has no reach across devices, and there is nothing underneath it.

### 6.3 Last-writer-wins per field

Each syncable row carries ordering metadata:

```
device_id   TEXT   -- stable per installation
updated_at  TEXT   -- hybrid logical clock
```

A **hybrid logical clock**, not a wall clock. Devices' clocks disagree and there
is no server to arbitrate, so a device five minutes fast would win every
conflict forever. An HLC carries a monotonic counter beside the wall time and
breaks ties on `device_id` — a total, stable order with no clock authoritative.
This matters more with drives than it would with a server: a drive can deliver a
change written weeks ago, badly out of wall-clock order.

Its encoding is kernel-level (§3): a fixed-width, lexicographically sortable
string, specified explicitly. Not `Date` (H5), and not a platform's default
timestamp rendering.

Per *field* rather than per row so both writes above survive — verification
lands on `last_verified_at`, regrouping on `storage_group_id`, neither reaching
for the other. Per-row LWW still loses one.

### 6.4 Deletes need tombstones

A row deleted on Device A and absent on Device B is indistinguishable from one
never seen, so a naive merge resurrects it. Rows carry `deleted_at` in the same
clock; reads filter them.

The app already has the instinct — `deleteReplicaState` is documented as only
for claims never made good: "A row describing bytes that exist is never dropped
this way: losing the record of a copy is how the app ends up unable to find,
check, or reclaim it." Tombstones extend that discipline.

Implemented as a `change_row_tombstones` table rather than a column, so a
deletion does not require the row to still be there. A write stamped later than
the tombstone legitimately brings the row back; one stamped earlier does not.

### 6.5 What building it taught

Two things that were not visible from the design.

**Stamping every column on a write is per-row LWW in disguise.** Every upsert
here rewrites the whole row, so the obvious implementation — stamp all columns
with the new stamp — has each write claim authorship of every field. A device
that changed only `desired_copies` then overwrites another device's rename with
the stale label it happened to be carrying. The per-field test caught it at
once: *both* devices lost the rename. The journal has to stamp **only the
columns whose values actually moved**, which means wrapping the write and
reading the row before and after — an upsert statement does not itself know
which values changed.

**Ordering inside the catalog's own startup.** Some schema migrations write rows
— moving per-source policies into storage groups is one — so the journal must be
open *before* `applySchema`, or those writes are never stamped. That in turn
exposed a cache which remembered "no such table" from a moment when the table
genuinely did not exist yet, and would have silently stopped stamping it
forever.

### 6.5a The gap a table-level test could not see

`JournalCoverageTests` asserts every shared table records *something*. That is
weaker than it looks, and it gave false confidence. A table can be journalled on
its main upsert and still have several other statements writing to it directly —
**eleven did**: assigning a photo to a group or a source, photos losing both
when one is deleted, repointing a copy that moved on a drive, withdrawing an
unearned verification, clearing tags, deleting a photo. Every one would have
produced a change no other device was ever told about.

Two things make this class of bug easy to miss:

- **The failure is silent and delayed.** Nothing errors; one device just
  quietly holds a different answer from the other.
- **A naive test passes anyway.** A row's creation is recorded as one whole-row
  stamp that expands to every column *at send time, reading current values* — so
  an unrecorded change to a row the other device has never seen still travels,
  carried by the creation. It only bites once the row is already known
  elsewhere. The first version of `JournalWritePathTests` created and modified in
  one breath and passed with the bug still in place; it earns its name only
  because each case now syncs first, then changes, then syncs again.

One deliberate exception, recorded so nobody "fixes" it: `projected_version` is
not journalled. It records that *this* device has read a payload with *this*
version of the reader — work, not archive. The conclusions it produces
(`asset_id`, `scope`) do travel, and a device that re-derives them writes the
same values, which is no change and therefore no news.

### 6.6 What the measurement changed

One stamp row per changed field is free for storage groups. On `assets` it was
not, and the number decided the design rather than the schedule:

| | fresh 2,000-asset import | extrapolated to 21,400 |
|---|---|---|
| One entry per column | 29 entries/asset | 7.8 s, 620,600 entries |
| One entry per new row | 1 entry/asset | **2.5 s**, 21,400 entries |

And the path that had never been measured at all — a new device meeting a full
archive for the first time, which is what happens when a drive is plugged into a
second device:

| | 2,000 assets (58,000 records) | extrapolated to 21,400 |
|---|---|---|
| As first written | 31.6 s | **5 min 38 s** |
| One transaction for the batch | 2.0 s | 21.3 s |
| …and the quadratic scan removed | **1.0 s** | **10.7 s** |

Three causes, in order of size. **No transaction**, so every one of 58,000
records committed separately. **A quadratic scan**: building a row searched the
whole batch for its own records, which for 2,000 new rows against 58,000 records
is 116 million comparisons to answer something one pass answers for all of them.
And **re-deciding records already accounted for**: after a row is built from its
group, its other 28 records each ran three queries to reach the answer
"superseded".

Worth noting how the numbers are asserted now: in **seconds against a real
archive size**, not as a multiple of a baseline. The import baseline is a bare
`INSERT` at about ten microseconds, so any bookkeeping looks like a large
multiple of it while costing a person nothing. The tests should fail when
somebody would notice, not when a ratio moves.

A new row's 29 entries all carried the same stamp and said the same thing, so a
creation is now recorded as a single whole-row entry that expands again on the
way out. Updates still stamp per column, so nothing about per-field resolution
changed.

The measurement also caught a live bug that had nothing to do with speed. The
catalog's `JSONEncoder` had no key ordering, so `exif_json` re-encoded to a
different string on every save — meaning an asset whose EXIF had not changed
looked changed every time it was written. Harmless while the column was only
written and read back; with a journal, every routine rescan would have read to
every other device as the whole archive being rewritten. Cross-platform it is
worse: two clients ordering keys differently overwrite each other forever
without either being wrong.

### 6.6a Connecting it to the app

Metadata sync runs from the existing newly-connected handler, and **first** —
before the reconciliation steps that decide what this drive is owed. A drive
arriving from another device may carry groups, sources or replica claims this
device has never heard of, and every one of those steps reasons about who owes
what, which is a different answer once they land.

Three things the integration had to get right:

- **Sliced, not one piece.** The catalog is written on the main actor, so a
  first sync of tens of thousands of records in one go would hold the window
  still for as long as it took. Slices of 2,000 with a yield between. The
  watermark advances per slice, which also makes an interrupted first sync
  resume rather than start over.
- **Reload afterwards.** Every screen is drawn from state read at launch, so a
  merge that changed rows underneath it leaves the window showing what was true
  before the drive arrived. There is a test asserting the catalog *and* the
  screen agree, because the catalog alone passing is the failure mode.
- **Failure is reported, never fatal.** A drive that cannot be written to still
  holds photographs. Refusing to use it because its metadata would not sync
  would be the wrong trade by a wide margin.

The store-based half is public and takes any `SegmentStore`, which is what let
this be tested without a drive to plug in — and is the same seam a LAN share or
a courier folder would arrive through.

### 6.7 What is wired

**All fourteen shared tables**, including the three keyed by a combination of
columns. A whole archive — assets, drives, replica claims, groups, sources,
policies, tags, metadata, audit history — now merges into a second, empty
catalog in a test and arrives intact.

Kept honest by `JournalCoverageTests`, which writes one row to every shared
table and then asserts that **every table declared shared recorded a change**,
and that no device-local table did. A table added next year fails it until it
is wired. That matters because the failure it guards against is silent: a shared
table written without going through the journal produces edits no other device
is ever told about, and the symptom is not an error but one device quietly
missing photographs the other believes are safe.

Wiring the last thirteen turned up one more instance of the ordering hazard
(H2): `metadata_schemas` sorted provider-supplied JSON keys with Swift's `<`
before storing them. Third site of the same bug, found only because every write
path was being read carefully.

---

## 7. The on-drive protocol

### Layout

```
<mount>/HeykinnClicks/
├── Replicas/                     (existing — the photo bytes)
├── CatalogBackups/               (existing — disaster-recovery snapshots)
└── Sync/
    ├── manifest.json             format version, catalog schema version
    ├── devices/
    │   ├── 9f3c…/                one directory per device, named by device_id
    │   │   ├── device.json       name, platform, watermarks merged
    │   │   ├── 00000001.jsonl    append-only change segments
    │   │   └── 00000002.jsonl
    │   └── b71e…/
    └── checkpoints/
        └── <hlc>.sqlite          periodic compacted full state
```

The existing `CatalogBackups/` stays and keeps its own job — a whole-catalog
snapshot for surviving loss of a device. It is not a sync mechanism: two devices
cannot restore from each other's snapshots without it being last-writer-wins
with extra steps.

### One rule does most of the work

**A device writes only inside its own `devices/<device_id>/` directory, and only
ever appends.** Everything else it reads.

That single constraint removes a category of problem. No two devices write the
same file, so there is no locking on the drive, no coordination protocol, and
nothing to corrupt if a drive is mounted by two devices at once over a network
share. Merging is reading other people's directories.

It also sidesteps the worst cross-platform trap: file locking semantics differ
sharply between macOS, Windows and Android, and over exFAT and SMB they are
close to meaningless. A protocol that needs no locks needs no agreement about
locks.

### Segments

JSON Lines, one change record per line, each line carrying its own checksum,
rolled at a size cap. Chosen for removable media and for portability:

- **A yanked drive tears the last write, not the file.** Read lines until one
  fails to parse or checksum; discard from there. A torn SQLite write on exFAT
  is a far worse day.
- **SQLite locking over exFAT and network mounts is unreliable**, and these
  drives are formatted for whatever the user needed.
- **Anything can read it.** A Windows or Android client needs no SQLite build,
  no schema knowledge, and no Apple frameworks to make sense of a line of JSON.

### Merging

Each device keeps locally a **merge watermark per peer**: the highest HLC merged
from that peer. On seeing a drive it reads each peer directory, skips records at
or below the watermark, applies the rest by §6.3, and advances.

Merges are idempotent, so re-reading is harmless — the watermark is an
optimisation, not a correctness requirement. Worth preserving deliberately: a
lost watermark then costs time and nothing else.

Each device publishes its watermarks in its own `device.json`, so a person can
see what every device has caught up on.

### Pruning, and the device that never comes back

The obvious rule is that a segment may be deleted once every known device has
published a watermark past its highest HLC — and it raises a case that has to be
designed for rather than discovered: a device sold, lost or dead never publishes
another watermark and would block pruning forever. That would need retiring a
device to be a user-visible action, a change record like any other, after which
its watermark stops counting toward the low mark.

**None of that was built, because the checkpoint dissolves it.** Periodically a
device writes a compacted full-state dump at a known HLC. A device behind that
point reads the dump; a device past it needs nothing below. So segments below a
checkpoint are unreachable *by anybody*, and deleting them consults no reader at
all — no low-mark arithmetic, no waiting, and a dead device holding back nothing.
Retirement stops being a mechanism and becomes tidying.

The checkpoint is also how a new device starts without replaying years of
history, and it is what makes state the base of the protocol rather than an
optimisation on top of the log. See `SPEC-format.md` §4.

### Format rules

Non-negotiable, cheap now, expensive once devices have written years of logs:

- UTF-8 JSON. **No plists, no `NSKeyedArchiver`, nothing Foundation-specific.**
- Explicit HLC and timestamp encodings (H5). Never a language's default.
- Filenames legal on FAT32/exFAT — no colons, no reserved names, no trailing
  dots or spaces.
- **Assume case-insensitive, case-preserving filesystems.** Never distinguish
  two names by case alone. **Device ids must be unique case-insensitively**;
  this implementation mints them as lowercase UUIDs so the question cannot
  arise. Two devices writing the same id in different cases would share one
  directory on an exFAT drive, and each would take the other's segments for its
  own and skip them.
- No symlinks, no extended attributes, no resource forks — none survive.
- Path separators normalised to `/` in recorded relative paths; each platform
  converts at its own boundary.
- Unicode normalisation fixed and stated: **NFC**, applied when recording any
  path. macOS hands out decomposed forms in places, Windows and Android do not,
  and a replica recorded under two normalisations is two replicas.

That last one is a genuine, quiet cross-platform bug generator and belongs in
the vectors.

### Convergence

An epidemic protocol over sneakernet:

```
Device A ──writes──▶ Drive 1 ──carries──▶ Device B      B learns A's changes
Device B ──writes──▶ Drive 1 ──carries──▶ Device A      A learns B's changes
Device B ──writes──▶ Drive 2 ──carries──▶ Device A      redundant path
```

Every drive carries the full log, so more drives converge faster and any one is
sufficient. Plugging in *any* registered drive syncs everything.

**The honest limitation: two devices that never share a drive never converge.**
No way around that without a network — which is what §8 is for.

---

## 8. Couriers

If a network transport is ever added, it carries data **in transit only**. That
has to be structural rather than intended, and it is testable:

> **Delete the courier entirely. Nothing is lost, and every device still
> converges via the drives.**

Three properties make it hold:

- It moves the **same opaque segment files** the drives carry. No schema, no
  queries, no record types, no server-side logic.
- Segments can be **encrypted with a key that never leaves the devices**.
- **Nothing is ever only there.** A segment reaches a courier after it is
  durable on at least one drive, never before.

The consequence is the platform-independence payoff: because a courier only
moves files, *every* courier is the same adapter. A drive, a LAN share over
mDNS, a folder in iCloud Drive or Google Drive, an S3 bucket, a USB stick in the
post — one implementation, and the user picks. A cloud becomes a convenience
anyone can decline, which is the opposite of lock-in.

A **LAN adapter** is worth noting as the natural second one: it fixes §7's
limitation for two devices on the same desk, with no account and no vendor at
all.

---

## 9. Version skew

Live today, before any of this. There is no `PRAGMA user_version`; schema
evolution is additive `CREATE TABLE IF NOT EXISTS` plus `addColumnIfMissing`.
Combined with whole-row writes and two builds already sharing an app group
container, an older build can open a newer catalog and write rows back missing
columns it does not know about.

Drives make it worse, because a drive is a time device — it can carry a log
written months ago by a build nobody runs, or one written yesterday by a build
this device has not installed. Cross-platform makes it worse again: version
parity across four app stores is not achievable.

Not fixable by enforcing matching versions. Fixable by making skew loud:

1. `PRAGMA user_version` on the catalog, written on every schema change.
2. On open: older → migrate forward as now. **Newer → refuse to open**, plainly.
3. The same stamp in the on-drive manifest and every segment header, so an old
   build declines to merge a newer log rather than merging it badly. It may
   still *write* its own segments; a newer device reads those later.
4. **Format version separate from schema version.** They will not move together
   once several platforms ship on their own release cycles.

Refusing is a real cost and the right one. The alternative is an app that opens
cheerfully and describes an archive that does not match the disks.

---

## 10. Order of work

Each step ships alone. Steps 1–5 involve no drives, no sync and no second
platform — the merge model should be correct before removable media, torn
writes and physical latency join the debugging surface.

| | | |
|---|---|---|
| ~~**1**~~ | ~~`PRAGMA user_version` + refuse to open a newer catalog~~ | **Done.** Stamped on open, refused when newer, checked before a restore replaces anything. `CatalogSchemaVersionTests`. |
| ~~**2**~~ | ~~Write `SPEC-hashing.md` + vectors; fix H1, H2, H4~~ | **Done.** Spec written, `Domain/Portability/` added, 17 conformance vectors. |
| ~~**3**~~ | ~~Split device-local state out of shared tables~~ | **Done.** `CatalogScope` classifies every table with a test that catches a new one; `drive_local_state` splits the mixed columns out of `drives`. |
| **4a** | ~~Hybrid logical clock~~ | **Done.** [`SPEC-format.md`](SPEC-format.md) §1, `HybridLogicalClock`, 16 vectors. Self-contained; nothing existing changed. |
| **4b** | ~~`device_id` + per-field LWW + tombstones + the merge engine~~ | **Done.** [`SPEC-format.md`](SPEC-format.md) §2, `DeviceIdentity`, `ChangeJournal`, 13 property tests. Two catalogs merged in a test; no drive involved. |
| ~~**4c**~~ | ~~Take the remaining shared tables through `recordingWrite`~~ | **Done.** All 14, composite keys included, with a coverage test that fails when a new table is not wired. |
| ~~**5**~~ | ~~Segment codec + `SPEC-format.md` §3~~ | **Done.** JSON Lines with per-line checksums; `SegmentStore`, `DriveSync`, and a torn write among the tests. |
| ~~**6**~~ | ~~Merge on connect~~ | **Done.** Runs from the existing connect handler, in slices so the window keeps drawing, with a line on the drive's card saying what travelled. |
| ~~**7**~~ | ~~Checkpoints, pruning, device retirement~~ | **Done, and smaller than it looked.** [`SPEC-format.md`](SPEC-format.md) §4. Making the checkpoint the base rather than an optimisation removed the low-mark arithmetic and device retirement entirely — segments below a checkpoint are unreachable by anybody, so pruning consults no reader. `CheckpointSyncTests`. |
| **8** | Extract adapters behind ports (H3's zip half is done). **Surveyed:** eleven files outside `UI/` need an Apple framework, and they cluster into five ports — image and video metadata (ImageIO, AVFoundation), thumbnails, file-kind detection (UTI), volume watching (AppKit), and inflate (Compression). `ApplePhotosConnector` is not one of them: being Apple-only is what it is for. `AppStore` imports SwiftUI for `ObservableObject` alone. | Makes the portable layer actually portable. Worth doing before a second platform, not during. |
| **9** | Read-only client on another platform | The vectors are what make this safe. **The status tier is not blocked on step 8**: it needs `Persistence/` and `Domain/`, which are Foundation, SQLite and nothing else — now enforced by `DocumentedRulesTests`. Step 8 is what the *browser* tier needs, for thumbnails and metadata. |

Step 2 was moved up deliberately and is the reason to have done it first: it was
nearly free, and it is the step that stops being possible. Every day the app
runs, more checksums and trees get written under whatever rule the code happens
to implement.

---

## Open questions

- **Kernel language.** Reimplement-against-vectors, Rust + UniFFI, or Swift
  everywhere. Deferred by design (§3); worth revisiting when a real second
  client is scheduled rather than in the abstract.
- **`cr-sqlite` or hand-rolled** for §6.3. It implements the model directly.
  Costs the project's first dependency and must build for every target platform
  — a heavier constraint under a cross-platform plan than a device-only one.
- **How much of `AppStore` — much the largest file in the app — assumes it is
  the only writer?** Step 4
  is scoped as "every upsert in `Persistence/`", which may be optimistic.
- **Does the zip-as-replica feature survive cross-platform?** H3 is not just
  `/usr/bin/unzip` — it implies every client needs a zip reader that agrees
  byte-for-byte on entry extraction. Given that all but a handful of the photos
  on these drives live inside Takeout zips, this is load-bearing, not a corner.
- **Segment size cap and checkpoint cadence.** Both want measuring against a real
  archive — the one in front of us, roughly 21,400 assets and 43,000 replica
  rows when the tables above were measured, is a reasonable yardstick.
- **What does the UI say about staleness?** "Last synced from Nina's Back, three
  days ago" is honest and useful. Less clear what to say when devices are known
  to have diverged and no drive has bridged them yet.
