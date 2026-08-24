# Architecture decisions — requirement, options, choice

*What each decision was for, what else was available, why this one, and what it
cost.*

Each decision carries a status. **Decided** means the choice is settled and will
not be revisited without new evidence; **built** means the code matches it.
Three decisions are settled but not yet built, and the gap is deliberate — the
measurements that settled them arrived after the first implementation.

The working paper that produced D5, D6, D15 and D16 was `ARCHITECTURE-REVIEW.md`,
deleted once every verdict in it had shipped and been recorded here — it still
opened with "nothing here is implemented", which had stopped being true. It is
in git history if the reasoning is ever wanted; the measurements it carried are
below, re-measured after the thing was built. Decisions still
open are listed at the end.

---

## The requirements

| | Requirement |
|---|---|
| **R0** | **Never claim more than you checked.** A wrong answer about where a photograph is, is worse than no answer. |
| **R1** | Several devices, one archive, consistent behaviour across them |
| **R2** | Devices will run different versions of the app. A version difference must never cause inconsistency or silent loss. |
| **R3** | The same state across devices, so behaviour is consistent wherever you are |
| **R4** | Later iOS, and after that Windows and Android, reading the same archive |
| **R5** | No Apple or Google ecosystem lock-in |
| **R6** | Sync by sharing metadata via the connected drives |
| **R7** | If a cloud is ever used it is transit, not a store |
| **R8** | **A person who is not technical can use it without learning our vocabulary.** Every word on screen is one they already own. |

R0 is inherited from the app itself and constrains every decision below. R8
constrains what any of it is allowed to *look* like: the machinery on this page
is elaborate, and none of it may surface. A person should never meet a target, a
replica, a catalog, a marker, a residency domain, a checkpoint or a merge — those
are our words for our problems. They own drives, photos, copies, and whether
their photos are safe.

---

## D1 · Sync at all

**Requirement:** R1, R3.

**The problem.** The app was written for one device: state is loaded into memory
at launch and written back as whole rows, so the second writer wins without ever
having seen the first's changes. A lock prevents that between two apps on one
device; nothing prevents it between two devices. The result is not a crash but
a catalog that reads perfectly while describing photographs that are not where it
says. Under R0 that is the worst available outcome.

**Options**

| | |
|---|---|
| Do nothing; one archive per device | Costs nothing and fails R1. Two archives cannot answer "is this photo safe" — each sees half the drives. |
| One device is primary, others read-only | Simpler, but which device? The answer changes over time and must survive one being sold. Getting it wrong silently loses the non-primary's work. |
| **Full sync, no primary** | **Chosen.** |

**Cost:** everything else on this page.

**Status:** decided and built.

---

## D2 · Transport — how metadata gets between devices

**Requirement:** R5, R6, R7.

**Options**

| | |
|---|---|
| CloudKit | Rejected. Apple platforms only, so R4 is unreachable. Also contradicts an app whose claim is that the photographs are on your own disks. |
| A server we run | Rejected. Cross-platform, but introduces an account, a bill, a privacy surface, and something that must still exist in ten years. |
| iCloud Drive or Dropbox as a synced folder | Rejected as primary. Ties the guarantee to a vendor, and file-sync services resolve conflicts by renaming, which is not a merge. |
| **The drives already being carried** | **Chosen.** |
| A LAN share | Deferred. Same adapter; useful later for two devices in one place. |

**Why:** the photographs already travel on those disks, so metadata riding along
adds no new dependency at all. It is the only option where nothing can be
withdrawn.

**How R7 is enforced.** "Transit, not a store" is structural rather than a
promise, and has a test: *delete the courier entirely, and nothing is lost,
because every device still converges through the drives.*

**Cost:** two devices that never share a drive never converge. There is no
network path. This is inherent to the choice.

**Status:** decided and built.

---

## D3 · The merge model

**Requirement:** R1, R3, R0.

**Options**

| | |
|---|---|
| Last write wins, whole row | Rejected. Verifying a photo on one device and re-grouping it on another are not in conflict, and this discards one of them. |
| Ask the user to resolve conflicts | Rejected. "One device says this photo is in Family, the other says Holiday" is not answerable — they do not remember, and there may be thousands. |
| **Last write wins, per field** | **Chosen.** |
| Full CRDTs per type — counters, sets, sequences | Rejected as the default. Most fields are scalars a person set, where "the later one" is correct, and the machinery is large. |
| Operational transform | Rejected. Built for concurrent text editing; nothing here is text. |

**Why:** the weakest model that does not lose edits which were never in conflict.
For a scalar setting a person changed, "the later one" is not a compromise.

