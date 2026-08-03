# Spec: macOS App for Local-First Photo Residency Management

*Revision 2 — rewritten against a working implementation and a real 248 GB
archive. The original prompt is preserved in git history; this document
supersedes it.*

This is the spec you would hand a coding agent today to build this system. It
keeps the original's core model intact — exclusive residency, Mac as control
plane, availability-aware two-drive replication — and corrects the parts that
did not survive contact with real data. **[R2]** marks a change from the
original prompt; each one is explained in "What changed and why" at the end.

---

## Product intent

A native macOS app that helps one person manage personal photos and videos over
time without depending on a single external cloud provider.

The app should:
- give the user long-term control over storage placement and metadata,
- avoid recurring cloud lock-in as the primary archive strategy,
- manage imports, duplicate detection, residency policy, migrations, and local
  replication,
- treat the Mac as the always-available control plane.

This is **not** a generic gallery app and **not** a Google Photos or Apple
Photos clone. It is a **storage-governance, metadata-authority, and
archive-coordination app**.

**[R2] It is also an ingest tool for hostile export formats.** The original
prompt treated importing as "scan a folder". In practice the first and largest
job is absorbing a multi-part Google Takeout export, and that format actively
fights you (see *Ingest*). Ingest quality is not a later phase; it determines
whether the catalog is worth governing at all.

---

## Core residency model

Every asset has **exactly one logical residency domain** in steady state:
`Local`, `AppleCloud`, or `GoogleCloud`. These are mutually exclusive.

| Allowed steady state | Disallowed steady state |
|---|---|
| Local only | Local + AppleCloud |
| AppleCloud only | Local + GoogleCloud |
| GoogleCloud only | AppleCloud + GoogleCloud |
| | all three |

If an asset is `Local`, local redundancy is handled by the local system and it
should not also be retained in a cloud. If it is in a cloud, it should not also
be retained in the managed local archive.

**Migration exception.** Temporary multi-domain overlap is legal *only* inside
an active migration job, with explicit state tracking and cleanup verification.
Overlap is never an acceptable final state.

### [R2] Residency is a claim; presence is evidence

This is the single most important correction to the original prompt.

The original spec treats residency as a fact the app can simply record. It
cannot. **The app has no Apple or Google account connection and makes no
network calls**, so it has no way to know whether an asset is still in iCloud
or Google Photos. Recording "present in GoogleCloud" because an import came
from a Takeout export is an *assumption*, and an assumption that silently
becomes a fact will eventually delete the user's only copy.

So presence in a domain must carry its provenance:

```
enum CloudPresenceEvidence {
    case verified      // a connected account confirmed it
    case userAsserted  // the user said so; recorded as their statement
    case inferred      // derived from an artifact (e.g. a Takeout export existed)
}
```

Rules:
- Local presence may be recorded as `verified` — hashing a file on a drive
  proves it.
- Cloud presence may **never** be recorded as `verified` without a connected
  account. Define the seam now (`CloudDomainVerifier`), implement it as a type
  that reports `isConnected == false` and *refuses to answer*, so no code path
  can mistake an assumption for a fact.
- Automatic imports record Local presence only.
- Any UI that asks the user to assert cloud presence must default to **off**
  and label the result as their statement, not a verified fact.
- The user must be able to see how many assets carry unverified cloud presence,
  and clear those claims in bulk.

---

## Local architecture

The Local domain is backed by **two external drives**, plus a Mac staging area.

The two drives are **not guaranteed to be available at the same time**. Handle
0, 1, and 2 connected drives dynamically. Do not assume a permanently online
NAS-style topology, and do not assume both drives are ever plugged in together.

**The Mac is the canonical, always-available authority** for the metadata
catalog, residency, duplicate state, policies, migration jobs, the drive
registry, per-drive backlog, protection state, and operational history. The Mac
must never need a drive attached to know system state.

**Drive identity** is a marker file token written at registration, with volume
UUID as a fallback. Never mount path. **[R2]** Additionally persist each
drive's `lastMountPath` — not as identity, but so content recorded by path
while a drive was attached is still attributed to that drive once it is
unplugged. Without it, an archive on an absent drive counts toward no drive at
all and its copy silently stops satisfying the policy.

### [R2] The corridor: two drives that are never together

The original prompt says "adapt to current availability" but never answers the
question that follows: *if a file is on drive A, is needed on drive B, and the
two are never connected at once, how does it get there?*

It cannot, without somewhere to wait. The system needs a **holding area on the
Mac**: content is copied there from the drive that has it, moved onto the drive
that needs it when that drive next connects, and deleted. Three routes, chosen
by what is plugged in right now:

