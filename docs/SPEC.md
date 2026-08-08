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
- Local content is held as **as many verified copies as its source asks for**,
  on the devices that source names, so no single device failing, decaying, or
  going missing takes the archive with it — and damage is found before the
  content is needed.
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
  `AppStore.reconcileAfterRestart`. The schema is one declaration in
  `CatalogStore.createSchema` — there are no incremental migrations to replay,
  because the one catalog that needed them has had them. The store takes an
  `AppEnvironment`, so a test builds a whole one over a temporary archive
  rather than the user's: `App/AppEnvironment.swift`.
- **Targets** — host-device or external-volume, marker-file identity (never
  path), uncapped in number, forgettable without deleting anything, one
  device = one copy: `Domain/Target.swift`. **The host device is registered by
  default**, into a folder the app asks for once, so a fresh install holds a
  real copy before any drive is plugged in — for a source asking for two
  copies that is this Mac plus one drive. It is all-or-nothing (invariant 4); forgetting it is the
  supported answer for an archive the boot disk cannot hold, and registration
  refuses outright when the copy will not fit with the reserve intact
  (`AppStore.adoptHostDeviceIfNeeded`, `AppStore.registerHostDeviceTarget`).
- **Access grants** — a drive answered for once is not asked about again. The
  volume's decision (manage it, sweep it for exports, leave it alone) is
  persisted against its identity, and a security-scoped bookmark is stored
  beside it so the grant survives relaunches rather than being re-requested at
  every mount. Every remembered grant is listed and revocable in ⌘, → Access:
  `Services/AccessGrants.swift`, `UI/SettingsView.swift`.

  The system half of this is not the app's to fix in code. macOS keys its
  removable-volume grant to the app's code-signing identity, and
  `Packaging/bundle.sh` signs ad-hoc by default — the cdhash changes on every
  rebuild, so macOS drops the grant and asks again. A stable Developer ID
  signature is the fix; the bookmark is what makes the app's own state survive
  in the meantime. Tracked in PRODUCTION_READINESS.md.
- **Replication** — per-file for loose assets, per-export-part for archives;
  archive-backed replicas; the host-staging corridor for targets never
  reachable together; a drive arriving with the same export already on it
  claims those bytes as its replicas, hash-verified at claim time, rather than
  being sent a copy of what it holds: `Domain/ArchiveReplication.swift`,
  `Services/ExportPartRelay.swift`, `Services/TakeoutReconciler.swift`.
- **On-drive layout** — the drive belongs to the user, so the app reads their
  layout rather than imposing one. A restored file goes back to the path it
  was recorded at; a delivered export part goes in beside the rest of its set
  wherever that drive keeps it. Everything the app writes that has no place of
  its own — replicas of content imported from the Mac, catalog snapshots, a
  part with no set on that drive yet — lives under one `HeykinnClicks/` folder:
  `Domain/ArchiveReplication.swift` (`ExportSetLayout`),
  `AppStore.rehomeDeliveredParts`.
- **Verification** — binary protection verdict with check-standing as
  evidence; anchor checks with in-place path repair; the size/mtime gate on
  connect, which is the only thing that sees a file edited *or deleted* under
  an intact path — including the export archives, which path repair never
  examines and the discovery scan only ever adds to; risk-ordered background
  rot patrol; sampled quick checksum with its limits stated in type, UI, and
  tests: `Domain/Protection.swift`, `Services/ReplicaPathRepair.swift`,
  `Services/ReplicaStatGate.swift`, `AppStore.checkArchivePresence`.

  **Cross-target tree comparison was removed, not adapted.** Its leaves were
  built from `asset.contentHash` — the catalog's hash — so two targets holding
  the same asset carried an identical digest *by construction*. It could never
  see damage, only which asset keys each target held, and under `k`-of-`n` that
  difference is the design rather than a defect. Scoping it to the overlap
  would have left a check guaranteed to report agreement every time: dead code
  wearing the costume of a safety feature, which is worse than no check,
  because somebody reads "targets agree" and believes something was verified.
  The membership question it answered is answered exactly, and more cheaply, by
  reading the replica rows — that is the placement audit.