**And a rule that follows from it.** Per field means per *column*, so a set held
in one column is one value and does not merge — two devices each adding a
different destination to a storage group keeps one. Measured: 1 of 2 additions
survived.

> **A set that two people can add to independently is a table, not a column.**

A set expressed as rows needs no new merge machinery: each element gets its own
identity, stamp and tombstone, and the existing per-row rules do the right thing.
One column was affected, `storage_groups.destination_ids_json`, now
`storage_group_destinations`. The others holding JSON lists are either dead
(`sources.destination_ids_json`, always written `"[]"`) or derived from content
that both devices compute identically.

**One thing the move nearly broke.** Destination *order* is load-bearing — when
a group names more devices than it wants copies, placement takes them in order,
"the first device somebody lists is the one they think of as primary". Reading
the rows back sorted by id would have quietly sent copies to different drives.
The rows carry a `position`, and reads order by it with the id as a deterministic
tiebreak so two devices that assigned the same position still agree.

**Status:** decided and built.

---

## D4 · The clock

**Requirement:** R1 — two devices must resolve a conflict identically, or they
never converge and nothing can detect it.

**Options**

| | |
|---|---|
| Wall clock | Rejected. Devices disagree by seconds routinely and by hours with a wrong timezone. A fast device wins every conflict permanently. |
| Lamport counter | Rejected alone. Orders correctly but carries no real time, so nothing can be shown to a person or compared against the world. |
| Vector clock | Rejected. Detects genuine concurrency rather than forcing an order, which is more correct — but it grows with device count and still leaves "so which wins?" unanswered. The extra information is not acted on. |
| **Hybrid logical clock** | **Chosen.** |

**Why:** a wall time with a counter beside it is meaningful to a person, total
and stable as an order, and leaves no clock authoritative. Ties break on device
id, so every device breaks them the same way.

**The drift bound.** A stamp claiming a wall time more than 24 hours ahead is
refused and reported. A hybrid logical clock advances to the highest time it has
seen, so one device with a clock set to 2099 would drag every device to 2099
permanently and win every later conflict. That is unrecoverable, so the bound
errs tight.

**Why drives sharpen this:** a drive routinely delivers a change written weeks
ago, so stamps arriving out of wall-clock order is the ordinary case here.

**Status:** decided and built.

---

## D5 · How changes are captured

**Requirement:** none directly; an engineering choice underneath D3.

**Options**

| | |
|---|---|
| Callers record their own changes | Rejected. Every call site must remember. |
| Wrap each write, comparing the row before and after | Built first, and superseded. Opt-in, so a write path can be added without it — eleven were. |
| **SQLite triggers** | **Chosen.** |
| `cr-sqlite` | See D15. |

**Why:** a trigger cannot be bypassed. Capture stops being something a call site
has to remember and becomes a property of the table.

The option was originally set aside on the assumption that a trigger could not
reach a clock reading without a custom C function. Tested, and false — the app
writes the current stamp into a one-row table at the start of a transaction and
the trigger reads it. Plain SQL, no extension.

Measured behaviour:

| | |
|---|---|
| Catches an `UPDATE` no wrapper knows about | Yes |
| Per-field diffing | Free, via `WHEN OLD.x IS NOT NEW.x` |
| A rewrite that changes nothing | No stamp |
| Bulk `UPDATE` over 500 rows | 500 journal rows — fires per row |

**What it removes:** the two row reads per write; the bulk special case; and the
class of defect where a write path is added without journalling, since there is
no longer anything to forget.

**What it adds:** triggers are generated per table and column from
`PRAGMA table_info`, and must be regenerated when the schema changes. A trigger
left behind after a column is dropped is a broken write path.

**A consequence worth having:** triggers live in the SQLite file, so a client on
another platform writing to the catalog inherits the guarantee without
implementing anything.

**Two things building it turned up.**

*A merge must not fire the triggers.* Applying another device's change writes
rows, which would stamp them with **this** device's clock — so a change received
would be recorded as one this device made and published straight back, and two
devices would echo it at each other indefinitely. Every trigger is guarded by a
suppression flag the merge sets.

*There can only be one source of stamps.* Leaving the explicit
`recordDeletion`/`stampColumns` calls in place alongside the triggers put two
clocks in play — the triggers advancing a counter, the old calls advancing the
clock directly — and they went out of order, so a row deleted and re-created came
back with a stamp *below* its own tombstone and stayed dead. Twenty-one such
calls were removed and three methods deleted.