| Connected | Route |
|---|---|
| Both drives | copy straight across, no detour |
| Only the donor | park it in the holding area |
| Only the recipient | deliver the parked copy, then delete it |

Design requirements:
- **Plan deliveries first.** Delivering is the only thing that empties the
  corridor. A planner that copies in before delivering out fills the boot disk.
- **Never block a delivery on space.** Delivering is what frees the space.
- **Park only what fits**, leaving a fixed reserve free on the boot disk. Filling
  the user's system disk is a worse failure than a transfer taking two sessions.
- **The directory listing is the state.** Name each parked file after what it
  holds. No table. A catalog restored from a backup, a crash mid-copy, or the
  user emptying the folder in Finder then all leave the truth plainly on disk
  with nothing to reconcile.
- **Stream through a `.partial` name**, rename only after the landed bytes are
  checked. An interrupted transfer must never leave something that *looks* like
  a complete file.

---

## [R2] Replication has a unit, and it is not always the asset

The original prompt models replication per asset. That is right for loose files
and badly wrong for archives.

A 248 GB Takeout export arrives as **12 zips containing 24,626 photos**.
Replicating it means having those 12 zips on both drives. Modelling it
per-asset turns 12 file copies into 24,618 pointless operations, and — worse —
hides the fact that a second drive already carrying the same 12 zips is
*already compliant*. The user watching the app copy 24,000 files onto a drive
that already has them is watching it be wrong, loudly.

So model the archive explicitly:

```
struct ExportPart {          // one zip of a split export
    setID: String            // export session token
    partNumber: Int
    copies: [DriveID: Archive]
}
```

An asset covered by a part is present on a drive **because that drive holds its
own part** — not because the drive holds *any* satisfied part. (Attributing
every covered asset to every drive holding any satisfied part claims redundancy
that evaporates the moment the drives hold different subsets.)

### [R2] Redundancy carries evidence levels too

Proving two 10 GB zips identical means reading 20 GB. At 12 parts × 2 drives
that is ~256 GB of reads, so in practice it never runs and every part sits
forever at "not compared". A binary verified/unverified flag therefore encodes
nothing. Grade it:

| State | Meaning |
|---|---|
| `absent` | on no managed drive |
| `singleCopy` | one drive has it |
| `redundantUnverified` | enough drives, matched by name and size only |
| `redundantSpotChecked` | enough drives, fast partial checksums agree |
| `redundantVerified` | enough drives, whole-file hashes agree |

The **quick checksum** hashes the file's length plus a head window, a handful of
interior windows, and a tail window — a few MB regardless of file size.
Measured: **7 MB read of a 9.9 GB part, 0.24 s**, versus minutes for a full
hash. It catches what actually goes wrong with archive copies — truncation, a
partial transfer, the wrong file under the right name, corruption at either
edge — and it *cannot* see a flipped bit between the sampled windows.

State that limit in the type, in the UI string, and in a test that asserts a
mid-file change is missed by the quick check and caught by the full one. A
sampled check presented as proof is a lie with a 10 GB blast radius.

---

## Protection state (separate from residency)

Local assets carry a computed protection state:

- `StagedOnly` — in Mac staging only
- `ReplicatedToOneDrive` — on one managed drive, pending on the other
- `FullyReplicated` — on both
- `DriftDetected` — actual replica content diverges from the catalog hash
- `VerificationOverdue` — replica exists but integrity re-check is stale

Keep residency, protection state, physical replica presence, duplicate
grouping, and migration state as **five separate concepts**. An asset that is
residency=`Local`, protection=`ReplicatedToOneDrive`, present on Drive A,
pending on Drive B is valid and must be representable directly.

**[R2] Compute protection in a batch, not per asset.** The obvious
implementation — for each asset, filter the replica list — is O(n²) and pins a
core at 100% on a 25,000-asset catalog, making the app unusable. Build the
index once per recomputation. At archive scale, algorithmic complexity is a
correctness requirement, not an optimization.

---

## [R2] Ingest: Google Takeout is the primary path, and it is hostile

Build for what the export actually is:

- **Split parts.** `takeout-<session>-001.zip`, `-002.zip`, … Parts sharing a
  session token are one export set. Session tokens can themselves contain
  dashes (`<timestamp>-2` for a re-run), so parse the part from the *last*
  dash. Warn on gaps in part numbers.
- **Cross-part duplicates.** Google repeats media between parts. Dedupe by
  content hash across the whole set, not within a part.
- **Live Photos are split across parts.** The still can be in part 005 and its
  motion half in part 012. Match candidates by filename stem *across folders*,
  then confirm by the QuickTime content identifier. Matching within a folder
  only will silently fail on most of the library.
