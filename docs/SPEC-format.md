# SPEC — sync format

_Normative for §1. Version 1._

Companion to [`SPEC-hashing.md`](SPEC-hashing.md). Where that document defines
the values the app records about *files*, this one defines the values it records
about *changes* — what has to be identical across devices for the archive to
converge rather than diverge.

| Section | State |
|---|---|
| §1 Hybrid logical clock | **Specified.** Implemented, with vectors. |
| §2 Change record and merge rules | **Specified.** Implemented, with property tests. |
| §3 Segment format and on-drive layout | **Specified.** Implemented, with tests including a torn write. |
| §4 Checkpoints | **Specified.** Implemented, with tests including an interrupted and a damaged one. |

Notation follows SPEC-hashing §Notation.

---

## 1. Hybrid logical clock

The ordering primitive. Conflicts are resolved by taking the later write, so
"later" must be a function every device computes identically, without a server
to arbitrate.

Wall clocks cannot do this. Two devices disagree by seconds routinely and by
hours when a timezone is set wrong, and a device that is fast would win every
conflict permanently. A hybrid logical clock keeps a counter beside the wall
time: the wall time keeps stamps meaningful and roughly ordered against the real
world, and the counter provides a total order when wall times tie or move
backwards.

Carrying metadata on drives makes this more important, not less — a drive
routinely delivers a change written weeks ago, so stamps arrive far out of
wall-clock order as a matter of course.

### 1.1 Value

A stamp is three fields:

| Field | Type | Meaning |
|---|---|---|
| `wallMillis` | signed 64-bit | milliseconds since the Unix epoch |
| `counter` | unsigned 32-bit | events sharing a wall millisecond |
| `deviceID` | non-empty string | the installation that issued it |

### 1.2 Ordering

Total order, compared in this sequence:

1. `wallMillis`, numerically;
2. `counter`, numerically;
3. `deviceID`, **bytewise over UTF-8** (SPEC-hashing §1).

The device id is never omitted from the comparison. Without it two devices can
produce equal stamps for different events, and "later wins" stops being a
function — two devices would pick different winners and never converge. Which
device wins such a tie is arbitrary; that every device makes the *same*
arbitrary choice is not.

### 1.3 Encoding

```
<wallMillis, 15 digits, zero-padded> "-" <counter, 6 digits, zero-padded> "-" <deviceID>
```

Example — `wallMillis` 1700000000000, `counter` 42, device `device-a`:

```
001700000000000-000042-device-a
```

- **Fixed width and zero-padded**, so a plain text comparison gives the same
  answer as §1.2 for the two numeric fields. An implementation may sort stamps
  without parsing them, and `"9"` sorts after `"10"` as text.
- 15 digits reaches the year 33658. The field never widens; a field that changes
  width stops sorting as text.
- 6 digits allows 999,999 events in one millisecond before carrying.
- **Parsing splits on the first two hyphens only.** A device id may contain
  hyphens, and every UUID does.
- Written into JSON as this string, never as an object.

A stamp that does not parse is skipped by the reader, not treated as an error:
malformed input arrives from a file on a drive, where the decision is to ignore
that record and carry on.

### 1.4 Issuing

Let `physical` be the device's current clock in milliseconds, and `(lastWall,
lastCounter)` the state carried from the previous stamp.

**`now()`** — for a local change:

```
if physical > lastWall:  lastWall = physical;  lastCounter = 0
else:                    advanceCounter()
```

**`observe(remote)`** — after reading a change from another device, so that
everything issued afterwards sorts after it:

```
if remote.wallMillis > physical + maximumDrift:
    refuse remote's wall time; return now()

highest = max(lastWall, remote.wallMillis, physical)
if highest == lastWall and highest == remote.wallMillis:
    lastCounter = max(lastCounter, remote.counter); advanceCounter()
elif highest == lastWall:
    advanceCounter()
elif highest == remote.wallMillis:
    lastCounter = remote.counter; advanceCounter()
else:
    lastCounter = 0