**Cost, measured:** a full import goes from 2.5 s to **5.1 s** on this archive.
The trigger bodies do three statements per row where the wrapper did two plus two
reads. That is 2.6 seconds once, against a class of silent divergence becoming
impossible.

**Status:** decided and built.

---

## D6 · What travels

**Requirement:** R6.

**Options**

| | |
|---|---|
| An operation log alone | Built first, and superseded. |
| Full state each sync | Rejected alone. Correct and simple, but rewrites the whole archive for a one-field change. |
| **A periodic state checkpoint, plus a delta log since it** | **Chosen.** |

**Why:** measurement, because the usual reasoning is wrong here in one direction
and right in the other.

| | Op-log | State dump |
|---|---|---|
| First sync onto a new device | **111 MB** | **21 MB** |
| A day's work — about 50 changed fields | **~10 KB** | 21 MB |

The log is 5.2× *larger* than writing out the whole archive on a first sync,
because a per-field record carries a 60-byte stamp and there are 29 of them per
photograph — the stamps cost more than the data. It is four orders of magnitude
smaller for ordinary use. Neither shape is right on its own.

Re-measured once the checkpoint was built, on 2,000 synthetic photographs
(`CheckpointCostTests`, `HEYKINN_BENCH=1`): **10.2 MB of log against 2.1 MB of
state, 4.9×**. The absolute numbers are smaller than the row above because those
came from a real import — real EXIF, real replica rows — and these are bare
photographs; the ratio is what carries across, and it held.

**The checkpoint is the base, not an optimisation.** That ordering is what makes
the rest fall out, and it turned out to be worth more than expected:

- **Pruning consults nobody.** A device behind the checkpoint reads the
  checkpoint; a device past it needs nothing below. So segments below one are
  unreachable by anybody, and dropping them needs no cross-device watermark
  arithmetic at all — not even the low mark that was planned.
- **Retiring a device evaporates entirely.** A dead device holds back nothing,
  so the user-visible retirement action that was going to be needed was never
  built.
- **A new device never replays history** — one checkpoint plus a few segments.

**When a checkpoint is written:** when the log since the last one exceeds it in
size. Self-tuning, and needs no cadence to be guessed at. With no checkpoint yet
the comparison is against one full segment, so a small archive never writes one.

**A related compression, already built:** creating a row is recorded as a single
whole-row stamp rather than one per column, and expands again on the way out.
Per-column stamping measured 16× slower on import and wrote 29 journal rows per
asset; as one per row it is one.

**Status:** decided and built. `SPEC-format.md` §4, `CheckpointSyncTests`.

---

## D7 · The file format on the drive

**Requirement:** R4.

**Options**

| | |
|---|---|
| A SQLite file on the drive | Rejected. A yanked drive can tear the file; locking over exFAT and SMB barely works; a client would need a SQLite build. |
| A packed binary format | Rejected. Smaller and faster, unreadable by a person debugging a drive, and every platform must agree about endianness. |
| **JSON Lines, checksummed per line** | **Chosen.** |

**Why:** a yanked drive tears the last line, which is detectable and recoverable,
and any language can read a line of JSON with nothing installed.

**Why the checksum:** truncated JSON usually fails to parse, and "usually" is not
enough. Sixteen hex characters settle it.

**Status:** decided and built.

---

## D8 · One directory per device, append-only

**Requirement:** R1, R4.

**The problem.** Two devices writing one file needs locking. File locking behaves
differently on macOS, Windows and Android, and over exFAT or SMB it barely works.

**Options:** a shared log with locking; a shared log with a lock file;
per-device directories.

**Chosen:** per-device directories, append-only. No two devices ever write the
same file, so there is no locking, no coordination, and nothing to corrupt if a
drive is mounted twice.

**Status:** decided and built.

---

## D9 · Specifying the formats

**Requirement:** R4.

**Options:** let the code be the definition; write prose; write a specification
with conformance vectors.

**Chosen:** a specification with fixed expected values, because "whatever the
Swift does" cannot be reproduced by a second implementation, and the archive is
meant to outlive this one.

**What it found:** three defects in shipping code — text sorted with Swift's
ordering, which no other language shares, in three places; JSON object keys with
no stable order, making every rescan look like a full rewrite; and device
directory names in a case that collides on a case-insensitive drive.

**Status:** decided and built.

---

## D10 · Where device identity lives

**Requirement:** R1.

**Options:** in the catalog; in preferences; in a file beside the catalog.

**Chosen:** a file beside the catalog.

- **Not the catalog** — snapshots get restored onto other devices, and the new
  device would then issue changes claiming to be the device that wrote the
  snapshot, breaking the tie-break that makes conflicts resolve identically.
