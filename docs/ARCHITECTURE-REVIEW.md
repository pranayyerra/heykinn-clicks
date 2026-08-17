# Architecture review — before building anything else

*Written after asking whether the multi-device design was the best available.
It was not. This records what was measured, what it says, and what should
change. **Nothing here is implemented.***

Five decisions are open. Three are settled by evidence below; one dissolves
once another is settled; one is a deferral with a reason.

| | Decision | Verdict |
|---|---|---|
| **A** | How changes are captured — wrappers or triggers | **Change it.** Triggers, measured and proven |
| **B** | What travels — operation log or state | **Change it.** Hybrid, and the checkpoint is primary |
| **C** | Lists inside columns | **Fix one column.** Narrower than feared |
| **D** | Adopt `cr-sqlite` | **No** — and A is why |
| **E** | Main-actor catalog | **Defer**, with the reason recorded |

---

## A. Capture: wrappers or triggers

### What is there now

Every write to a shared table is wrapped in `journaled(_:_:)`, which reads the
row before, runs the caller's statement, reads it after, and stamps the columns
that differ.

**It is opt-in, and opting in is something you can forget.** Eleven write paths
did — assigning a photo to a group, pointing it at a source, repointing a copy
that moved, deleting a photo. Every one of them would have produced changes no
other device was ever told about, silently. They were found by reading, not by
failing.

That is not bad luck. It is the predictable result of choosing a mechanism that
must be remembered over one that cannot be avoided.

### What was measured

A plain SQLite trigger, on a throwaway database, against the exact statement
shapes the eleven bugs had:

```sql
CREATE TRIGGER sg_label_upd AFTER UPDATE OF label ON storage_groups
WHEN OLD.label IS NOT NEW.label
BEGIN
    INSERT INTO change_field_versions VALUES
        ('storage_groups', NEW.id, 'label',
         (SELECT hlc FROM change_pending_stamp WHERE id = 0))
    ON CONFLICT(table_name, row_id, column_name) DO UPDATE SET hlc = excluded.hlc;
END;
```

| Property | Result |
|---|---|
| Catches a raw `UPDATE` nothing wrapped | **Yes** — the whole eleven-bug class |
| Per-field diffing | **Free**, via `WHEN OLD.x IS NOT NEW.x` |
| A rewrite that changes nothing | **No stamp**, same as today |
| `INSERT` → whole-row stamp | **Yes** |
| Bulk `UPDATE` over 500 rows | **500 journal rows** — fires per row |
| Needs a custom C function | **No** |

That last row was the thing in doubt. A trigger cannot call into Swift for a
clock reading — but it does not need to. The app writes the current stamp into a
one-row table at the start of a transaction, and the trigger reads it. Plain
SQL, no extension, no bridging.

### What changes

**Deleted outright**

- The before/after row reads in `recordingWrite`. `OLD` and `NEW` are already
  there — this is most of the import overhead.
- `stampColumns`, the bulk special case. A trigger already fires per row, so
  `deleteStorageGroup`'s `UPDATE … WHERE storage_group_id = ?` records 500 rows
  by itself.
- The class of bug where a write path forgets to journal. Not *reduced* —
  removed, because there is no longer a thing to forget.

**Gained**

- **The enforcement travels with the catalog.** Triggers live in the SQLite
  file, so a Windows or Android client writing to the catalog inherits them
  without implementing anything. That is a portability argument I had not seen.

**Cost**

- Triggers are generated per table and per column, from `PRAGMA table_info` —
  mechanical, but it is code that must run on every schema change, and a trigger
  left behind after a column is dropped is a broken write path.
- Roughly 14 tables × their columns. Generated, not hand-written.
- `JournalCoverageTests` and `JournalWritePathTests` stay. They stop being the
  only defence and become the proof the generator covered everything.

### Recommendation

**Switch to triggers.** It is strictly better on every axis measured: it removes
a bug class structurally, removes two reads per write, removes a special case,
and carries the guarantee to other platforms. The cost is a generator, which is
smaller than what it replaces.

---

## B. What travels: operation log, or state

### What is there now

An append-only log of per-field changes. A first sync publishes every change
this device has ever recorded, which for a whole archive is one record per
column per row.

### What was measured

Publishing a 2,000-asset archive to a drive, then dumping the same catalog's
shared tables as one JSON object per row:

| | 2,000 assets | Scaled to 21,400 |
|---|---|---|
| Operation log written | 10.4 MB | **111 MB** |
| Full state dump | 2.0 MB | **21 MB** |

**The op-log is 5.2× larger than simply writing out the whole archive.**

The reason is visible once stated: a per-field record carries a table name, a
row id, a column name, a value, and a 60-character stamp. Twenty-nine of those
per asset means the stamps alone cost about 1.7 KB per photograph, to carry
maybe 400 bytes of actual data.

That inverts the usual argument for logs. It also means a first sync currently
writes **111 MB to a USB drive** — slow, and a lot of writing for what it
carries.

### But the log wins the other case, and wins it enormously

| Scenario | Op-log | State dump |
|---|---|---|
| New device meets the archive | 111 MB | **21 MB** |
| A day's work — say 50 changed fields | **~10 KB** | 21 MB |

Neither shape is right on its own. Every mature system lands in the same place:
**a periodic state checkpoint, plus a delta log since it.**

### The part that reframes the design

I had checkpoints in the design as an optimisation to add later, under
"pruning". That is backwards. **The checkpoint is the primary mechanism**, and
the log is the delta on top of it.

Getting that order right dissolves work that is currently outstanding:

- **Pruning becomes trivial.** Drop every segment older than the newest
  checkpoint each device has read. No low-watermark arithmetic across devices.