- **Google strips the still's Apple maker note.** The pairing UUID is often
  gone from the still even though the video keeps its identifier, so tiered
  confidence is required: identifiers match > motion identifier plus matching
  name > not a Live Photo. Unpaired motion files must remain browsable as
  ordinary videos until something links them, and must be re-checked when a
  later part imports a matching still.
- **Capture dates are frequently missing or wrong.** Resolve through an explicit
  precedence chain — file metadata → Google sidecar → the *original's* sidecar
  for an edited variant → filename → containing folder's year → unknown — and
  record which source won, so the guess is auditable.
- **Folder names are localized.** `Photos from 2014` is English-only. Detect the
  year structurally (a standalone 4-digit year component), not by matching an
  English string, and guard against reading a year out of the export's own
  directory names.
- **Edited variants are separated from originals.** Link an edited file to its
  original so they display together rather than as unrelated near-duplicates.

**Every one of these must be fixed in the import path, not by a one-off script
against one person's catalog.** A repair that only ever runs on the developer's
data leaves every other user with the defect. When a migration is genuinely
needed for existing catalogs, ship it as startup reconciliation that any
install will run.

### Archive-backed replicas

When imported media already lives on a managed drive, **that file is the
drive's replica**. Do not copy it to Mac staging — staging holds only content
with no drive-resident copy. Support replica paths that point into a volume, a
zip member (streamed, never extracted), or an export part, so a drive that
already carries the export is compliant without writing a byte.

---

## Duplicate handling

Exact duplicates by content hash. Asset identity is distinct from storage
location. Never auto-merge a risky case. Perceptual matching is a later phase.

---

## Residency policies

Rule-based and manual assignment; e.g. WhatsApp media defaults to Local, large
videos default to Local, selected sets pinned to a cloud. Evaluate rules in
priority order. Surface illegal steady-state coexistence rather than silently
tolerating or auto-fixing it.

**[R2]** Make the redundancy target a policy value (`desiredCopies`), read
everywhere redundancy is judged, rather than the number 2 scattered through
protection, planning and registration as a literal.

---

## Migration workflows

A migration is a controlled move between residency domains: create the job,
track the in-progress overlap as legal, verify target completion, clear source
retention, log the outcome. Explicit state machine, no implicit transitions.

Cloud transfer execution stays a user-confirmed manual workflow until account
integration exists — consistent with never asserting unverified cloud presence.

---

## Durability

The media survives on the drives; **residency, replica state, duplicate
grouping and import history exist only in the catalog.** Protect it on four
levels:

1. **Atomic chunk commits.** Each import chunk writes assets, replica states,
   batch counters and its resume checkpoint in one transaction. A crash loses at
   most the chunk in flight.
2. **Resumable imports.** Archives carry a checkpoint (files processed / files
   seen), trusted only while the file total still matches, so an interrupted
   part resumes instead of re-hashing gigabytes.
3. **Startup reconciliation.** Every launch requeues interrupted replication
   tasks, recovers missing batch records, attributes archives whose drive was
   unknown, and deletes orphaned staged files, abandoned extraction workspaces
   and half-written transfers — removing only files the catalog does not
   reference.
4. **Verified snapshots on the drives.** `VACUUM INTO` a consistent copy to each
   connected drive, written under a temporary name, read back read-only
   (integrity check plus an asset count), and renamed into place only on
   success. Keep the newest few per drive. Judge freshness from the snapshots
   actually present on the drive, not a remembered timestamp.

**[R2] Retry transient failures.** A drive unplugged mid-sync fails every
remaining task in milliseconds and, if those failures are terminal, the work is
lost silently. Distinguish transient failures (source unreachable) from real
ones, stop the run cleanly, and requeue at next launch.

---

## UI

Screens: **Overview, Library, Asset Detail, Drives & Health, Duplicates,
Violations, Policies, Migrations, Google Takeout, Activity, Settings.**

Requirements:

- **[R2] Default to acting, not asking.** The original prompt's screen list
  implies a control panel. Every operation exposed as its own button produced a
  screen with sixteen of them and no answer to the only question that matters.
  Connecting a drive should run scan → reconcile → extract → import → redundancy
  → transfer automatically; the screen's job is to answer *"is this safe?"* and
  keep the manual escapes in a menu.
- **[R2] Say what will happen, not that something is wrong.** "4 of 12 parts
  need another copy (42 GB)" leaves the user to work out whether to plug
  something in, wait, or free space. Name the parts, the drives, the route, and
  the action.
- **[R2] Publish incrementally.** Long operations must publish partial results
  as they go — assets appear in the Library as they are hashed, not after a
  multi-part import finishes. A progress bar that only moves at the end reads
  as a hang.