- **Sources are the unit of provenance; storage groups are the unit of
  policy** — a source is *each thing the user added*: one folder, one Google export (its zips and their unpacked folders
  are one source, not two), one Apple Photos import, and later Google Photos.
  It is a row in the catalog with a copy count and a list of destination
  devices; assets link to it. An export's row is identified by its **set id**
  — the timestamp Google stamps across every part of one download — rather than
  by a path, because its zips can sit on three drives with unpacked folders
  beside them and all of that is one export. The three nodes on the Sources screen are
  groupings of these, not stand-ins for them: `Domain/Source.swift`.

  Adding one asks — a sheet, prefilled with the previous answer, so the tenth
  folder going to the same two devices costs a click rather than a decision.
  Nothing imports before it is answered, because placement without a
  destination is the app guessing.

- **Placement follows the source's destinations** — copies go to the devices
  the source names, in the number it asks for. Free space is *validation*, not
  policy: a destination without room produces a reported shortfall, never a
  silent substitution onto some other device. A destination that already holds
  the source's own files counts there in place and is sent nothing:
  `Services/PlacementPlanner.swift`.

- **Retargeting is a job with a confirmation** — moving a source from one
  device to another copies, verifies, and only then releases the old device,
  and it states beforehand exactly what will be deleted. **App-written copies
  are deleted; the user's own files are only un-counted.** The app does not
  delete a file it did not write, so "move" means two different things
  depending on whose bytes they are, and the sheet says which is which rather
  than averaging them into one sentence.
- **The placement audit** — per asset, is it present on each of its source's
  destination devices? Anything missing is queued. `O(R)` over the replica
  rows, exact, and with no false positives — it replaces the tree comparison
  entirely: `AppStore.auditPlacement`.
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
- **UI** — navigation is the three questions somebody actually has: *what I
  have*, *where it came from*, *is it safe*. The mechanisms — violations,
  migrations, policies, duplicates, the activity log — are pages inside the
  question they answer, not top-level names the reader has to already
  understand. Overview with the one-answer protection card; the Drives screen
  with the archive map (the archive at the centre, a node per place, empty
  slots drawn); Sources with the inbound flow (each source, how much of it has
  made it across, the archive at the end); ⌘, Settings. Acting by default,
  escapes in menus, photos leading over files, and every screen written for
  somebody who has not read this document.

  **Every source states its redundancy the same way**, because they are the
  same question asked of different content. A Google export reports it per
  part; a folder reports it per import batch — which devices hold that
  folder's photos, how many are still owed and to whom, and what is waiting on
  this Mac for a drive that is not here. Both read off `replicaStates` and
  `replicationTasks`, so neither can disagree with the Overview verdict:
  `UI/ExportCard.swift`, `UI/FolderSourceList.swift`.

  **Paths are shown whether or not the disk is attached.** The reveal action
  is what depends on reachability, not the fact of the path — "where is it?"
  is asked most often about content that is not currently reachable:
  `UI/RevealInFinder.swift`.