lastWall = highest
```

**`advanceCounter()`** — increments, and **carries into `wallMillis`** when it
would exceed 999,999. It must never wrap: a wrapped counter reissues a stamp
already used, and the entire order rests on that not happening.

### 1.5 Two requirements that are not obvious

**State must survive a relaunch.** The last stamp issued is persisted and handed
back on the next launch. A generator that starts fresh can reissue a stamp it
has already used — and two different changes sharing one stamp is the single
failure the order cannot absorb.

**Received wall times are bounded.** `maximumDrift` is **24 hours**. A stamp
claiming a wall time further ahead than that is refused: the change itself is
still accepted, only its claim about *when* is discounted, and the refusal is
reported rather than swallowed.

This bound is what stops one broken clock capturing the archive. A hybrid
logical clock advances to the highest wall time it has seen, so a device whose
clock reads 2099 would drag every other device to 2099 permanently, and every
later conflict would resolve in favour of whoever was wrong. The failure is
asymmetric — too tight a bound clamps the ordering of a mis-set device while
its data still merges; too loose a bound is unrecoverable — so the bound errs
tight. A day absorbs timezone and DST mistakes and modest drift, and refuses
what is really a wrong clock rather than an inaccurate one.

### 1.6 Conformance

`Tests/HeykinnClicksTests/HybridLogicalClockTests.swift`. Beyond the encoding
vectors, an implementation must reproduce:

- stamps strictly increasing while the physical clock stands still
- stamps strictly increasing while the physical clock moves **backwards**
- a resumed generator never reissuing a stamp, with the clock now reading earlier
- the counter carrying into `wallMillis` at its limit rather than wrapping
- observing an old stamp not moving the clock backwards
- a stamp beyond the drift bound refused *and reported*
- two devices with independently drifting clocks trading stamps over many
  rounds, producing no duplicates and no inversions

---

## 2. Change record and merge rules

The unit that travels: **one field's value, or one row's deletion**, stamped.

Field-scoped rather than row-scoped because two devices editing different
columns of one row are not in conflict. Verifying a photo on one device and
re-grouping it on another are independent facts, and a row-scoped record throws
one of them away for nothing.

### 2.1 Shape

| Key | Meaning |
|---|---|
| `t` | table name |
| `r` | row id, as text — the value of the table's single primary-key column |
| `c` | column name; **absent means this is a row deletion** |
| `v` | the value; absent for a deletion |
| `h` | the stamp, encoded per §1.3 |

A deletion has no column because it is not a value — it is the absence of the
whole row, and encoding it as a column would make "which column is deleted" a
question with no answer.

### 2.2 Values

Tagged, one key per storage class:

```
{"s": "…"}   text        {"i": 42}    integer
{"r": 1.5}   real        {"n": true}  null
```

Tagged rather than using JSON's own types because JSON does not distinguish an
integer from a float and SQLite does. `1` and `1.0` are the same JSON number and
different SQLite values, and a column that silently changed storage class on the
way through another device would be very hard to see.

**JSON stored inside a column must have its object keys sorted.** Several
columns hold JSON — `exif_json`, `destination_ids_json` — and the *text* is what
gets compared, so an encoder with unstable key order makes an unchanged value
look changed. Swift dictionaries have no defined iteration order, and this was
live: re-saving an asset whose EXIF had not changed produced a different string
every time, which a change journal reads as a change. A routine rescan would
have looked to every other device like the whole archive being rewritten. Two
clients ordering keys differently would overwrite each other's value forever
without either being wrong.

### 2.3 What a write produces

A local write emits a record for **each column whose value actually changed**,
all sharing one stamp.

Only the changed columns, and this is load-bearing. Every upsert in this catalog
rewrites a whole row, so stamping every column would have each write claim
authorship of every field — a device that changed only one column would
overwrite another device's edit with whatever stale value it happened to be
carrying. That is row-scoped last-writer-wins wearing field-scoped clothing, and
it silently loses edits that were never in conflict.

**Creating a row stamps every column**, because against a row that does not
exist every column has changed. That is also what allows another device to build
the row from scratch.

A creation may be recorded as a **single whole-row entry** rather than one entry
per column — the implementation writes the column name `*`, which no real
column can be called. A field's effective stamp is then the later of its own
entry and its row's whole-row entry, and emitting expands a whole-row entry back
into one record per column, so what travels is unchanged either way.

This is a storage compression, not a coarsening of the merge: updates after
creation still write per-column entries, and per-field resolution is unaffected.
It exists because it was measured. Stamping each column separately made a
2,000-asset import **16× slower** and wrote 29 entries per asset — 620,000 for a
21,400-asset archive, on the one path a user waits for. As one entry per new
row it is 5.5× and 21,400 entries.

### 2.4 Merge

For each record, oldest stamp first:

1. **Reject** unless `t` is a table that travels — see `CatalogScope`. Records
   arrive from a file on a removable drive, so a table name in one is input,
   never instruction, and nothing outside the allow-list may reach a statement.
2. **Reject** unless `t` exists in the live schema, has a single primary-key
   column, and `c` is one of its columns.
3. **Deletion**: skip if a tombstone at or after `h` exists, or if any field of
   the row was written after `h` — a later write is a legitimate re-creation.
   Otherwise delete the row and record the tombstone.
4. **Set**: skip if a tombstone later than `h` exists (the deletion wins), or if
   the local stamp for that field is at or after `h`.
5. Otherwise apply the value, stamp the field with `h`, and clear any tombstone
   older than `h`.
6. A row that does not exist locally is created from every record for it in the
   same batch. If that does not carry every NOT NULL column, the row is
   **rejected and counted**, never partly created.

### 2.5 The properties this must have

These are what conformance means, and each fails silently if it fails at all —
the catalog stays perfectly readable while describing something untrue.

- **Idempotent.** Merging the same records twice is merging them once. Drives
  are re-read constantly; a merge that cannot be repeated cannot be retried.
- **Order-independent.** Any arrival order gives the same final state. Drives
  deliver in whatever order they are read.
- **Convergent.** Two devices that have seen the same records hold the same
  values — including agreeing on *which* write won a genuine conflict. Two
  devices that resolve one conflict differently never converge again.
- **Deletions do not resurrect**, and writes after a deletion do.

### 2.6 Conformance

`Tests/HeykinnClicksTests/ChangeJournalTests.swift`, which states these as
properties rather than as examples of one merge going well — including a
shuffled-arrival test across several attempts, a repeat-merge test, and both
sides of the deletion/re-creation case.

---

## 3. Segments and the on-drive layout

### 3.1 Layout

Under the drive's `HeykinnClicks/Sync/`:

```
manifest.json                 what this directory is
devices/<device_id>/device.json
devices/<device_id>/00000001.jsonl
devices/<device_id>/checkpoints/00000001/state.json
devices/<device_id>/checkpoints/00000001/00000001.jsonl
```

**A device writes only inside its own `devices/<id>/` directory, and only ever
appends.** Everything else it reads. No two devices write the same file, so
there is no locking, no coordination, and nothing to corrupt if a drive is
mounted twice over a share — which matters because file locking differs between
macOS, Windows and Android and is close to meaningless over exFAT or SMB. A
protocol that needs no locks needs no agreement about locks.

Segment names are the index zero-padded to 8 digits, so they sort as text.
Segments roll at **4 MiB**, checked before appending, so a reader may assume one
fits in memory.

### 3.2 Line format

```
<16 lowercase hex> <space> <compact JSON of the record> <newline>
```

The checksum is the first 16 hex characters of `SHA256(json bytes)` — 64 bits,
enough to catch truncation and corruption, which is all it is for. The JSON is
encoded with **sorted keys and unescaped slashes**, so the same record always
produces the same bytes and two implementations can be compared byte for byte.

### 3.3 Reading

Take lines until one fails; keep everything before it; stop. Stop rather than
skip — a bad line means the file is not what it claims, and reading past it
would treat damaged bytes as authoritative. A reader also stops reading a
device's *later* segments once one is damaged, since those were written after
the damage.

Three ways a line fails, all treated alike: no separator (the usual shape of a
torn tail), a checksum mismatch, or JSON that is not a record.

### 3.4 Torn writes, and recovering from them

An interrupted append can only damage the tail. Three rules make that survivable,
and all three are needed — the first two alone are not enough:

1. **A writer records what it published only after the segment is written.** If
   it dies between the two, the records are simply written again, and a merge
   discards the duplicates. The other order loses them silently.
2. **A writer verifies its own tail before deciding what is new.** A drive can
   be damaged *after* a successful publish, and then the writer's note says
   "sent" while the drive says otherwise — so those records would never be
   offered again by anyone. On each publish a device reads back its own newest
   segment and takes the lower of what it believes it sent and what is actually
   still readable. The cheap check first: if the newest segment decodes whole,
   nothing earlier can have been damaged by an append.
3. **A writer truncates its own damaged tail back to the last complete line
   before appending.** Without this, the new record is spliced onto the
   half-written one and the file stays corrupt from that point — and because
   readers stop at the first bad line, that would block every record written
   afterwards, permanently, for every device that ever reads the drive.

A device repairs only its own directory, so this never breaks rule 3.1.

### 3.5 `manifest.json`

```json
{"formatVersion": 1, "catalogSchemaVersion": 1}
```

Both are checked before anything is read or written, and both refuse a drive
written by a newer build. They are separate because they move separately: the
layout can change without the catalog schema changing, and once several
platforms ship on their own release cycles they will not stay in step.

The manifest is written **last** on a first publish, so a directory only claims
to be a sync directory once it holds something.

### 3.6 `device.json`

```json
{"id": "...", "name": "...", "platform": "macOS",
 "published": "<stamp>", "seen": {"<peer id>": "<stamp>"},
 "logFloor": "<stamp>"}
