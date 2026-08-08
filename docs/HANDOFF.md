# Continuation brief

Paste-and-go context for picking this work up in Claude Code. Written at the end
of a long session; everything below is either verified against the running app
or explicitly marked as unverified.

Read `docs/SPEC.md` first — the invariants and lessons are the contract.
`README.md` describes shipped behaviour. Both are level with the code.

**A later session has since landed items 1–4 and fixed three further bugs — see
"Done since this brief was written" below before reading the rest.**

---

## State of the tree

All work is **uncommitted**. `git status` shows ~28 modified files and these new
ones:

```
Domain/Source.swift                    Services/AccessGrants.swift
Domain/SourceCopyStatus.swift          Services/PlacementPlanner.swift
Persistence/CatalogStore+Sources.swift Services/PatrolScheduler.swift
UI/SourceCopyStatusView.swift          UI/SourceSettingsSheet.swift
Tests/AccessGrantTests.swift           Tests/PlacementPlannerTests.swift
Tests/PatrolSchedulerTests.swift       Tests/ReplicaPruneTests.swift
Packaging/prune-empty-replicas.sh
```

**It builds, runs, and the suite is green** (451 tests, 0 failures). It was
rebuilt and exercised against the real 24,639-photo archive twice. Confirmed working in the running app: the Access settings tab,
the source backfill (`Recorded 4 sources for 24,639 photos…`), risk-ordered
patrol, host-device adoption, per-folder copy status, and the empty-folder
prune.

`Tests/ReplicaPruneTests.swift` has since compiled and passes. Note the suite
was **not** green when this brief was written: eight assertions were failing,
which is how the three extra bugs below were found.

The catalog schema was altered on the user's live database this session
(`assets.source_id` added, `sources` table created, backfill run). Non-destructive
and already applied.

---

## The model — three revisions, do not relitigate

This is the part worth reading carefully. The storage model was got wrong twice
before landing. Both wrong versions are documented in SPEC invariant 4 so they
do not come back.

1. **Wrong:** devices capped at `desiredCopies`, everything replicated to every
   device. Made "device holds the archive" and "photo has enough copies" the
   same sentence. Symptom: could not register a third drive.
2. **Wrong:** uncapped devices, app picks destinations by free space. Fixed the
   mechanics and removed the decision the user had asked for by name.
3. **Correct, and current:** the **user** specifies, per source, how many copies
   and **which devices hold them**. The app places copies on exactly those
   devices. Free space *validates* (reports a shortfall), it never *chooses*.

A **source** is each thing the user added — one folder, one Google export (zips
and their unpacked folders are one source), one Apple Photos import. It is a row
in `sources` carrying label, provenance, `desired_copies` and
`destination_ids_json`. Assets point at it via `assets.source_id`; the source
holds no list. Membership is a strict partition: one source per asset.

Everything downstream resolves through `AppStore.placementPolicy(forAsset:)`.
Placement, the audit, copy status and the retarget planner all read it, so
regrouping an asset changes all of them at once.

**Also removed this session, deliberately:** the cross-target Merkle comparison.
Its leaf digests came from `asset.contentHash` on both sides, so two devices
holding the same asset carried an identical digest by construction — it could
never see damage, only membership differences, which under this model are the
design. Scoping it to the overlap would have left a check guaranteed to report
agreement forever. `ReclamationPlanner.Blocker.targetsDisagree` went with it.
`Domain/MerkleTree.swift` still exists but nothing calls it.

---

## Done since this brief was written

All of items 1–4 below have landed, plus the two bugs and the dead columns.
`swift test` is **451 tests, 0 failures** (5 skipped); `swift build &&
./Packaging/bundle.sh` is clean.

- **Global copy policy removed.** `redundancyPolicy`, `desiredCopiesPreference`,
  `maxSettableCopies`, `requestedCopies` and the `LocalRedundancyPolicy` type
  are gone. Protection, placement, reclamation and the archive plan all read the
  number off the asset's own source. `newSourceDefaults` stays and binds
  nothing. SPEC invariant 4 now says this explicitly.
- **Google exports are real sources.** `PhotoArchiveSource.exportSetID` (new
  `sources.export_set_id` column) identifies an export by its set id. Takeout
  imports claim their source, `ExportCard` offers the same settings sheet and
  "Change where these are kept" a folder has, and the archive plan grades each
  set against its own number (`copiesRequiredBySetID`).
- **Both bugs fixed.** `DriveCard` no longer offers "look for copies this drive
  already has" for host devices, and `AppStore.isAppOwnedFolder` refuses an
  import rooted at any app-owned folder. `StagingStore.remove` prunes its
  bucket, with `pruneEmptyBuckets()` for what older versions left.
- **Dead columns dropped**, with a guarded `dropColumnIfPresent`.

### Three further bugs found and fixed

None of these were known when the brief was written; all three were found by
the failing tests the brief did not mention.