Stack: SwiftUI · Swift concurrency · raw `sqlite3` (WAL, `VACUUM INTO`) ·
Apple frameworks only — zero third-party dependencies.

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
4. **Redundancy is configured per storage group, and the user configures it.**
   Each group carries its own copy count and its own **named destination
   devices** — "this export: 2 copies, on Archive Drive and the NAS". The app
   places copies on exactly those devices and nowhere else. It does not choose
   destinations, by free space or by anything else: where a person's photos
   live is a decision they are entitled to make, and an archive that quietly
   redistributes itself is one nobody can reason about.

   The number of registered devices is not capped, and devices are *expected*
   to hold different content — one source's destinations have nothing to do
   with another's. One device still holds at most one copy of an asset, and
   identity is still the marker file, never a mount path.

   **Provenance and policy are two rows.** `PhotoArchiveSource` records where
   photos came from and never changes; `StorageGroup` records how they are kept
   and is the user's to change. Every asset points at one of each, and
   membership on the group side is a strict partition — a policy needs one
   answer, and "this photo is in three groups naming three devices" has none. A
   group made by hand has policy and no provenance, which is the case the
   single-row model could not represent without inventing a history.

   **There is no archive-wide copy count.** Not as a policy, and not as a
   default that binds anything: the only surviving global is
   `newSourceDefaults`, which prefills the add-a-source sheet with the last
   answer given and governs nothing once a source exists. Every protection
   verdict, every placement and every reclamation precondition reads the
   number off the asset's own source, through
   `AppStore.placementPolicy(forAsset:)`. An asset with no source recorded
   falls back to those same defaults rather than to nothing — placing nothing
   would stop protecting content that was protected yesterday.

   Two earlier models were wrong here and are worth naming so neither returns.
   The first capped devices at the copy count and replicated everything to
   every device, which made "this device holds the archive" and "this photo
   has enough copies" the same sentence. The second let the app choose
   destinations by free space, which fixed the cap and took the decision away
   from the user in the same move.
5. Never stage or copy what a target already holds; never delete
   archive-backed content; moved content is repointed, never re-copied. **The
   host device is not exempt in principle** — a folder on this Mac's own disk
   is content the host target already holds, and copying it into the managed
   folder writes a second copy on one disk, which is not a second copy of
   anything. It *is* exempt in fact today, and that gap is named in the path
   below rather than papered over: the `volume:` replica form resolves
   relative to a target's root, so recording an arbitrary Mac path in it would
   name a file that does not exist. Honouring this for the host device needs
   an absolute-path replica form first.
9. A grant is remembered until it is taken back, and everything remembered is
   listed somewhere it can be taken back from. Re-asking a question the user
   has already answered is a defect, not caution — and a decision with no way
   to reverse it is worse than one the app never offered.
10. **This machine is a device like any other.** It is registered as a target
    by default, and placement gives it a share sized by what fits — not the
    whole archive. Under the old every-device-holds-everything model the host
    had to be all-or-nothing, because a boot disk that could not take the full
    archive could not be a target at all; `k`-of-`n` removes that cliff. A
    full boot disk simply stops being chosen for new content, and the drives
    take it. Forgetting the host target remains the way to keep the archive
    off this Mac entirely.
11. **Devices are compared only where they overlap, and only by reading.**
    Nothing may infer damage from two devices holding different content: that
    is the normal steady state. A cross-device check whose inputs are both
    derived from the catalog compares the catalog to itself and proves
    nothing, however elaborate the structure it uses to do it.
6. No destructive cleanup without explicit job state and confirmation — or,
   for future reclamation, the listed proof, which is stronger than a prompt.
7. Interrupted work resumes; a crash or an unplug never corrupts the catalog.
8. Defects are fixed in the code path that produces them — the import path,
   the scan, startup reconciliation — so every install benefits, and so the
   fix runs before the wrong answer is shown rather than a launch after it.
   Never by hand against one catalog.

---

## The path

### Next — no connector required

1. **In-place replicas on the host device.** A folder anywhere on this Mac's
   own disk is content the host target already holds, and invariant 5 says not
   to copy it — but the replica cannot be recorded yet. `volume:<relative>` is
   resolved as `mountURL + relative`, and a host target's `mountURL` is its
   configured folder, so `volume:Users/…/Pictures/x.jpg` would resolve to
   `<configured folder>/Users/…/Pictures/x.jpg`: a path that does not exist,
   recorded as a `present` replica. That is a false claim of a copy, which is
   invariant 2's exact failure mode, so the crediting is deliberately not
   shipped ahead of the form that can carry it.

   What it needs: an absolute-path replica prefix (`hostpath:`) alongside
   `volume:`, taught to `ReplicationService.resolveReplicaURL` and
   `isArchiveBacked`, then to the three things that read replica paths —
   `ReplicaPathRepair`, `ReplicaStatGate`, and verification. Until then the
   host target takes ordinary managed copies, which is correct but writes
   bytes it should not have to.