```

`published` is how far this device has written here. `seen` is how far it has
read every other device — published so a person, or a future tool, can see what
each device has caught up on. `seen` is written again after merging, not only
after publishing: it is *learned* during a merge, so writing it only on publish
would leave it permanently describing the sync before last.

`logFloor` is the stamp below which this device's segments **no longer exist**,
because a checkpoint covers them. Absent until something has been pruned. A
reader whose watermark for this device is older than the floor cannot be served
by the log at all and must read the checkpoint (§4.3).

### 3.7 Conformance

`Tests/HeykinnClicksTests/DriveSyncTests.swift`. Beyond the round trip, an
implementation must reproduce: a drive read twice applying nothing the second
time, a device ignoring its own segments, a deletion travelling and not being
resurrected by a device that still holds the row, a torn tail costing only the
records inside it, **those records arriving on the next sync**, an empty drive
being empty rather than an error, and a newer manifest being refused.

---

## 4. Checkpoints

**A checkpoint is a dump of the whole archive's state; the segments after it are
the delta.** That ordering is the design, not an optimisation on top of the log:
a device that has never seen the archive reads one checkpoint instead of
replaying every change ever made, and every segment a checkpoint covers can then
simply be deleted, which is the only reason a drive synced for years does not
grow without bound.

The reason is arithmetic. A per-field record spends a 60-character stamp, a table
name and a row id to deliver one value, and there are 29 fields to a photograph —
so the bookkeeping outweighs the data. Measured on 2,000 synthetic photographs:
**10.2 MB of log against 2.1 MB of state, 4.9× smaller.** The same comparison on
a real archive's first sync measured 111 MB against 21 MB. For a day's work —
about 50 changed fields — the log is four orders of magnitude smaller. Neither
shape is right alone.

### 4.1 Line format

The same as §3.2, byte for byte. Only what is on the line differs, so a reader
that can read one file on the drive can read them all.

```json
{"t":"<table>","r":"<row id>","h":"<stamp>",
 "v":{"<column>":<value>,...},"o":{"<column>":"<stamp>",...}}