- **Not preferences** — those are per sandbox container, so two builds of the app
  would look like two devices sharing one archive.

**Status:** decided and built.

---

## D11 · Splitting device-local state

**Requirement:** R1, R3.

**The problem.** `/Volumes/My Passport` is a fact about one device. On another
it names nothing; on Android it is not even a path shape. Recording something
meaningless as though it meant something is R0's failure.

**Chosen:** classify every table in code, with a test that fails when a new one
is not classified, and move the mixed columns out of `drives` into a table of
their own.

**Status:** decided and built.

---

## D12 · One protocol

**Requirement:** R7, and testability.

**Chosen:** exactly one — a place that can list, read, write and append files.

Two things earn it: more than one implementation is planned (a drive now, a LAN
share or courier folder later), and damage is otherwise untestable — a test
cannot pull a drive out of a socket, but it can hand the code a store that
misbehaves.

**Status:** decided and built.

---

## D13 · How a row is named in a change record

**Requirement:** R4 — a client on another platform must name the same row.

Most tables are keyed by one column; three are keyed by a combination
(`replica_states`, `asset_tags`, `export_capture_versions`). A record has to
carry a compound identity as one string.

**Options**

| | |
|---|---|
| Join with a separator | Rejected. A key component is arbitrary text — a filename, a tag value — so any separator can appear inside one, and escaping is a second thing every platform must implement identically. |
| A JSON array | Rejected. String escaping differs subtly between JSON writers, so the same components can produce different text. |
| **Length-prefix each component** | **Chosen** — `3:abc5:defgh`. |

**Why:** unambiguous whatever the content, with no escaping to agree on. Lengths
count **UTF-8 bytes**, so the number does not depend on how a language defines a
character. A single-column key encodes the same way, so there is one rule and no
table sits on a boundary between two.

**Status:** decided and built.

---

## D14 · Referential integrity is not enforced by the database

**Requirement:** R1 — merges must be order-independent.

The schema declares **no foreign keys**, so `PRAGMA foreign_keys = ON` currently
enforces nothing. That was accidental; keeping it is deliberate.

**Why it must stay that way.** A merge has to be able to accept a child before
its parent — records arrive in whatever order a drive is read, and a device may
learn about a copy before it learns about the photograph. Enforcing a foreign key
would reject that record, and the reader has no way to ask for the missing parent.
Order-independence and foreign keys cannot both hold.

**What replaces them.** Cascades travel as explicit changes rather than as
database actions: deleting a photo tombstones its copy records too, and deleting
a group stamps the affected photographs' group column. Both were built that way,
and both are what makes the deletion arrive complete on the other device.

**Cost:** an orphan is possible between a parent's deletion and the child's
tombstone arriving. It resolves on the next sync, and nothing reads a copy record
whose photograph is absent.

**Status:** decided and built. The inert `PRAGMA foreign_keys = ON` has been
removed rather than given constraints: left on, it claimed an integrity that did
not exist, and the first foreign key anybody added to a shared table would have
started being enforced and dropping merged rows. `CatalogScopeTests` now checks
that no travelling table declares one.

---

## D15 · Not adopting `cr-sqlite`

**Requirement:** R4, R5.

`cr-sqlite` implements CRDT change capture as a loadable SQLite extension, using
triggers — the mechanism D5 now chooses.

**Against**

- **D5 is achievable in plain SQL.** The main thing the extension would buy is
  already available with no dependency.
- **It becomes a hard runtime dependency on the archive being writable.** A
  loadable extension must be present, signed and shipped on every platform. An
  archive that needs a particular binary to be written is a weaker promise than
  one that needs only SQLite — and the archive is meant to outlive the app.
- **It would be the project's first dependency**, in the layer with the largest
  blast radius, on a build that must justify a shipped binary to App Store review.

**For:** it is battle-tested, and hand-written merge code is where subtle bugs
live. D5's triggers answer most of that by making capture declarative rather
than procedural.

**Status:** decided. Revisit only if the merge *rules* prove troublesome, rather
than the capture.

---

## D16 · The catalog stays on the main actor

**Requirement:** none directly; a constraint everything else inherits.

`CatalogStore` is written on the main actor, which is why a first sync is applied
in slices with a yield between them rather than in one piece.

**Options:** move the catalog to a background actor; give sync its own SQLite
connection on another queue; keep it and slice.

**Chosen:** keep it and slice. SQLite is already opened `FULLMUTEX` and WAL
supports multiple connections, so a second connection is genuinely tractable —
but D6 changed the shape of the work this would optimise, and the condition set
here has now been measured.