2. **Duplicate resolution.** Keep/discard on hash groups: the survivor keeps
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
   rather than 25 assets at a time (`AppStore.checkApplePhotosPresence` takes a
   `limit` of 25 today).
4. **Migrations end to end (Apple).** The existing state machine drives
   PhotoKit execution instead of stopping at user-confirmed manual steps.
5. **Reclamation (Apple).** Proven local redundancy automatically releases the
   cloud copy — no prompt, no per-asset confirmation. The preconditions *are*
   the safety mechanism: Local residency; as many copies on targets (not
   staging) as the asset's source asks for; every copy read back and matched at
   least once; the provider confirming the same content immediately before
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
14. Stat anchors and files for free, aim the reads; only the patrol finds rot.
    A replica is often not its own file — one stat can cover ten thousand of
    them — which is what made stat-ing everything on connect affordable.
30. A check whose two inputs both come from the catalog compares the catalog
    to itself. The Merkle comparison read convincingly, had tests, and shipped
    — and its leaves were catalog hashes on both sides, so a shared key could
    not differ however far the bytes had rotted. Ask what a check's inputs are
    derived from before asking how clever it is.
31. Risk belongs to the asset, not the replica. A copy read yesterday makes its
    asset safe no matter how stale the other copy is, and two copies both read
    six months ago are in more danger than either one alone suggests — so
    "oldest replica first" aims the reads at the wrong files. Order by the age
    of an asset's *freshest* copy.
32. `k` of `n` is not `n` of `n`. Capping the number of devices at the number
    of copies made "this device holds everything" and "this photo has enough
    copies" the same sentence, and the cap on how many drives somebody could
    own was the visible symptom of the two having been conflated.
33. Automating a decision is not the same as fixing the bug that made it hard.
    Removing the device cap was correct; replacing it with free-space
    balancing solved the mechanics and took from the user the one thing they
    had asked for by name — saying where their photos go. Ask what the person
    wanted to decide before deciding it well on their behalf.
34. The unit of a storage policy is the source, not the asset and not the
    device. "Keep my 2019 folder on these two drives" is the sentence people
    actually say; per-asset rules are unmanageable and per-device rules cannot
    express it at all.
35. "Move" is two operations wearing one word. Bytes the app wrote can be
    deleted after the new copy verifies; bytes the user put there can only
    stop being counted. A retarget sheet that does not separate them is
    promising to free space it will not free, or threatening a deletion it
    will not perform.
36. Removing a file is not removing what held it. Replicas are filed under the
    first two characters of their id, so draining a device left up to 256
    empty directories the app could not see and the user could — a folder tree
    still sitting there after the app said it had stopped using the drive.
    Deletion has to clean up the shape it made, not only the contents.
15. A moved folder is repointed, never re-copied.
16. Targets are configuration, capped by the policy; forgetting frees a slot
    and deletes nothing.
17. Preferences live in ⌘,; the working screens show the archive itself.
18. Reclamation, when it comes, is automatic and gated on proof, not prompts.
19. The spec holds vision, invariants, and path; for shipped behavior the code
    is the source of truth.
20. A date the file states can still be impossible; say so where it shows, and
    change nothing.
21. A discovery scan only ever adds; something has to notice what left. A
    deleted export part is a copy the archive no longer has, and the catalog
    row that outlives it must stop counting as one — but only ever from a
    target that was reachable at the time, because an unplug makes every
    check fail at once.
22. The sidebar is the user's questions, not the app's mechanisms. A name
    like "Violations" tells somebody who already knows the model where to
    click, and tells everyone else nothing.