```

- `h` is the row's **base** stamp: the stamp every column takes unless `o` says
  otherwise. The writer picks whichever stamp the most columns share, breaking
  ties on the stamp itself so two implementations produce the same bytes.
- `o` is omitted when every column agrees with `h`, which is the ordinary case —
  a row created and never touched carries no overrides at all.
- `v` **absent means the row is deleted**: a tombstone. A row that is merely
  missing from a state dump is indistinguishable, on the reader, from one it has
  never been told about, and the next merge would hand it straight back.
- Values are tagged exactly as in §2.2.

A record expands into the ordinary §2 change records — one per column, at
`o[column]` or `h` — and merges by the ordinary §2.4 rules. **Nothing downstream
learns a new rule.** This is a compression of the wire and only that.

### 4.2 Writing one

Parts go down first, rolling at the same 4 MiB as segments; `state.json` is
written **last**, atomically. Until it exists the parts beside it are not a
checkpoint but an interrupted write, and a reader ignores the whole directory —
so a checkpoint cut short by a drive being pulled out costs nothing rather than
delivering a partial archive.

```json
{"formatVersion": 1, "catalogSchemaVersion": 1, "generation": 1,
 "horizon": "<stamp>", "parts": 1, "rows": 2000, "byteCount": 2189312,
 "firstSegmentIndexAfter": 3, "seen": {"<peer id>": "<stamp>"},
 "writtenAt": 1755400000.0}