- **[R2] Name the phase.** Scanning, checking existing copies, extracting,
  importing, fingerprinting, transferring — never let one be mistaken for
  another that won't end.
- **[R2] Media must render.** Resolve previews through a fallback chain (Mac
  staging → archive-backed file on a connected drive → managed replica), cache
  thumbnails in memory and on disk, generate them for videos too, dedupe
  in-flight requests during fast scrolling, and play Live Photos and videos in
  place on hover with the indicator on the tile — as Apple's Photos does.
- **Don't reimplement the OS.** No in-app eject button; the volume ejects from
  Finder. Do make it visible when a drive is busy, and release it promptly when
  macOS signals an unmount.

---

## Stack

SwiftUI · Swift concurrency · SQLite (raw `sqlite3`, WAL, `BEGIN IMMEDIATE`
transactions, `VACUUM INTO`, additive `ALTER TABLE` migrations) · Apple
frameworks for metadata, thumbnails and AV. Media must never be trapped in a
proprietary format: an understandable filesystem layout plus a robust catalog
mapping.

---

## Safety

- No destructive cleanup without explicit job state and confirmation.
- Interrupted syncs must never corrupt catalog state.
- Drive identity never inferred from mount path alone.
- Illegal steady states flagged, never silently tolerated.
- Background operations resumable where practical.
- **[R2] Never delete archive-backed content.** Migration cleanup releases the
  catalog's claim and leaves the user's Takeout files in place. A folder whose
  files back live replicas is storage, not a redundant copy.
- **[R2] Never claim more than you checked.** A spot check is not a proof; an
  assumption is not evidence; a copy nobody read back is not verified.

---

## Phasing

| Phase | Content |
|---|---|
| 1 | App shell, domain models, SQLite persistence, local import, metadata extraction, exact duplicates, Library + Asset Detail |
| 2 | Drive registration and identity, staging, per-drive backlog, protection state, Drives & Health, 0/1/2-drive handling |
| 3 | Policy engine, violations, manual residency, migration jobs |
| 4 | **[R2] Takeout ingest in full** — export sets, archive-backed replicas, part-level redundancy, Live Photos, capture-date recovery, the transfer corridor |
| 5+ | Perceptual duplicates, faces, semantic search, map view, account integration behind the `CloudDomainVerifier` seam |

**[R2]** Phase 4 was originally "better browsing/search". It is not: without
correct ingest the catalog describes an archive that does not match the disk,
and every later feature inherits that. Live Photo pairing, capture-date
recovery and video thumbnails were listed as "later phases" in the original
prompt and had to be pulled forward — real export data made them table stakes,
not polish.

---

## What changed and why

Twelve corrections the original prompt got wrong or did not anticipate. Each
was found by running the system against a real 248 GB archive on two real
drives, not by reasoning about it.

1. **Cloud presence cannot be assumed.** A hardcoded "still in Google" default
   asserted unverified presence on 5,496 assets. Presence now carries evidence,
   and the unimplemented verifier refuses to answer rather than guessing.
2. **Replication needs a unit.** Per-asset modelling of a 12-zip export
   generated 24,618 unnecessary copy operations and hid that a second drive was
   already compliant.
3. **Verification needs grades.** Full comparison was so expensive it never ran,
   leaving every part permanently "not compared". A 0.24 s sampled check —
   honestly labelled — is worth more than a proof nobody can afford.
4. **Per-part attribution matters.** Crediting every covered asset to every
   drive holding any satisfied part over-claimed redundancy that did not exist.
5. **Two drives need a corridor.** Availability-awareness without a holding area
   leaves a part on drive A permanently unable to reach drive B.
6. **Absent drives must still count.** Archives with no `drive_id` were
   invisible to planning — 18 of 36 — so a satisfied policy still reported
   "partly replicated".
7. **Transient failures must be retried.** 1,683 copies were lost when a source
   drive was ejected mid-sync; a later fix recovered 2,132 tasks at startup.
8. **Algorithmic complexity is correctness.** O(n²) protection evaluation pinned
   a core at 100% and made the app unusable at 25,000 assets.
9. **Long operations must publish as they go.** Twice, the UI appeared hung
   because results were only published at the end.
10. **Never stage what is already on a drive.** An import began duplicating
    128 GB onto the boot disk before it was caught.
11. **Fix the import path, not the data.** Every one-off repair — capture dates,
    Live Photo pairing, edited-original linking, drive attribution — was
    re-landed as import-time and startup-reconciliation code so any user
    benefits, not just the one whose catalog was patched.
12. **Fewer buttons.** The Takeout screen went from 16 controls to 9, then to
    one card per export answering a single question. Automatic handling with a
    menu of escapes beat exposing every operation.
