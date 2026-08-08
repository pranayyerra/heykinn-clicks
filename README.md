# heykinn-clicks

A local-first **photo residency manager** for macOS. Not a gallery app, not a
cloud-sync clone — a storage-governance, metadata-authority, and
archive-coordination tool for personal photos and videos.

The vision, the invariants that must never regress, and the path from here
are in [docs/SPEC.md](docs/SPEC.md). For shipped behavior, this codebase is
the source of truth; the full build-time spec lives in git history.

## Core model

**Exclusive residency.** Every asset has exactly one logical residency domain
in steady state: `Local`, `AppleCloud` (iCloud / Apple Photos), or
`GoogleCloud` (Google Photos / Drive). Any multi-domain coexistence outside an
active migration job is a **violation** — flagged, never silently tolerated,
never auto-fixed.

**The host machine is the control plane.** The catalog (SQLite at
`~/Library/Application Support/HeykinnClicks/catalog.sqlite`) is the canonical
authority for metadata, residency, duplicate state, policies, migration jobs,
the target registry, per-target backlog, protection state, and audit history.
Nothing about system state depends on a target being attached.

**Local is a logical domain held by replication targets.** A target is a
device: either **this machine** (a folder on its own disk) or an **external
volume**. Register as many as you like; any number may be reachable at once,
from none to all.

**You decide where each source lives.** A **source** is each thing you added —
one folder, one Google export, one Apple Photos import. It carries its own
settings: **how many copies, and which devices they live on.**

> 2019 photos → 2 copies, on This Mac and Field Drive
> Google export of 3 Mar → 2 copies, on Archive Drive and the NAS

The app places copies on exactly the devices you named and nowhere else. It
does not pick destinations for you, so **your devices are expected to hold
different content** — that is the design, not drift, and nothing in the app
treats it as a fault.

Adding a source asks once, in a sheet prefilled with your last answer, so the
tenth folder going to the same two places costs a click. Change a source's
devices whenever you like; that opens a job that copies, verifies, and then
tells you exactly what it will and will not delete.

**A copy you already have counts.** If the source's files are already sitting
on one of its destination devices — Takeout zips you downloaded straight onto
Archive Drive — that *is* the copy on that device. It is hash-verified where
it lies and nothing is transported. Only the difference is copied.

**This machine is a device too.** On first launch the app registers a folder
on this Mac, so it is available as a destination before any drive is plugged
in and there is always something reachable to copy from. It is a device like
any other: it holds what the sources you pointed at it hold, and nothing else.
To keep it out of the archive entirely, **forget** it under Keep safe —
that deletes nothing.

A Takeout folder that already sits *inside* the host target's own folder is
counted where it is, exactly as one on a drive is. A folder elsewhere on the
Mac — `~/Pictures/OldBackup` — is **not yet** credited in place: it is copied
into the managed folder, which writes a second copy on the one disk and buys
no redundancy. That is a known gap, not the intended behavior; see *Next
implementation steps*. Crediting it needs a replica form that can record an
absolute path, because the existing `volume:` form is resolved relative to the
target's root and would silently name a file that does not exist.

- **Nothing reachable** — imports still work; files land in staging;
  replication tasks queue for the source's destination devices.
- **Some reachable** — each is identified by a marker file written at
  registration (volume UUID as fallback for removable ones; never path alone).
  Their backlogs sync; absent targets keep accumulating backlog.
- **Two targets on one device are refused at registration** — a copy on each
  does not survive that device failing, so the policy would count one copy as
  two.
- **Devices holding different content is normal**, so nothing treats it as a
  fault. What the app checks is whether each *photo* has its *k* copies, and
  whether the bytes of each copy still match what was imported. Those are two
  different questions and neither is "do these two drives look the same".

**Protection state ≠ residency.** Local assets carry a computed protection
state: `StagedOnly` → `ReplicatedToOneDrive` → `AwaitingFirstCheck` →
`FullyReplicated`, plus `DriftDetected` (replica content diverged from catalog
hash), `VerificationOverdue` (replica integrity not re-checked recently) and
`NotApplicable` (asset is not Local-resident). `AwaitingFirstCheck` means the
copies exist but none has been read back — it satisfies what the asset's
source asks for, and is deliberately distinct from a check that has gone stale. An asset can
validly be residency=Local, protection=ReplicatedToOneDrive, present on Drive A,
pending on Drive B — the model represents that directly.