1. **Registering a device queued nothing.** `register()` ran the placement
   audit *before* `rescanTargets()`, so the new device was still unreachable —
   and an unreachable candidate reports nil free bytes, which
   `PlacementPlanner` read as "no room". Every photo came back with a
   `.noRoom` obstacle and the audit queued zero copies; registering a drive did
   nothing until some unrelated event happened to re-run the audit.
2. **Nothing was ever owed to an unplugged drive.** Same nil-as-zero reading,
   permanent version: a named destination that is not connected could never be
   planned for, which is exactly the case the Mac's holding area exists to
   serve. Unknown room is now deferred to copy time, where the figure means
   something; a device that *is* here and full still reports `.noRoom`.
3. **Every folder added through the sheet lost its source.**
   `persistImportedAssets` called `assignSource` — an `UPDATE` — before
   `upsertAsset` inserted the rows, so it matched nothing. Placement was right
   (the in-memory map was set), but the link was never stored and the `loadAll`
   at the end of each import replaced the map with the empty one from disk.

### On the user's live catalog

Verified against a **copy** of the real 24,639-photo catalog, not in the
abstract (`HEYKINN_LIVE_CATALOG=<copy> swift test --filter
LiveCatalogMigrationCheck`). The schema step drops the two dead columns, adds
`export_set_id`, loses no rows, and is idempotent.

That catalog had **two** `takeoutExport` sources for one export — the backfill
keyed on batch label, and this export arrived in two batches. They asked for
identical settings, so `linkExportSourcesToTheirSets()` folds them into one.
Where two such rows *disagree*, both are left alone and reported: choosing
between them is the user's, not the app's (invariant 4).

It also contains an import batch for
`~/Library/Application Support/HeykinnClicks/LocalCopy` — the DriveCard bug in
the wild. It imported 0 photos, so nothing needs undoing.

---

## Outstanding work

Items 1–4 of the original list are done. What is left is below: item 5 is
designed but unbuilt, item 6 needs a decision.

### 5. Lossless Google metadata capture — designed, not built
Requirement from the user: keep everything so the zips become disposable; the
model must absorb Google changing its fields; data the app does not use must not
be carried through hot paths.

**Verified against the real export** (`takeout-20260710T081521Z-2-001`), not
from general knowledge. Asset sidecars use the newer
`*.jpg.supplemental-metadata.json` naming, ~640–700 bytes:

```json
{ "title": "…_o.jpg", "description": "", "imageViews": "10",
  "creationTime":   { "timestamp": "1501424012", "formatted": "Jul 30, 2017…" },
  "photoTakenTime": { "timestamp": "1500986614", "formatted": "Jul 25, 2017…" },
  "geoData": { "latitude": 0.0, "longitude": 0.0, "altitude": 0.0,
               "latitudeSpan": 0.0, "longitudeSpan": 0.0 },
  "url": "https://photos.google.com/photo/AF1Qip…",
  "googlePhotosOrigin": { "webUpload": { "computerUpload": {} } } }
```

Used today: `photoTakenTime`, `description`, lat/lon.
**Dropped:** `imageViews`, `creationTime` (upload time, distinct from capture
time), `url`, `googlePhotosOrigin`, `altitude`, `latitudeSpan`, `longitudeSpan`.
`title` is decoded then ignored. The all-zero geo case is already correctly
guarded at `TakeoutImporter.swift:345`.

Album `metadata.json` (dropped entirely):

```json
{ "title": "Kodaikanal", "description": "", "access": "protected",
  "date": { "timestamp": "1501424012", "formatted": "Jul 30, 2017…" } }
```

`people`, `favorited`, `archived`, `trashed`, `geoDataExif` did not appear in the
sampled file — Google emits those keys only when set, so absence in one file
proves nothing about the other 24,638.

**Structural finding that drives the design:** album membership is not a field.
It is encoded by *directory placement* — `Kodaikanal` and `Paro, Bhutan` are
albums, `Photos from YYYY` are year buckets, `Failed Videos` is Google's marker
for videos that failed to process. Storing sidecar payloads alone still loses
album membership, so the capture layer must record each file's path within the
archive and project membership from it.

**Proposed architecture:**

- *Layer 1, capture.* `metadata_records`: `asset_id` (nullable), `source_id`,
  `scope` (`asset` | `album` | `export`), `provider`, `origin_path`,
  `captured_at`, `schema_fingerprint`, `payload`. Payload is the JSON verbatim
  and unparsed, so a field Google adds next year is saved before any code knows
  about it. Own table, never joined into `fetchAssets()`, never in `loadAll()`,
  never `@Published`. Read only on asset detail, search, and export.
- *Layer 2, projections.* Only fields the app acts on get typed columns.
  Derived and rebuildable from Layer 1, so adding a projection later costs a
  re-projection pass, not a re-read of the zips.
- *Layer 3, tags.* `asset_tags` (asset_id, kind, value) for albums and people.
  **Never storage groups** — they are many-to-many and a policy needs a
  partition, or "this photo is in three albums naming three drives" has no
  answer. If "everything in album X lives on drive Y" is wanted later, that is a
  rule that *assigns* assets to a storage group — `PolicyEngine`'s job, with
  explicit precedence.