- **Retiring a device mostly evaporates.** A dead device blocks pruning today
  because its watermark never advances. With checkpoints, it only ever holds
  back segments newer than the last checkpoint — bounded, not unbounded.
- **A new device never replays history.** It reads one checkpoint and the few
  segments after it.

### Recommendation

**Adopt checkpoint-plus-delta, and build the checkpoint first.** Concretely: a
device writes a compacted state snapshot when the log since the last one exceeds
it in size, which is a self-tuning rule needing no cadence to guess at.

This should be settled **before** pruning is built, because it deletes most of
what pruning was going to be.

---

## C. Lists inside columns

### The defect, demonstrated

Two devices each add a *different* drive to the same storage group. One addition
survives. Proven with a throwaway test: `1 of 2 additions survived`.

Per-field last-writer-wins means per-*column*, and a JSON array in one text
column is one field. The list does not merge; it is replaced.

### How wide is it, really

Five columns hold JSON lists. Only one matters:

| Column | Concurrently edited? | Verdict |
|---|---|---|
| `storage_groups.destination_ids_json` | **Yes** — this is a user setting | **Fix** |
| `sources.destination_ids_json` | No — `upsertSource` always writes `"[]"`; policy moved to storage groups | Dead column |
| `migration_jobs.asset_ids_json` | No — set at creation; later writes are state transitions | Leave |
| `metadata_schemas.keys_json` | No — derived from the payload, identical per fingerprint | Leave |
| `assets.exif_json` | No — derived from the file; both devices compute the same map | Leave |

So this is **one column**, not a category. I overstated it when I raised it.

### The two ways to fix it

**Normalise to rows** — a `storage_group_destinations` table, one row per
(group, drive). Each destination then has its own identity, its own stamp, and
its own tombstone, so two additions merge and a removal travels.

**An observed-remove set encoded in the column** — keep the shape, add per-element
metadata.

Normalising is the better answer here: it needs no new merge machinery at all,
because the existing per-row rules already do the right thing once each element
is a row. It is a schema change, a migration, and a read/write path — the UI is
unaffected, since it already reads `[UUID]`.

### Recommendation

**Normalise that one column.** Small, targeted, and it stops being cheap the
moment anyone has two devices.

Worth stating as a rule so it does not recur: **a column holding a set that two
people can add to independently is a table, not a column.**

---

## D. Adopt `cr-sqlite`

I raised this twice and never assessed it. Doing so now.

It implements CRDT change capture as a loadable SQLite extension, using
triggers — which is exactly the mechanism section A recommends.

**Against, and decisive:**

- **A is achievable in plain SQL.** The measurement above shows triggers plus a
  one-row stamp table do the job with no extension. The main thing `cr-sqlite`
  would buy is already available for free.
- **It is a hard runtime dependency on reading the archive.** A loadable
  extension must be present, signed, and shipped on every platform — and the
  archive is meant to outlive the app. A catalog that needs a specific binary to
  be writable is a weaker promise than one that needs only SQLite.
- **It would be the project's first dependency**, in the layer with the largest
  blast radius, on an App Store build that must justify a shipped dylib.

**For:** it is battle-tested, and hand-rolled merge code is where subtle bugs
live. That is a real argument, and section A's triggers are the thing that
answers it — the risky part was capture, and triggers make capture declarative.

### Recommendation

**Do not adopt.** Revisit only if the merge rules themselves prove troublesome,
rather than the capture.

---

## E. The main-actor catalog

Everything built inherits `CatalogStore` being written on the main actor. It is
why a first sync had to be manually sliced with yields to stop the window
freezing.

**What would fix it:** SQLite is already opened `FULLMUTEX`, and WAL supports
multiple connections, so sync could hold its own connection on a background
queue. That is genuinely tractable.

**Why not now:** the slicing works, and section B changes the shape of the work
this would optimise — a checkpoint-based first sync is a bulk load, not 620,000
small merges, and may not need backgrounding at all. Fixing the constraint
before knowing the workload would be optimising a path that is about to change.

### Recommendation

**Defer**, and revisit after B. Recorded here so it is a decision rather than an
omission.

---

## What this implies for order of work

Current plan has pruning and the zip reader next. This changes it:

1. **Normalise `storage_group_destinations`** (C). Small, and it is a live
   data-loss defect that gets more expensive with every day of data.
2. **Move capture to triggers** (A). Removes a bug class and most of the import
   overhead. Behaviour-neutral if done right, which is how it gets tested.
3. **Checkpoint-plus-delta** (B). Then pruning, which will be much smaller than
   currently scoped — and possibly not a separate task at all.
4. **The zip reader** (H3, unchanged). Still the thing that decides whether
   non-Apple clients are reachable.

Steps 1–3 are all behaviour-neutral on a single device, which is how each was
tested before and should be again.

---

## What survives review unchanged

Worth recording, so it is clear the review was not indiscriminate.

- **Per-field last-writer-wins with a hybrid logical clock and tombstones.** No
  simpler model works, and the alternatives to LWW (multi-value registers,
  user-facing conflict resolution) ask a person to arbitrate something they have
  no way to judge.
- **JSON Lines rather than a database file on removable media.** A yanked drive
  tears one line; a torn SQLite write on exFAT is far worse. And any client can
  read a line of JSON.
- **One directory per device, append-only.** This is the strongest decision in
  the design. It removes locking entirely, and locking is where cross-platform
  sync usually dies.
- **Specifying formats with conformance vectors.** It found three live bugs
  before they bit.
- **One protocol, `SegmentStore`.** Earned its place twice over.