23. Put it back where it was. The catalog already records where content
    lived, so restoring a copy to a folder of the app's own choosing invents
    a second location for one file; a part delivered to complete an export
    belongs beside that export, wherever the user keeps it. What the app
    writes that has nowhere of its own goes in one folder with the app's name
    on it, so the user can see at a glance what is theirs.
24. A migration that has run everywhere it will ever run is weight, not
    safety. With one install, "everywhere" is checkable: confirm against the
    catalog that each one applied, then delete it — and report what has not
    applied rather than deleting the code that would have done it.
25. A repair belongs where the damage is made. The same function called at
    startup arrives a launch late, after the wrong total has already been
    shown; called where the row is written, it prevents. Ask what can create
    the bad state before deciding a repair is one-time — the fix that closed
    the obvious cause may not have closed the only one.
26. A question already answered is not asked again. "Don't ask again" that
    cannot be undone is a trapdoor, not a preference — remembering and
    revoking are one feature, and shipping the first without the second is
    how a user ends up unable to re-adopt their own drive.
27. Show the path even when the disk is not here. A path is the answer to
    "where is my stuff", and that question is asked most often precisely when
    the thing is unreachable; hiding the answer exactly then leaves the reveal
    button useful only when it is not needed.
28. The host device is a device. Treating this Mac as a corridor and never a
    destination meant a fresh install with no drive attached protected
    nothing, while a boot disk with room to spare sat unused.
29. A source is not only where content came from; it is somewhere that content
    still is. An export knew which drives held it and a folder did not, and
    that asymmetry was in the rendering, not in the model — the replica states
    were there the whole time.
30. A number the whole archive shares cannot answer a question each source
    asks separately. The copies slider survived three model revisions by
    looking harmless — it bound nothing once sources carried their own count,
    so it read as a default while contradicting every source under it.
31. An `UPDATE` cannot find a row that has not been inserted yet. The import
    claimed its assets for their source before writing them, so the claim
    matched nothing, and the reload at the end of every import replaced the
    in-memory answer with the empty one from disk — placement was right and
    the record of why was gone.
32. Unmeasured is not full. A device nobody can reach reports unknown free
    space, and reading that as zero made the archive refuse to owe anything to
    an unplugged drive — including, for one scan's worth of time, a drive that
    had just been registered.
33. A device that was never asked to hold something does not owe it. Export
    parts were graded against every registered device rather than the ones
    their export names, so a Mac holding none of the zips owed a copy of all of
    them for ever — and no change to the export's settings could clear it,
    because its settings were never consulted.
34. Withdrawing the task is not withdrawing the intention. Archive-level
    redundancy cancelled the queued copy for every asset an export covered, on
    every device, but only rewrote the pending replica rows on devices holding
    a part — leaving 15,345 rows on a device reporting work that nothing would
    ever do.
35. Two facts in one row is one fact too many. A source recorded both where
    photos came from and where they should be kept; the first cannot change and
    the second must, and the moment a group is made by hand there is no history
    to put in it. Splitting them cost a migration and removed a whole class of
    question with no answer.
36. Complete means "holds what it was asked to hold", not "holds everything".
    A device no group names fell through to `.complete` on the Drives map and
    read "Complete copy" while the card beneath it said "Nothing to hold yet" —
    the same screen contradicting itself, in the voice of the model that was
    replaced two revisions ago.
37. A source does not own a group; its photos merely happen to be in one. The
    source's card offered "change where these are kept" whenever a group could
    be found, so once photos had moved, editing one export's settings reached a
    group holding a different export's photos and changed those too. Membership
    moves and ids do not, so resolving a group by the id it was created with
    goes wrong exactly when it matters.
38. Two doors into one room is the whole cost. The elaborate rule about when a
    source's card could safely edit a group existed only because the card could
    edit at all; deleting that affordance deleted the rule, the question "does
    this override that?", and the class of bug underneath both. One setting,
    one place to change it.