## Build & run

```bash
swift build        # compile
swift test         # core-engine tests
swift run          # launch the app (SwiftPM executable; window activates itself)

# Also run the real-volume integration test (creates + mounts a temporary DMG,
# verifies marker-based drive identity incl. an unplug/replug cycle):
HEYKINN_DMG_TESTS=1 swift test --filter DriveIdentity
```

To try the drive workflow without physical drives, disk images behave exactly
like external volumes:

```bash
hdiutil create -size 100m -fs APFS -volname HeykinnDriveA /tmp/HeykinnDriveA.dmg && hdiutil attach /tmp/HeykinnDriveA.dmg
```

Mount it, register it under Keep safe, and the backlog syncs to it; detach
(`hdiutil detach /Volumes/HeykinnDriveA`) mid-sync to see interruption handling,
re-attach to see reconnect + auto-sync resume.

First launch starts empty. Nothing is seeded: demo rows asserting cloud
residency described a state the app has no connector to establish, and the rest
was noise sitting alongside a real archive.

Two compile errors recur often enough to be worth naming, both from SwiftUI's
result builders and both reported far from their cause:

- **A ternary mixing `HierarchicalShapeStyle` and `Color`.** `isOn ? .secondary
  : .orange` does not compile — the two branches are different types and the
  leading-dot syntax hides it. Spell both out: `isOn ? Color.secondary :
  Color.orange`.
- **A view body the type-checker gives up on.** A long `VStack` of conditionals
  fails with something unrelated, or times out. Extracting part of it into its
  own `@ViewBuilder` property fixes it and usually reads better anyway.

## Architecture

```
Sources/HeykinnClicks/
├── App/
│   ├── HeykinnClicksApp.swift   @main entry
│   └── AppStore.swift           @MainActor orchestrator; single source of truth
├── Domain/                      Typed models, deliberately kept separate:
│   ├── Residency.swift          ResidencyDomain, DomainPresence (presence ≠ residency)
│   ├── Asset.swift              Asset, AssetVariant, AssetKind, ImportOrigin
│   ├── Protection.swift         ProtectionState (computed, never stored blindly)
│   ├── Target.swift             ReplicationTarget, TargetKind, TargetMarker,
│   │                            TargetStorage (one device = one copy), VolumeInfo
│   ├── Replication.swift        TargetReplicaState, ReplicationTask (per-target backlog)
│   ├── Policy.swift             PolicyRule
│   ├── Migration.swift          MigrationJob + MigrationState (overlap legality)
│   ├── Violation.swift          ViolationKind (computed, surfaced, never auto-fixed)
│   ├── Takeout.swift            TakeoutArchive, TakeoutExportSet, pipeline phases
│   ├── ArchiveReplication.swift ExportPart, PartRedundancy (graded, not binary),
│   │                            HeldExportPart, ExportPartTransferPlanner
│   ├── CloudClaimWithdrawal.swift withdrawing claims the app never verified
│   └── …                        ImportBatch, AuditEvent, DuplicateGroup
├── Persistence/
│   ├── SQLiteDatabase.swift     thin sqlite3 wrapper (WAL, prepared statements)
│   └── CatalogStore*.swift      schema + repositories for every entity
├── Services/                    Pure/stateless engines where possible:
│   ├── ImportService.swift      scan → hash → dedupe → classify → stage → catalog
│   ├── HashingService.swift     streaming SHA-256 + sampled quick checksum
│   ├── MetadataExtractor.swift  ImageIO EXIF (encapsulated; swappable for exiftool)
│   ├── CaptureDateResolver.swift date precedence chain, recording which source won
│   ├── LivePhotoPairer.swift    still ↔ motion matching, tiered by confidence
│   ├── PolicyEngine.swift       priority-ordered rule evaluation + origin classification
│   ├── DuplicateDetector.swift  exact hash groups (perceptual matching = later phase)
│   ├── StagingStore.swift       Mac staging/cache area
│   ├── TargetMonitor.swift      volume enumeration, marker identity, mount notifications
│   ├── AccessGrants.swift       remembered per-volume decisions + security-scoped
│   │                            bookmarks; the store behind ⌘, → Access
│   ├── PlacementPlanner.swift   places copies on the devices a source names;
│   │                            free space validates, never chooses
│   ├── ReplicationService.swift copy/verify/remove backlog execution (hash-verified,
│   │                            temp-file + atomic rename; interruption-safe)
│   ├── ExportPartRelay.swift    the Mac holding area; verified large-file copy
│   ├── Takeout*.swift           Scanner, Extractor (adaptive parallel), Importer,
│   │                            Reconciler — the zero-button drive pipeline
│   ├── CloudDomainVerifier.swift seam for account integration; refuses to guess
│   ├── CatalogBackupService.swift VACUUM INTO snapshots, verified before publishing
│   ├── ThumbnailCache.swift     memory + disk tiers, video frames, in-flight dedupe
│   ├── ProtectionEvaluator.swift batch protection-state computation (per-asset is O(n²))
│   ├── ViolationScanner.swift   invariant checks incl. migration-overlap exemption
│   └── MigrationService.swift   explicit state machine: pending → copyingToTarget →
│                                verifyingTarget → clearingSource → completed/failed
└── UI/                          Overview (visual dashboard), Library (hover-plays
                                 Live Photos and video), Asset Detail, Storage &
                                 Health, Duplicates, Violations, Policies,
                                 Migrations, Google Takeout, Activity,
                                 Settings (⌘,: Automation · Safety · Access)
```