- *Adaptation.* `schema_fingerprint` = hash of the sorted key set. Unseen
  fingerprints get logged to a `metadata_schemas` table with a count and one
  example path, turning "Google changed the format" from silent loss into a
  reportable event. Swift's `Decodable` already ignores unknown keys, so the
  typed decoder is unaffected.

**Sequence:** table + import-path writes → **backfill from the existing 12 zips**
→ fingerprint surfacing → projections → album/people browsing. The backfill is
the step that actually buys zip-independence for the 24,639 photos already
imported; `TakeoutReconciler` already streams zip members without extracting, so
the machinery exists.

### 6. Source vs StorageGroup — **done**

Split, as decided. `PhotoArchiveSource` is provenance only (kind, label,
originPath, exportSetID, addedAt); `StorageGroup` carries label, desiredCopies,
destinationTargetIDs and membership. New `storage_groups` table and
`assets.storage_group_id`; `CatalogStore.migrateSourcePoliciesIntoStorageGroups`
reads a pre-split catalog's settings straight across, one group per source,
sharing the source's id so the two halves can find each other before any photo
links them. Idempotent, and verified against a copy of the real 24,639-photo
catalog: 3 groups, correct settings, every photo in one.

`AppStore.placementPolicy(forAsset:)` is still the only funnel; it reads the
group. `applySourceSettings` became `applyStorageGroupSettings`,
`EditSourceSheet` became `EditStorageGroupSheet`, and `retargetPlan` /
`releaseDepartedDevices` take a group.

Groups are now first-class in the UI: `StorageGroupsList` on the Policies
screen lists every group with its settings and photo count, and creates,
renames, edits and removes them. Removing one that still holds photos names
somewhere for them to go rather than dropping them to the defaults. The store
side is `createStorageGroup`, `renameStorageGroup`, `moveToStorageGroup` and
`deleteStorageGroup(_:movingPhotosTo:)`.

Still to do: **a Library action to move a selection into a group.**
`moveToStorageGroup` already takes arbitrary asset ids and is tested, so this
is UI only — but the Library has no multi-select at all today, so it needs
selection state before it can have the action.

### 7. Small things the UI check turned up

- **A leftover import batch for the app's own folder.** The live catalog has an
  `import_batches` row for
  `~/Library/Application Support/HeykinnClicks/LocalCopy`, from before the
  self-import guard existed. It imported 0 photos, so nothing is wrong with the
  archive, but the Sources screen reads "2 folders · most recently LocalCopy",
  which is exactly the confusion the guard was added to prevent. Deleting the
  row is cosmetic and safe; it is history, so it was left for the user to
  decide.
- **"How many copies" on the Policies screen** still says the setting lives
  "for each source under Sources". Since the split it is really per storage
  group; the group is reached from the source's card, so the direction is right
  and the noun is not.

## Two questions left open with the user

1. **Snapshot weight.** Raw payloads ride in every VACUUM snapshot (5 per drive
   × 3 drives). ~24,600 sidecars ≈ 15 MB raw. Compress, or leave plain so the
   catalog stays inspectable with `sqlite3` by hand? Leaning plain — the volume
   is small and readability matches the "archive outlives the app" goal.
2. **Archived / trashed.** If those keys appear elsewhere in the export, should
   they change behaviour, or be recorded and surfaced while every photo stays
   protected identically? Leaning record-and-surface: an export is a snapshot of
   one moment, and declining to protect something on the strength of a flag is
   irreversible in the direction that loses photos.

---

## Working notes

- **Build:** `swift build && ./Packaging/bundle.sh`. Tests: `swift test`.
  Real-volume test: `HEYKINN_DMG_TESTS=1 swift test --filter DriveIdentity`.
- The previous session could not compile — no Swift toolchain — so several
  rounds of type errors were found only at the user's build. Two classes recur:
  **ternaries mixing `HierarchicalShapeStyle` and `Color`** (`isOn ? .secondary :
  .orange` fails; spell both `Color.…`), and result-builder scoping. Build early.
- `Packaging/prune-empty-replicas.sh` is a one-time maintenance script for empty
  replica buckets left by older versions. Dry-run by default, refuses a drive
  with no `.heykinn-clicks-drive.json` marker. The in-app equivalent is Drives →
  a drive → **Tidy up empty folders**. Ran against My Passport: nothing to clean,
  verified independently in Finder.
- The user's drives: **My Passport** and **Owner's Back** (external, each a
  complete copy) plus **Studio MacBook Pro** (host device, folder
  `~/Library/Application Support/HeykinnClicks/LocalCopy`). Only ~18 replicas are
  app-written; the other ~24,618 assets are archive-backed Takeout counted in
  place. That asymmetry matters for retargeting — a move off My Passport can
  delete ~18 files and must leave ~24,618 of the user's own alone.
- Only ~90 of 21,401 copies have ever been read back, so the patrol has a lot of
  ground to cover and most assets are `awaitingFirstCheck`.