**Measured, after D6:** a first sync of 2,000 photographs from a checkpoint takes
**2.0 seconds**, applied in 2,000-record slices with a yield between them. That
is a bulk load, not hundreds of thousands of small merges, and it does not need
moving off the main actor.

**Status:** decided, and the condition discharged. Revisit only if an archive an
order of magnitude larger makes the first sync uncomfortable.

---

## Requirement → decision

| | Met by | State |
|---|---|---|
| **R0** Never claim more than you checked | D3, D4, D11 | Held |
| **R1** One archive, several devices | D1, D3, D4, D8, D10, D11 | Built and tested |
| **R2** Version differences never cause loss | Catalog and sync version stamps; a build refuses a catalog newer than itself | Built. Behaviour still differs by version; only damage is prevented |
| **R3** Consistent state across devices | D1, D3, D6, D11 | Built |
| **R4** iOS, Windows, Android | D7, D9 | Format ready; blocked by the zip reader |
| **R5** No ecosystem lock-in | D2 | Held |
| **R6** Sync via connected drives | D2, D6, D8 | Working end to end, and bounded — a drive synced for years stops growing |
| **R7** Cloud as transit only | D2, D12 | Structural |

---

## Still open

Three decisions awaiting a call. Each has been investigated and costed in
`OPEN-DECISIONS.md`, which carries the evidence and a recommendation; the
summaries below say only what is being decided.

### O1 · How zip members get read — **decided and built**

Entry listing, entry hashing and Takeout detection now read the archive's own
central directory instead of running `unzip`. Inflate comes from the platform,
so no dependency was added.

The defect this fixed was live: `unzip` mangles non-ASCII bytes in the names it
prints, and every name downstream came from that listing. On a four-file test
archive, three of four entries — a narrow no-break space, a decomposed `é`, an
emoji — were listed unreadably, and each one is a photograph the app would have
recorded as absent from a drive holding it.

**Bulk extraction has followed.** `tar`, `ditto` and the `unzip` workers are gone
too: `ZipExtractor` writes entries to disk and `ParallelZipExtraction` runs
several readers concurrently instead of several processes. That was R4 work
rather than a correctness fix — extraction writes files rather than producing
recorded facts — and it was checked first that the parallel path did *not* suffer
the name mangling that forced the single-entry path off `unzip`. It did not; a
fixture in Google's exact shape round-tripped every entry.

Two things came out of doing it anyway. Speed: **1.39× faster than the four
`unzip` processes it replaced** (0.34s against 0.47s for 1,200 photographs and
their sidecars, 229 MB), because there is no process to spawn and no argument
list to build. And a check nobody owned before — an entry named
`../../.ssh/authorized_keys` was refused by `unzip` and `tar` in their own ways,
and doing the extraction here means owning that refusal rather than inheriting
it.

`diskutil` remains, and is allowed to: it only picks a worker count, which is a
speed hint rather than a recorded fact.

### O2 · Whether other platforms read only, or also write

Three tiers, not two. A **status reader** — what exists, where the copies are,
what is at risk — needs SQLite and the schema and **none** of the kernel. A
**browser** adds zip reading, because nearly every photograph in a Google
export is inside a zip and thumbnails never leave the device that made them — and zip is a
published format with a library on every platform, so this is not kernel work. A
**writer** adds the whole kernel — clock, journal, merge, segment codec,
checkpoint — reimplemented where a mistake is silent and corrupts the shared
archive for every device.

*No line count here on purpose. Two different figures have appeared in this
paragraph, neither reproducible from any file list, and both read as precision
that was never measured. What decides the tier is that the kernel has a
specification (`SPEC-format.md`, `SPEC-hashing.md`) and conformance vectors —
whether that is two thousand lines or four changes nothing about the risk.*

The tiers are cumulative rather than alternatives: each strictly contains the one
before, so the only real question is how far to go, and the last step can be
declined indefinitely without stranding the first two.

**Recommended:** read-only, status tier first. O1 has since landed, so the
photographs are reachable as soon as somebody wants them.

### O3 · A migration job advanced on two devices

Per-field last-writer-wins takes the later stamp, which for a state machine can
move a job backwards or turn a failure into a success.

**Migration execution is not shipped** — there are no PhotoKit change requests in
the codebase, and the state machine stops at user-confirmed manual steps. The
scenario needs two devices advancing a job neither can execute.

**Recommended:** defer until migrations execute end to end. If it becomes live,
keeping migration jobs device-local is likely the cheapest correct answer, since
a migration is work happening where the drives are.