### Sync behavior

- **Auto-sync on connect** (toggleable in Settings → Automation): when a target
  becomes reachable with pending backlog, its sync starts automatically. Syncs
  serialize — a second target queues behind a running one.
- **Progress + cancel**: syncs process one task at a time with a live progress
  bar and current-file readout. Cancel stops after the current task; a drive
  unplugged mid-sync is detected between tasks. Either way the remaining
  backlog stays queued, so the next sync resumes exactly where this one
  stopped.

### Finding damage when devices hold different things

Two checks answer two different questions, and neither is "do these drives
match".

- **Does each photo still have its *k* copies?** The placement audit walks the
  replica rows and counts, per photo, how many devices hold it. Fewer than *k*
  means copies are placed and queued. This is exact, costs no disk access, and
  has no false positives.
- **Do the bytes still match what was imported?** Only reading finds that. A
  size/mtime check on connect catches anything edited or deleted under an
  intact path; the background rot patrol reads a small ration continuously,
  because silent decay changes no timestamp and no cheap check will ever see
  it.

**The patrol reads by asset risk, not replica age.** A photo whose copy was
read yesterday is safe however stale its other copy is — there is a known-good
copy to restore from. A photo whose two copies were both read six months ago
is in real danger, and under "oldest replica first" the patrol would never
prioritise it, because neither copy is the oldest anything. So the queue is
ordered by the age of each photo's **freshest** copy, with never-read-back
sorting first, and within a photo the oldest reachable copy is the one read —
it is the likeliest to be damaged and verifying it resets both clocks. The
ration is measured in bytes rather than files, with a per-file cap, so one
10 GB video cannot consume an entire run.

A cross-device tree comparison used to sit here and was removed rather than
adapted. Its leaves were the catalog's hashes on both sides, so two devices
holding the same photo carried an identical digest by construction — it could
never see damage, only which photos each device held. Under *k*-of-*n* that
difference is the design. Scoping it to the overlap would have left a check
guaranteed to report agreement forever, which is worse than no check: somebody
reads "targets agree" and believes something was verified.

### Google Takeout support

The **Google Takeout** screen finds and imports Takeout exports that already
sit on your drives — the common case of Takeout zips downloaded straight onto
the external archive drive:

- **Scan** any reachable target (one click per target) or any folder.
  Detected: `takeout-*.zip`, any zip whose listing is rooted at `Takeout/`
  (renamed downloads), extracted folders including extraction-collision names
  (`Takeout`, `Takeout 2`, `Takeout (1)`, …), and renamed roots found
  structurally by their `Google Photos` child directory. Scans skip the
  drive's own replica structure; discoveries are persisted in the catalog with
  the drive they were found on, so an archive on an offline drive stays listed
  as "(offline)".
