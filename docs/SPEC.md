# heykinn-clicks: vision and path

*Revision 3. Revisions 1–2 — the full build-time spec — are in git history.
This document records the **vision**, the **invariants that must never
regress**, and the **path from the current state**. For behavior that has
already shipped, the code is the source of truth: this document points at it
and does not restate it.*

---

## Vision

One person's lifetime photo and video archive, owned outright.

- Every asset lives in **exactly one deliberate place** — the Local domain
  (the user's own devices) or a chosen cloud — and the app can **prove**
  where, never assume it.
- Local content is held as **`desiredCopies` verified copies** on registered
  devices, so no single device failing, decaying, or going missing takes the
  archive with it — and damage is found before the content is needed.
- Once account connectors exist, the app **verifies cloud presence itself**,
  executes migrations between domains end to end, and **automatically releases
  cloud copies whose local redundancy is proven** — ending recurring cloud
  lock-in without ever risking an only copy.
- The archive outlives the app: plain files in an understandable layout, a
  portable SQLite catalog mapping them.

Not a gallery and not a sync clone: storage governance, metadata authority,
archive coordination.

### The residency model

| Allowed steady state |
|---|
| Local only |
| AppleCloud only |
| GoogleCloud only |

Any multi-domain coexistence outside an active migration job is a violation —
surfaced, never auto-fixed. Presence is evidence, not opinion:

```
enum CloudPresenceEvidence { case none; case verified }
```

No `userAsserted` and no `inferred`. Either the app checked against a
connected account, or it records nothing: an export proves where content
*was*, and nobody reviews 24,000 photos to assert where it *is*.

---

## Where the app is today

Shipped and tested; the pointers are where to look.

- **Catalog authority and durability** — atomic chunk commits, resumable
  imports, startup reconciliation, verified per-target snapshots:
  `Persistence/`, `Services/CatalogBackupService.swift`,
  `AppStore.reconcileAfterRestart`. The store takes an `AppEnvironment`, so a
  test builds a whole one over a temporary archive rather than the user's:
  `App/AppEnvironment.swift`.
- **Targets** — host-device or external-volume, marker-file identity (never
  path), capped at `desiredCopies`, forgettable without deleting anything, one
  device = one copy: `Domain/Target.swift`.
- **Replication** — per-file for loose assets, per-export-part for archives;
  archive-backed replicas; the host-staging corridor for targets never
  reachable together: `Domain/ArchiveReplication.swift`,
  `Services/ExportPartRelay.swift`.
- **Verification** — binary protection verdict with check-standing as
  evidence; the aimed-reads triad complete (Merkle-tree agreement between
  targets, anchor checks with in-place path repair, and the size/mtime gate on
  connect, which is the only thing that sees a file edited under an intact
  path); background rot patrol; sampled quick checksum with its limits stated
  in type, UI, and tests: `Domain/Protection.swift`, `Domain/MerkleTree.swift`,
  `Services/ReplicaPathRepair.swift`, `Services/ReplicaStatGate.swift`.
- **Ingest** — Google Takeout in full: split parts, cross-part dedupe, Live
  Photo pairing across parts, capture-date precedence with provenance,
  structural year detection, edited-variant linking: `Services/Takeout*`,
  `Services/ImportService.swift`.
- **Duplicates** — exact-hash groups, review only.
- **Machinery for the vision, running locally** — residency domains, the
  policy engine (applies at import and re-applies on rule change; a rule
  naming a cloud opens a pending migration, never a label), and the migration
  state machine: `Services/PolicyEngine.swift`,
  `Services/MigrationService.swift`, `Services/ViolationScanner.swift`.
- **The first connector: Apple Photos** — indexes the library from metadata
  (no downloads) into one unified Library; merges a match into the existing
  row as a *counterpart link* when filename, capture second and dimensions
  agree, and only byte-identical originals write `verified` presence. Refuses
  to answer against an empty library, so an absent library can never read as
  "not present". A Live Photo is exported as both halves and stored as a still
  plus a linked motion asset, never flattened. **Whether the library is
  AppleCloud depends on iCloud Photos, which PhotoKit cannot report** — the app
  asks once at connect time and treats the answer as topology, never as
  evidence about a photo: `Services/ApplePhotosConnector.swift`.

  Searched, and there is no supported signal to replace that question with.
  `PHCloudIdentifier` looks like one and is not: Apple's own WWDC21 session
  says cloud identifiers work on an account signed out of iCloud Photos, or
  one that never was. `PHImageResultIsInCloudKey` means "these bytes are not
  on this device", which is true of an optimised library whether or not it
  syncs. `PHAssetSourceType.cloudShared` is iCloud Shared Albums, a different
  feature. No `PHPhotosError` case names the state, and nothing on the library
  container reports it. Inferring it anyway would write false residency — the
  exact failure the evidence model exists to prevent.
- **UI** — Overview with the one-answer protection card; Storage & Health with
  the archive map (the archive at the centre, a node per place, empty slots
  drawn); ⌘, Settings. Acting by default, escapes in menus, photos leading
  over files.

Stack: SwiftUI · Swift concurrency · raw `sqlite3` (WAL, `VACUUM INTO`,
additive migrations) · Apple frameworks only — zero third-party dependencies.

---

## Invariants — never regress

1. Exactly one residency domain in steady state; overlap is legal only inside
   an active migration job; violations are surfaced, never auto-fixed.
2. **Never claim more than you checked.** Sampled checks say they sampled;
   matching Merkle roots never prove bytes; a copy nobody read back is not
   verified.
3. Cloud evidence is `none | verified`, and nothing writes `verified` without
   a connected account. The user is never asked to assert presence — a
   one-time question about their *setup* (does this library sync?) is
   topology, not presence, and may not be stretched into one. An unavailable
   or empty source yields a refusal, never a negative.
4. One device holds one copy; the policy caps how many targets exist; identity
   is the marker file, never a mount path.
5. Never stage or copy what a target already holds; never delete
   archive-backed content; moved content is repointed, never re-copied.
6. No destructive cleanup without explicit job state and confirmation — or,
   for future reclamation, the listed proof, which is stronger than a prompt.
7. Interrupted work resumes; a crash or an unplug never corrupts the catalog.
8. Defects are fixed in the import path or startup reconciliation, so every
   install benefits — never by hand against one catalog.

---

## The path

### Next — no connector required

1. **Duplicate resolution.** Keep/discard on hash groups: the survivor keeps
   the claim, discards release catalog claims only, and archive-backed bytes
   are never deleted.

### Account integration — the vision's gate

The providers are not symmetric, and the path is honest about it. **Apple**
supports the whole loop: PhotoKit reads the library (verification — shipped),
and deletion through PhotoKit carries a system confirmation and propagates to
iCloud, so migrations and reclamation can execute end to end. **Google is
constrained by Google**: since March 2025 its Library API reads only
app-created content, and it has never offered deletion — so programmatic
verification of a pre-existing Google library cannot be built honestly.
Google verification stays manual (a fresh Takeout diffed against the catalog),
and reclamation from Google stays a manual act the app can only guide.

3. **Verified presence at scale (Apple).** Budgeted whole-library scans on the
   shipped connector, so Violations reports real cross-domain coexistence
   rather than 25 assets at a time.
4. **Migrations end to end (Apple).** The existing state machine drives
   PhotoKit execution instead of stopping at user-confirmed manual steps.
5. **Reclamation (Apple).** Proven local redundancy automatically releases the
   cloud copy — no prompt, no per-asset confirmation. The preconditions *are*
   the safety mechanism: Local residency; `desiredCopies` copies on targets
   (not staging); every copy read back and matched at least once; target trees
   in agreement; the provider confirming the same content immediately before
   release. **The read-only half of this has shipped**: the app computes and
   displays what it would release, and what is holding the rest up, and removes
   nothing — every precondition but the last, which is a check made at the
   moment of release and cannot honestly be asserted in advance
   (`Services/ReclamationPlanner.swift`). What remains is the release itself.
6. **Google, within its limits.** A guided fresh-Takeout diff — "what does
   Google still hold that this archive already protects?" — with a manual
   deletion checklist the app tracks but never performs.

### Later

7. Perceptual duplicates, faces, semantic search, map view.

---

## Appendix: lessons, one line each

Earned against a real 248 GB archive; the stories are in git history.

1. Cloud presence cannot be assumed — record evidence or nothing.
2. Replication has a unit; for a split export it is the part, not the asset.
3. Verification needs grades — an honest cheap check beats a proof too
   expensive to ever run.
4. An asset counts on a target only because that target holds its own part.
5. Two targets never reachable together need a holding corridor on the host.
6. Absent targets still count; attribute content by last-known path.
7. Transient failures requeue; they are not verdicts.
8. At archive scale, algorithmic complexity is a correctness requirement.
9. Long operations publish incrementally and name their phase.
10. Never stage what a target already holds.
11. Fix the import path and reconciliation, never one catalog by hand.
12. Fewer buttons: act automatically, keep the escapes in a menu.
13. The protection verdict is binary; a stale check is evidence, not a state.
14. Compare trees and stat anchors and files for free, aim the reads; only the
    patrol finds rot.
    A replica is often not its own file — one stat can cover ten thousand of
    them — which is what made stat-ing everything on connect affordable.
15. A moved folder is repointed, never re-copied.
16. Targets are configuration, capped by the policy; forgetting frees a slot
    and deletes nothing.
17. Preferences live in ⌘,; the working screens show the archive itself.
18. Reclamation, when it comes, is automatic and gated on proof, not prompts.
19. The spec holds vision, invariants, and path; for shipped behavior the code
    is the source of truth.
