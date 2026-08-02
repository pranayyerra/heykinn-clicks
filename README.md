# heykinn-clicks

A local-first **photo residency manager** for macOS. Not a gallery app, not a
cloud-sync clone — a storage-governance, metadata-authority, and
archive-coordination tool for personal photos and videos.

## Core model

**Exclusive residency.** Every asset has exactly one logical residency domain
in steady state: `Local`, `AppleCloud` (iCloud / Apple Photos), or
`GoogleCloud` (Google Photos / Drive). Any multi-domain coexistence outside an
active migration job is a **violation** — flagged, never silently tolerated,
never auto-fixed.

**The Mac is the control plane.** The catalog (SQLite at
`~/Library/Application Support/HeykinnClicks/catalog.sqlite`) is the canonical
authority for metadata, residency, duplicate state, policies, migration jobs,
the drive registry, per-drive backlog, protection state, and audit history.
Nothing about system state depends on a drive being attached.

**Local is a logical domain with two physical replicas.** The Local domain is
backed by two managed external drives that may be attached in any combination
(0, 1, or 2 at a time), plus a Mac staging/cache area:

- **0 drives connected** — imports still work; files land in staging;
  replication tasks queue per drive.
- **1 drive connected** — identified by a marker file written at registration
  (volume UUID as fallback; never mount path). Its backlog syncs; the absent
  drive keeps accumulating backlog and stays pending.
- **2 drives connected** — both sync as independent replicas, serially in v1.

**Protection state ≠ residency.** Local assets carry a computed protection
state: `StagedOnly` → `ReplicatedToOneDrive` → `FullyReplicated`, plus
`DriftDetected` (replica content diverged from catalog hash) and
`VerificationOverdue` (replica integrity not re-checked recently). An asset can
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

Mount it, register it in Drives & Health, and the backlog syncs to it; detach
(`hdiutil detach /Volumes/HeykinnDriveA`) mid-sync to see interruption handling,
re-attach to see reconnect + auto-sync resume.

First launch seeds sample data: 8 Local photos (real PNGs in staging, including
an exact-duplicate pair and WhatsApp-named files), cloud-resident placeholders,
a deliberate two-cloud violation, default policies, and a pending migration —
so every screen shows real behavior immediately.

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
│   ├── Drive.swift              ManagedDrive, DriveMarker, VolumeInfo
│   ├── Replication.swift        DriveReplicaState, ReplicationTask (per-drive backlog)
│   ├── Policy.swift             PolicyRule
│   ├── Migration.swift          MigrationJob + MigrationState (overlap legality)
│   ├── Violation.swift          ViolationKind (computed, surfaced, never auto-fixed)
│   └── …                        ImportBatch, AuditEvent, DuplicateGroup
├── Persistence/
│   ├── SQLiteDatabase.swift     thin sqlite3 wrapper (WAL, prepared statements)
│   └── CatalogStore*.swift      schema + repositories for every entity
├── Services/                    Pure/stateless engines where possible:
│   ├── ImportService.swift      scan → hash → dedupe → classify → stage → catalog
│   ├── HashingService.swift     streaming SHA-256
│   ├── MetadataExtractor.swift  ImageIO EXIF (encapsulated; swappable for exiftool)
│   ├── PolicyEngine.swift       priority-ordered rule evaluation + origin classification
│   ├── DuplicateDetector.swift  exact hash groups (perceptual matching = later phase)
│   ├── StagingStore.swift       Mac staging/cache area
│   ├── DriveMonitor.swift       volume enumeration, marker identity, mount notifications
│   ├── ReplicationService.swift copy/verify/remove backlog execution (hash-verified,
│   │                            temp-file + atomic rename; interruption-safe)
│   ├── ProtectionEvaluator.swift pure protection-state computation
│   ├── ViolationScanner.swift   invariant checks incl. migration-overlap exemption
│   └── MigrationService.swift   explicit state machine: pending → copyingToTarget →
│                                verifyingTarget → clearingSource → completed/failed
├── Support/SampleData.swift     first-run seed (real files, real hashes)
└── UI/                          Library, Asset Detail, Drives & Health, Duplicates,
                                 Violations, Policies, Migrations, Activity
```

### Sync behavior

- **Auto-sync on connect** (toggleable in Drives & Health): when a managed
  drive appears with pending backlog, its sync starts automatically. Multiple
  drives serialize — a second drive queues behind a running sync.
- **Progress + cancel**: syncs process one task at a time with a live progress
  bar and current-file readout. Cancel stops after the current task; a drive
  unplugged mid-sync is detected between tasks. Either way the remaining
  backlog stays queued, so the next sync resumes exactly where this one
  stopped.

### Google Takeout support

The **Google Takeout** screen finds and imports Takeout exports that already
sit on your drives — the common case of Takeout zips downloaded straight onto
the external archive drive:

- **Scan** any connected managed drive (one click per drive) or any folder.
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
- **Residency semantics**: if the photos still exist in Google Photos (the
  default assumption, controlled by a toggle at import), the assets are marked
  present in both GoogleCloud and Local, and a **GoogleCloud → Local migration
  job** is auto-created at Verifying Target — so the overlap is legal and
  tracked, and the job walks you through verifying replication and then
  confirming deletion from Google Photos to close the overlap window.
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

With "Automatically manage Takeout" on (default), connecting a managed drive
runs the zero-button pipeline: **scan → reconcile → extract → import**.

- **Archive-backed replicas.** Assets imported from a Takeout folder on a
  managed drive record the folder's own files as that drive's replica
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

### Drive-connect prompt

When an unmanaged external volume mounts, the app asks what it should be:
register it as one of the two managed Local-storage drives (when a slot is
free), just scan it for Takeout archives, or never ask again for that volume
(persisted per volume identity). Managed drives skip the prompt — on connect
they auto-sync their backlog and get an automatic Takeout sweep, so no manual
scanning is needed.

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
- Perceptual duplicates, faces, semantic search, map view, Live Photo pairing
  (`AssetVariant` already models the paired video), sidecar export.

## Next implementation steps

1. Scheduled verification sweeps that refresh `lastVerifiedAt` and demote
   `FullyReplicated` → `VerificationOverdue` proactively.
2. Duplicate review workflow (keep/supersede, storage reclaim via explicit jobs).
3. Apple Photos export importer (Takeout is done; the Apple side needs its own
   metadata reconciliation), plus richer Takeout coverage: album JSON, edited
   variants, motion-photo pairing.
4. Import hardening on real libraries: Live Photo pairing (`AssetVariant` is
   ready), video capture dates via AVFoundation, progress UI for multi-GB
   imports.
5. Xcode app-bundle wrapper (icon, sandbox entitlements with security-scoped
   bookmarks for drive access) once the SwiftPM skeleton stabilizes.