- **Split downloads are export sets.** Large exports arrive as ordered parts
  (`takeout-<session>-001.zip`, `-002.zip`, …). Parts sharing a session token
  are grouped into one set, with a warning when part numbers have gaps.
  "Import set" runs the parts serially as a single import batch with
  cross-part duplicate detection (Google can repeat media between parts) and
  one migration job covering the whole set. Parts already imported are kept if
  a later part fails. Multiple zips extracted into one merged `Takeout` folder
  simply import as that folder; hash dedupe also makes importing both the zips
  and their extracted folder harmless.
- **Import** extracts zips to a temporary workspace (`ditto`, so zip64/unicode
  are fine), pairs each media file with Google's JSON sidecar
  (`photoTakenTime` wins over EXIF, GPS and description are carried in),
  stages everything as Local-resident assets, dedupes by content hash, and
  queues drive replication. The archive file itself is never modified.
- **Residency semantics**: imports record **Local presence only**. The app has
  no Google or Apple account connection and makes no network calls, so it
  cannot know whether an export's photos are still in Google Photos — and an
  assumption that silently becomes a fact eventually deletes someone's only
  copy. A toggle at manual import lets you state the overlap yourself; it is
  **off by default**, recorded as `userAsserted` rather than verified, and
  creates a GoogleCloud → Local migration job so the overlap is legal, tracked,
  and closed once you confirm deletion from Google. Automatic imports never
  tick it. `CloudDomainVerifier` is the seam a real account integration slots
  into; until one exists it reports `isConnected == false` and refuses to
  answer, so no code path can mistake an assumption for evidence.
- **Extract-on-drive workflow**: zips can be extracted in place on their drive
  (folder named zip-name-minus-.zip, joining the same export set) so imports
  read directly from the drive instead of extracting ~10 GB parts to Mac
  scratch space each time. Interruption-safe (`.extracting` temp dir + rename)
  with a free-space check; the zip is always kept as the pristine original.
- **Adaptive parallel extraction**: zips extract with multiple concurrent
  unzip workers, each owning a disjoint slice of the entry tree (partitioned
  by Takeout/product/album prefix, balanced largest-first). Worker count
  adapts to the Mac's cores AND the destination disk via diskutil: SSDs get
  up to 8 workers, spinning drives are capped at 2 (parallel writes there
  seek-thrash and lose to serial), unknown media gets a conservative 4.
  Single-process ditto remains the fallback if the parallel path fails.
  Where a part exists as both zip and folder, imports prefer the folder. After
  a folder's imported assets are **fully replicated to both drives**, a gated
  "Delete folder" action reclaims its space (import state transfers to the zip
  twin so the set still reads as imported). Re-scans refresh existing records
  (size, set grouping) without touching import state.

### Automatic Takeout management & archive-backed replicas

With "Automatically manage Takeout" on (default), a target becoming reachable
runs the zero-button pipeline: **scan → reconcile → extract → import**.

- **Archive-backed replicas.** Assets imported from a Takeout folder on a
  target record the folder's own files as that target's replica
  (`volume:`-prefixed replica paths) — hash-verified at import, with no
  duplicate copy queued onto the same disk. Only the *other* drive gets copy
  tasks.
- **Reconciliation (second drive with the same export).** When a drive
  arrives carrying content the catalog already knows — the same zips or
  extracted folders — the pipeline claims that content as the drive's
  replicas by hashing it in place: folder files directly, zip entries
  streamed out of the zip (`zipmember:<zip>!<entry>` replica paths, no
  extraction, no writes). Queued copies to that drive are cancelled. A second
  drive with the same 12 zips reaches FullyReplicated with zero additional
  bytes written.