```

- `horizon` is the highest stamp anywhere in the archive when it was taken. A
  reader that applies the whole checkpoint has, by definition, seen everything
  up to here — whoever wrote it.
- `firstSegmentIndexAfter` is where the log resumes. **The segment is rolled
  deliberately when a checkpoint is taken**, so no segment is ever half covered
  and both the reader and the pruner work in whole files. A writer must never
  reuse an index below it, even after pruning frees the name, or fresh records
  would land exactly where every reader skips.
- `parts` lets a missing part be detected rather than silently read short.
- `seen` is the writer's own watermarks at the time. **Recorded, not acted on** —
  see §4.5.

Rows with no stamp at all are skipped, exactly as the log skips them: with
nothing to compare against, a value that cannot lose a conflict is worse than no
value.

### 4.3 Reading one

A checkpoint is a **fallback, not the normal path**. A day's work is kilobytes of
log against a whole archive of state, so the log is far cheaper whenever it can
answer. It cannot in exactly two cases:

1. the reader has never read this device at all, or
2. `logFloor` is above the reader's watermark — the log has been pruned past it.

Reading is **all or nothing**. A checkpoint's records are in table order, not
stamp order, so no prefix of one is worth anything in particular; applying part
and then advancing a watermark past the horizon would skip whatever was in the
rest, permanently. If any part is missing or fails its checksums, the whole
checkpoint is refused and the log is what is left.

For the same reason the watermark moves to `horizon` **only once all of it has
been applied**, rather than batch by batch the way the log's does. An interrupted
checkpoint therefore costs a retry and nothing else.

Batches must not cut a row in half. A row the reader has never seen can only be
created from all of its columns at once, and one that arrives short is rejected
outright — guessing at a value somebody's archive depends on is not something a
merge does.

### 4.4 Pruning

After a checkpoint is complete:

1. write `logFloor` into `device.json`, **then**
2. delete this device's own segments below `firstSegmentIndexAfter`, and
   checkpoint generations older than this one.

That order and no other. Dying between the two leaves the drive holding segments
the floor claims are gone, which is harmless — a reader that trusts the floor
reads the checkpoint instead. The reverse leaves a reader looking for segments
that no longer exist and quietly missing everything they held.

**No reader has to be consulted.** A device behind the checkpoint reads the
checkpoint; a device past it needs nothing below. So there is no watermark
arithmetic across devices and no waiting on a device that never comes back — a
retired device holds back nothing at all.

Deleting stays inside the device's own directory, which is the same rule that
makes the whole protocol lock-free. Nothing here deletes a photograph.

### 4.5 What is deliberately not done

A reader that applied a whole checkpoint *could* adopt the writer's `seen`
watermarks: the state it just took on already incorporates everything the writer
had merged, so it would be entitled to skip those peers' logs too. The argument
is sound — the merge is a join and the order does not matter — but it is the
subtlest one in the design, and getting it wrong means silently skipping records
for good. Not adopting them costs only re-reading, which is idempotent. The
numbers are published so the choice stays open.

### 4.6 When one is written

When the log this device has written since its last checkpoint has grown larger
than that checkpoint. Self-tuning, with no cadence to guess at: the checkpoint is
written the moment it is cheaper than the history it replaces. With no checkpoint
yet the comparison is against one full segment, so a small archive never writes
one and never needs to.

### 4.7 Conformance

`Tests/HeykinnClicksTests/CheckpointSyncTests.swift`. An implementation must
reproduce: a device that has never seen the archive getting all of it from state
alone; a checkpoint being smaller than the log it replaces; a device **not**
republishing its whole history after pruning its own log; work after a checkpoint
travelling as ordinary log at an index above `firstSegmentIndexAfter`; a deletion
surviving into state rather than being resurrected; a marker-less checkpoint
being ignored entirely; a damaged part refusing the whole checkpoint; and no
batch ever cutting a row in half.

### Changing anything above

Every stamp issued under §1 is written into records that other devices will read.
A change is a format break, and needs a new version on this document plus the
migration reasoning set out in SPEC-hashing §6.