- **No duplicate staging.** When imported media already lives on a managed
  drive, that file is the drive's replica and nothing is copied to the Mac —
  staging holds only content that has no drive-resident copy. Replication to
  the *other* drive sources from any reachable copy (staging, or a connected
  drive's file), so drive-only assets replicate drive-to-drive.
- **Checksum fast path.** Zips are fingerprinted (whole-file SHA-256) lazily —
  only for the one or two candidate donors involved in an actual
  reconciliation, never as a bulk sweep of every zip on a drive. A later
  drive whose zip matches a known fingerprint is byte-identical, so the known
  entry→asset mapping transfers directly. Per-entry reconciliation remains
  the fallback when no fingerprint or mapping exists yet.
- **Cheap re-scans.** Folder sizes are recorded at discovery and reused, so a
  re-scan does not re-walk tens of thousands of files per extracted folder.
- **No pipeline restarts.** A busy volume can transiently fail metadata reads;
  a drive whose mount point is still on disk stays connected rather than
  reading as an unplug/replug, and the pipeline will not re-enter for a drive
  it has already processed this session.
- **Explicit phases.** The Takeout screen names what is happening — Scanning,
  Verifying existing copies, Extracting, Importing, Fingerprinting — with a
  step counter, so long work is never mistaken for a scan that won't end.
- **Incremental import.** Parts are imported in chunks: each chunk is
  persisted and published straight to the Library, so assets appear as they
  are hashed rather than after the entire multi-part export finishes. The
  activity banner reports files processed and assets imported so far.
- **Reconciliation only where it can help.** A drive that already backs a
  part's replicas is never re-hashed for it, and its zip twin is never
  fingerprinted — that read would claim nothing.
- **Library shows drive-resident content.** Previews resolve through a
  fallback chain — Mac staging → archive-backed Takeout file on a connected
  drive → managed replica — so imported content renders in the Library
  whenever any copy is reachable.
- **Archive-backed replicas are never deleted by the app.** Migration cleanup
  releases the catalog's claim but leaves Takeout files in place; the
  extracted-folder cleanup action refuses while a folder's files back
  replicas (it is storage then, not a redundant copy). Verification streams
  archive-backed content and detects drift like any managed replica.

### Export-part replication, spot checks, and the transfer corridor

A 248 GB export is **12 zips holding 24,626 photos**. Replicating it means
having those 12 zips on both drives — modelling it per-asset turns 12 file
copies into 24,618 pointless operations and hides that a second drive already
carrying the same zips is *already compliant*. So the archive is modelled as
`ExportPart`s, and an asset is present on a drive because that drive holds
**its own** part (not because the drive holds any satisfied part — that would
claim redundancy that evaporates the moment the drives hold different subsets).

- **Graded redundancy.** `absent` → `singleCopy` → `redundantUnverified`
  (name and size agree) → `redundantSpotChecked` (quick checksums agree) →
  `redundantVerified` (whole-file hashes agree). A binary verified flag encodes
  nothing here, because the proof is unaffordable.
- **Quick checksum.** Hashes the file's length plus a 2 MB head, six 512 KB
  interior windows, and a 2 MB tail — about **7 MB read of a 9.9 GB part in
  0.24 s**, versus minutes for a full hash (and ~256 GB of reads to compare a
  whole export across two drives, which is why the full comparison never ran).
  It catches truncation, a partial transfer, the wrong file under the right
  name, and corruption at either edge. It **cannot** see a flipped bit between
  the sampled windows — stated in the type name, in the UI string, and in a
  test that asserts a mid-file change is missed by the quick check and caught
  by the full one. Byte-for-byte comparison stays available per export.
- **Transfer corridor.** When the drive that has a part and the drive that
  needs it are never plugged in together, the part waits in a holding area on
  the Mac in between. Both drives connected: copy straight across. Only the
  donor: park it. Only the recipient: deliver the parked copy and delete it.
  Deliveries are planned **first** so the corridor drains rather than fills, and
  are never blocked by space pressure — delivering is what frees the space.
  Only as many parts are parked as fit with a 20 GB reserve left on the boot
  disk; the rest are reported as waiting, not silently dropped. A part
  surviving only as an extracted folder is reported stranded rather than
  half-transferred.
- **The holding area keeps no table.** A parked part is a file named after the
  part it holds, so the directory listing *is* the state — a catalog restored
  from a snapshot, a crash mid-copy, or emptying the folder in Finder all leave
  nothing to reconcile. Copies stream through a `.partial` name and are renamed
  only once the landed bytes match the source, so an interrupted transfer never
  leaves something that looks complete. The source's full SHA-256 is captured
  during the read (free there; a 10 GB reread otherwise), while the landed copy
  gets only a quick checksum — nothing read those bytes back in full, and
  calling it verified would be a lie.

### Every source says where its copies are

Sources answers two questions about each place photos came from: how much of
it made it into the archive, and **where those photos are now**. The second
used to be answered only for Google exports, which reported per part which
drive held them — a folder you added got a photo count and nothing else, even
though the app had the replica states all along.

Now both read the same way, off `replicaStates` and `replicationTasks`:

- **Which devices hold it** — named, including this Mac, with the ones that
  are attached distinguished from the ones that are not.
- **What is still owed** — how many photos from this folder are not yet on
  which device, and how many bytes that is.
- **What is in transit** — content held on this Mac for a drive that is not
  currently connected, so a corridor that is doing its job looks different
  from one that is stuck.
- **What is load-bearing** — photos this folder holds the archive's only copy
  of, so emptying it in Finder would cost a copy.

**Paths are shown whether or not the disk is attached.** Reachability decides
whether *Show in Finder* is offered, not whether the path appears — "where is
it?" is asked most often about something that is not currently plugged in. An
unreachable path is rendered plainly with the disk it is on named.

### Real-library ingest: Live Photos, dates, and previews

Google Takeout fights you, so these are import-path fixes rather than one-off
repairs to one person's catalog:

- **Live Photos are split across parts** — the still in part 005, its motion
  half in part 012. Candidates are matched by filename stem *across* folders and
  confirmed by the QuickTime content identifier. Google also strips the still's
  Apple maker note, so pairing is tiered by confidence (identifiers match >
  motion identifier plus matching name > not a Live Photo). Unpaired motion
  files stay browsable as ordinary videos and are re-checked when a later part
  imports a matching still. Paired stills show the Live indicator and play in
  place on hover, as in Apple's Photos.
- **Capture dates** resolve through an explicit precedence chain — file
  metadata → Google sidecar → the *original's* sidecar for an edited variant →
  filename → containing folder's year → unknown — recording which source won.
  Folder-year detection is structural (a standalone 4-digit component), not a
  match on the English string `Photos from YYYY`, so non-English exports work.
- **Edited variants link to their originals** so they display together instead
  of as unrelated near-duplicates.
- **Thumbnails** are cached in memory and on disk, generated for videos too
  (`AVAssetImageGenerator`), with in-flight requests deduped so fast scrolling
  doesn't start several reads of the same original off the drive.

### Durability and catalog backup

The media survives on the drives, but residency, replica state, duplicate
grouping, and import history exist **only** in the catalog — so the catalog is
protected on three levels.

- **Atomic commits.** Each import chunk writes its assets, replica states,
  batch counters, and resume checkpoint in one transaction. A crash can lose
  at most the chunk in flight, never a half-written record.
- **Resumable imports.** Archives carry a checkpoint (files processed / files
  seen), so an interrupted part resumes rather than re-hashing gigabytes. The
  index is only trusted while the file total still matches.
- **Startup reconciliation.** Every launch requeues replication tasks that
  were interrupted mid-flight, recovers missing import-batch records from
  their assets, and deletes orphaned staged files, abandoned extraction
  workspaces, and half-written `.extracting` folders. It only removes files
  the catalog does not reference.
- **Verified snapshots on the drives.** `VACUUM INTO` writes a consistent,
  compacted copy of the catalog to `HeykinnClicks/CatalogBackups/` at each
  connected drive's root — outside the replica root, so replica cleanup can
  never touch it. Every snapshot is written under a temporary name, read back
  **read-only** (integrity check plus an asset count), and only then renamed
  into place; a snapshot that fails verification is never published. The five
  newest per drive are kept. Backups run at launch, after an import, and when
  a drive connects, and freshness is judged from the snapshots actually
  present on that drive rather than a remembered timestamp — so a drive whose
  backups were deleted is caught immediately. Failures are written to the
  audit log, not just shown once.

**To restore**: quit the app and copy a snapshot over
`~/Library/Application Support/HeykinnClicks/catalog.sqlite` (delete the
`-wal` and `-shm` files beside it). A snapshot is an ordinary SQLite database —
inspect one any time with `sqlite3 <snapshot> "SELECT count(*) FROM assets;"`.

### Drive-connect prompt, and remembering the answer

When an unmanaged external volume mounts, the app asks what it should be:
register it as managed Local storage (when a slot is free), just scan it for
Takeout archives, or leave it alone. Managed drives skip the prompt — on
connect they auto-sync their backlog and get an automatic Takeout sweep, so no
manual scanning is needed.

**Answer once.** Every choice in that prompt can be remembered against the
volume's identity, including the *action*, not only the suppression: a drive
you told to scan is scanned on every future mount without asking. The grant is
stored with a security-scoped bookmark to the volume, so it survives quitting
the app rather than being re-requested at each mount.

**And take it back.** ⌘, → **Access** lists every disk the app has a
remembered decision for — what was decided, when, and whether it is attached
right now — each revocable. Revoking only forgets the decision: nothing on the
disk is touched, and the next mount asks again. This is deliberately a pair;
the previous "Don't ask again for this drive" wrote a key into preferences
that no screen could remove.

**The system prompt is a separate thing.** macOS itself gates access to
removable volumes, and that grant is keyed to the app's code-signing identity.
`Packaging/bundle.sh` signs ad-hoc by default, so the hash changes on every
rebuild and macOS asks again — expected while developing, and fixed by a
stable Developer ID signature rather than by anything in the app's code. If
macOS is re-asking on every connect of a build you did not rebuild, check
System Settings → Privacy & Security → Files and Folders.

### Safety behaviors implemented

- Replica copies go to a `.partial` temp name, are hash-verified, then
  atomically renamed — an interrupted sync leaves a retryable queued task,
  never a corrupt catalog entry or a plausible-but-wrong replica. A leftover
  `.partial` from a crash is discarded on retry (covered by a test).
- Remove tasks are only ever enqueued by explicit migration cleanup, behind a
  destructive-action confirmation in the UI.
- Drive identity = marker file token (primary) + volume UUID (fallback).
- Manual residency reassignment flips only the logical domain; the violation
  scanner immediately surfaces the presence mismatch until a migration moves
  the actual bytes — the UI says so before you confirm.
- Every import, sync, registration, policy change, and migration transition is
  written to the audit log.

## What v1 defers (by design)

- **Cloud transfer execution.** Migration jobs to/from Apple/Google track
  explicit states, but the copy itself is a manual workflow the user confirms
  (`Mark target copy complete` / `Mark verified`). Workflow helpers (Takeout
  parsing, Apple export reconciliation) are Phase 4.
- Catalog access is main-actor synchronous; fine at personal-archive scale,
  and the `CatalogStore` boundary is where a background actor slots in later.
- Perceptual duplicates, faces, semantic search, map view, sidecar export.

## Next implementation steps

1. Scheduled verification sweeps that refresh `lastVerifiedAt` and demote
   `FullyReplicated` → `VerificationOverdue` proactively.
2. Duplicate review workflow (keep/supersede, storage reclaim via explicit jobs).
3. Apple Photos export importer — Takeout is done; the Apple side needs its own
   metadata reconciliation. Google's album JSON is read now: its title, date and
   places, captured verbatim and projected into tags.
4. Account integration behind `CloudDomainVerifier`, so cloud presence can be
   recorded as `verified` instead of only asserted, and migrations can confirm
   deletion rather than asking the user to.
5. An icon, a Developer ID signature and notarisation. The bundle itself is
   done — `Packaging/bundle.sh` assembles and signs `HeykinnClicks.app` around
   the SwiftPM binary, which is what gives the app a stable identity for the
   Photos permission. Not sandboxed, and not using security-scoped bookmarks:
   the app reaches volumes the user registers and identifies them by a marker
   file at the volume root, and that identity survives a rename, a remount and
   a different mount path, which is more than a bookmark does. The cost is no
   Mac App Store. See `Packaging/README.md`.
