# heykinn-clicks: vision and path

*Revision 4. Revisions 1–2 — the full build-time spec — are in git history.
This document records the **vision**, the **invariants that must never
regress**, and the **path from the current state**. For behavior that has
already shipped, the code is the source of truth: this document points at it
and does not restate it.*

*Revision 4 adds the device dimension: the archive was one device's, and is
becoming one archive that several devices hold a view of. The design work is in
`MULTI_DEVICE_STATE.md`; the formats it depends on are normative in
`SPEC-hashing.md` and `SPEC-format.md`.*

---

## In one page

**Today.** One device holds the catalog. It knows every photo the user owns, where
each copy lives across their drives, whether those copies have been read back
and matched, and what is owed. It ingests Google Takeout and Apple Photos,
places copies according to per-group policy, verifies them, finds damage, and
never claims more than it checked. A second device would be a second, separate
archive.

**Where it is going.** *One* archive that any number of devices hold a view of,
kept in step by the drives the user already carries between them — no account,
no server, no cloud required, and no ecosystem that can withdraw it. Eventually
readable from iOS, Windows and Android, because the archive should outlive the
app, the device, and the company.

**What has changed since revision 3.** The machinery for that exists and is
tested: every fact the catalog holds is stamped with when and by which device,
two devices merge without either losing work, and the changes travel on the
drives. What is not done is stated in *The path*.

---

## Vision

One person's lifetime photo and video archive, owned outright.

- Every asset lives in **exactly one deliberate place** — the Local domain
  (the user's own devices) or a chosen cloud — and the app can **prove**
  where, never assume it.
- Local content is held as **as many verified copies as its group asks for**,
  on the devices that group names — worked out from the registered drives, or
  chosen — so no single device failing, decaying, or
  going missing takes the archive with it — and damage is found before the
  content is needed.
- Wherever a provider connector can answer honestly, the app **verifies cloud
  presence itself**, executes migrations between domains end to end, and can
  eventually release cloud copies whose local redundancy is proven. Apple
  Photos verification is the first shipped connector; provider-confirmed
  deletion/reclamation and a Google account connector are not shipped.
- The archive outlives the app: plain files in an understandable layout, a
  portable SQLite catalog mapping them.
- **The archive is one thing, however many devices see it.** A person with
  several devices owns one archive, not one per device that happen to share
  drives. What each device knows travels on the drives already being carried
  between them.

Not a gallery and not a sync clone: storage governance, metadata authority,
archive coordination.

### One archive, several devices

The unit is the *archive*, and a device is a viewer of it. That was implicit
while there was only ever one device; making it explicit is what revision 4 is
about.

- **The drives are the transport.** Metadata travels the way the photographs
  already do — on the disk somebody plugs in. Nothing here requires an account,
  a server, a network, or a company to still exist.
- **A cloud may only ever be a courier.** If one is ever used it carries the
  same opaque files a drive carries, and the test is structural: *delete it
  entirely, and nothing is lost, because every device still converges through
  the drives.* A courier that fails that test has become a store of record, and
  a store of record somebody else operates is the thing this app exists to
  avoid.
- **No device is authoritative.** Two devices that have seen the same changes
  hold the same answers, including agreeing on which of two conflicting edits
  won. There is no primary device and no server to arbitrate.
- **What is true of the archive travels; what is true of a device does not.**
  `/Volumes/My Passport` is a fact about one device, means nothing on another, and
  on Android would not even be a path.
- **Other platforms read the same archive.** iOS, Windows and Android are
  intended readers, so anything recorded and later compared is defined by
  specification rather than by whatever Swift happened to do.

The limit is honest and inherent: **two devices that never share a drive never
converge.** There is no network path, by choice.

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

**One device holds the catalog, and the machinery for several devices to hold
one archive exists and is tested.** It ingests Google Takeout and Apple Photos,
places copies according to each group's policy, reads them back, finds damage,
and never claims more than it checked. Changes are stamped with when and by
which device and travel on the drives; two devices merge without either losing
work. What is not done is in *The path*.

**This section is deliberately not an inventory.** It said which file to open
for each of twenty features, which is the code's job, and it went stale where it
described behaviour — it was still saying the add-photos sheet "asks, prefilled"
after that had become invariant 20. What is worth writing down is the shape and
the constraints, which is what the invariants below are.

Where to look:

| | |
|---|---|
| The formats a second implementation must match | [`SPEC-hashing.md`](SPEC-hashing.md), [`SPEC-format.md`](SPEC-format.md) — normative, with conformance vectors |
| Why the multi-device design is what it is | [`ARCHITECTURE-DECISIONS.md`](ARCHITECTURE-DECISIONS.md), [`MULTI_DEVICE_STATE.md`](MULTI_DEVICE_STATE.md) |
| What is still undecided | [`OPEN-DECISIONS.md`](OPEN-DECISIONS.md) |
| Everything already built | The code, and the test named beside each rule below |

**Stack.** SwiftUI, Swift concurrency, raw `sqlite3` — no third-party
dependencies at all. `Domain/` and `Persistence/` import only Foundation and
SQLite, enforced by `DocumentedRulesTests` both ways: no foreign import, and no
reference to a type declared in a file that has one. That is what a status
reader on another platform needs, and `StatusReaderConformanceTests` shows a
raw-SQL reader reaching the same answer about safety that the app does.

## Invariants — never regress

1. Exactly one residency domain in steady state; overlap is legal only inside
   an active migration job; violations are surfaced, never auto-fixed.
2. **Never claim more than you checked.** Sampled checks say they sampled; a
   copy nobody read back is not verified; and a check that reads no bytes may
   not set the field that means "read" — which is how 21,117 photographs came
   to be reported as all read back by a check incapable of earning it.

   The tree comparison this used to cite went for the same reason and is worth
   remembering rather than naming: both its sides took their digests from the
   catalog, so a shared asset matched *by construction* however far the bytes
   had rotted. It is withdrawn (`SPEC-hashing.md` §4); ask what a check's
   inputs are derived from before asking how clever it is.
3. Cloud evidence is `none | verified`, and nothing writes `verified` without
   a connected account. The user is never asked to assert presence — a
   one-time question about their *setup* (does this library sync?) is
   topology, not presence, and may not be stretched into one. An unavailable
   or empty source yields a refusal, never a negative.

   That one question survives because PhotoKit cannot answer it and there is no
   supported signal that can. `PHCloudIdentifier` works on an account signed out
   of iCloud Photos; `PHImageResultIsInCloudKey` means "not on this device",
   true of any optimised library; `PHAssetSourceType.cloudShared` is Shared
   Albums. Inferring it anyway would write false residency, which is the failure
   this invariant exists to prevent.
4. **Redundancy is configured per storage group.** Whether a group is *shown*
   is invariant 21's business, not this one's. Each group carries its own
   copy count and a destination mode: let the app work out the required devices
   deterministically, or name specific devices — "this export: 2 copies, on
   Archive Drive and the NAS". Chosen mode places copies only on those devices;
   automatic mode takes the drives with the most room, breaking ties on which
   was registered first, and takes as many as the copy count asks for
   (`StorageGroup.automaticDestinations`). The figure it sorts on is the free
   space **recorded when each drive was last seen**, not measured live — so a
   drive plugged into another device still counts, and every device reaches the
   same answer from the same recorded facts. Measuring live would have each
   device answer from whatever it could see, and a group's destinations would
   flip at every sync. A source never silently switches from
   chosen back to automatic: where a person's photos live is a decision they
   are entitled to make, and an archive that quietly
   redistributes itself is one nobody can reason about.

   The number of registered devices is not capped, and devices are *expected*
   to hold different content — one source's destinations have nothing to do
   with another's. One device still holds at most one copy of an asset, and
   identity is still the marker file, never a mount path.

   **Ask what the person wanted to decide before deciding it well on their
   behalf.** Two earlier models were wrong here and are worth naming so neither
   returns.
   The first capped devices at the copy count and replicated everything to
   every device, which made "this device holds the archive" and "this photo
   has enough copies" the same sentence. The second let the app choose
   destinations by free space, which fixed the cap and took the decision away
   from the user in the same move.

   **The second is not what automatic mode does today, and the difference is
   the whole of it.** That version ran inside `PlacementPlanner`, per asset,
   over devices the user had *named* — it overruled them. Today's rule runs one
   layer up, only for a group where nobody has named anything, and it produces
   a named list the planner then honours in order. Free space is still never
   policy inside the planner: a destination without room is a reported
   shortfall, never a silent substitution. What changed is what a group
   resolves to when the user has expressed no preference at all — previously
   registration order, which knew nothing about anything.
5. Never stage or copy what a target already holds; never delete
   archive-backed content. **A folder somebody imported from is read and never
   written, with one exception they have to ask for**: once the archive holds a
   file's exact bytes on the devices its set names, and has read one of those
   copies back, the folder's copy can be moved to the Trash on request. Never
   automatically, never a file the app did not import, and never on the strength
   of copies nothing has read (`SourceFolderReclaim`). Everything else the app
   deletes is its own — the working copy in staging, a spare form of an export
   it put on a drive.
   Beyond that: moved content is repointed, never re-copied. **The
   host device is not exempt in principle** — a folder on this device's own disk
   is content the host target already holds, and copying it into the managed
   folder writes a second copy on one disk, which is not a second copy of
   anything. It *is* exempt in fact today, and that gap is named in the path
   below rather than papered over: the `volume:` replica form resolves
   relative to a target's root, so recording an arbitrary device path in it would
   name a file that does not exist. Honouring this for the host device needs
   an absolute-path replica form first.
6. No destructive cleanup without explicit job state and confirmation — or,
   for future reclamation, the listed proof, which is stronger than a prompt.
   The working copy on this device follows the same rule and has no switch: it
   goes once every copy exists *and* has been read back, so a switch could only
   ever have kept a duplicate the app does not count as one of your copies.
7. Interrupted work resumes; a crash or an unplug never corrupts the catalog.
8. Defects are fixed in the code path that produces them — the import path,
   the scan, startup reconciliation — so every install benefits, and so the
   fix runs before the wrong answer is shown rather than a launch after it.
   Never by hand against one catalog.

9. A grant is remembered until it is taken back, and everything remembered is
   listed somewhere it can be taken back from. Re-asking a question the user
   has already answered is a defect, not caution — and a decision with no way
   to reverse it is worse than one the app never offered.
10. **This device is a device like any other.** It is registered as a target
    by default, and placement gives it a share sized by what fits — not the
    whole archive. Under the old every-device-holds-everything model the host
    had to be all-or-nothing, because a boot disk that could not take the full
    archive could not be a target at all; `k`-of-`n` removes that cliff. A
    full boot disk simply stops being chosen for new content, and the drives
    take it. Forgetting the host target remains the way to keep the archive
    off this device entirely.
11. **Devices are compared only where they overlap, and only by reading.**
    Nothing may infer damage from two devices holding different content: that
    is the normal steady state. A cross-device check whose inputs are both
    derived from the catalog compares the catalog to itself and proves
    nothing, however elaborate the structure it uses to do it — so ask what a
    check's inputs are derived from before asking how clever it is.

12. **No operation may require two devices connected at once.** One cable and
    two drives is the ordinary setup, not an exotic one. Work that needs both
    is work that never runs: it does not fail, it reports "nothing to do" for
    ever, which is the most expensive kind of wrong. Everything is per-device
    and resumable, and anything comparative reads what is here, records it, and
    meets the other reading in a later session — which is a fact about drives,
    not a weakening of the evidence (invariant 2 still applies: two readings
    are still two readings, whenever they were taken).
13. **A marker naming another archive is never overwritten silently.**
    Registration reads the marker before writing one, and where it names a
    different archive it stops and asks (`DriveMarkerConflict`,
    `MarkerConflictTests`). It applies to every archive equally — the real one
    must not be able to quietly claim a test archive's drive either.

    Found by doing it: setting up a throwaway archive for screenshots, with a
    real drive mounted, registered that drive and overwrote the real archive's
    marker. Nothing was lost — the volume UUID is a fallback and it held — but
    the archive was relying on its backup identity for a drive plugged into the
    device, and nothing said so.

    Two archives on one device is not exotic; the app itself offers a test
    archive beside the real one. And the rule reaches further than registration:
    a folder is adopted because it carries a marker naming *this* target, never
    because it sits where one would expect, which is what lets
    `HostTargetPathRepair` find this device's own copy again after the archive
    directory moves without risking somebody else's.

14. **Two devices given the same changes reach the same answers.** Including
    which of two conflicting edits won. If two devices resolve one conflict
    differently they never converge again, and nothing afterwards can detect it
    — so the merge is order-independent, idempotent, and total: every tie breaks
    on device id, and no device is authoritative.

15. **No cloud, account, or network may ever be required.** Metadata travels on
    the drives that already carry the photographs. A courier may be *offered*,
    never depended on, and the test is that deleting it entirely loses nothing.
    A device is allowed to be offline for a year and then catch up from a drive.

16. **What is true of a device never travels.** Mount paths, place handles,
    the archive lock, the local work queue, caches. A `/Volumes` path from
    another device is not a weaker fact, it is a meaningless one, and recording it
    as though it meant something is the same failure as claiming an unverified
    copy. `CatalogScope` is the list, and it is enforced by a test rather than by
    memory.

17. **Anything recorded and later compared is defined by specification, not by
    implementation.** Hashes, orderings, encodings, the on-drive format. Swift's
    `String` ordering is not Rust's, Kotlin's or C#'s; JSON object key order is
    not stable unless it is made so; an integer and a float are one JSON number
    and two SQLite values. Each of those was a live defect found by writing the
    rules down. A value whose definition is "whatever the Swift does" cannot be
    reproduced by a second implementation, and the archive is meant to outlive
    this one.

18. **A newer catalog, or a newer drive, is refused rather than downgraded.**
    An older build must not open what a newer one wrote, because every upsert
    rewrites whole rows and would silently discard the columns it does not know.
    Version parity across devices and app stores is not achievable, so the
    failure is made loud instead: refusing costs somebody a sync, and the
    alternative costs them data they will not notice losing.

19. **Nothing on screen uses a word the app invented.** Enforced by
    `DocumentedRulesTests`, because it had been swept by hand once and declared
    finished while the photo library's filter still read *All domains* and
    registering a drive still promised to queue "all existing Local assets for
    replication". The person using this is
    not technical and should never have to become so. They own *drives*,
    *photos*, *copies*, and the question *are my photos safe* — and every screen,
    prompt, error and log line answers in those terms.

    A *target*, a *replica*, a *catalog*, a *marker*, a *residency domain*, a
    *checkpoint*, a *merge*, a *journal* — these are our words for our problems.
    They may live in the code and in these documents, where they are precise and
    earn their keep, and they may not cross into the interface. The test is not
    whether a sentence is accurate; it is whether somebody who has never read
    this document knows what to do next.

    **Renaming a concept and removing it are different acts**, and the five that
    follow are the second. They were argued out separately and are recorded here
    because each is a thing that must not come back.

20. **The app states what it is about to do rather than asking.** Adding photos
    gives one sentence — *"Every photo on Nina's Back and My Passport"* — with
    `Change…` beside it, not a form whose answers are already correct. The whole
    form is still there behind the link, and opens by itself for a set that
    already names its own devices.

    This became possible only when placement acquired a reason worth showing.
    While the answer was "whichever drives were registered first", there was
    nothing to say and the controls were the only honest way to show the
    arrangement. **A control is often a missing explanation**, and the reverse
    holds: the app may only decide for somebody where it can say why in one
    sentence they could check, and it may only claim a reason where one exists —
    naming both of two drives is not a judgement about room.

21. **A row, a prompt or a control appears where something differs.** The
    storage screen shows one line while every set of photos is kept the same
    way, because a set exists per import and six identical rows answer "where
    did this come from", which is provenance, on the screen asked "are my photos
    safe" (`StorageGroup.sharedRule`). A drive nobody has claimed asks one
    question with two named buttons; a drive already in use, or carrying another
    archive's ID file, asks nothing, because the answer is already known.

    This is also what protects the case that cannot be automated. Somebody who
    keeps one set off the drive they travel with has a set that differs, so it
    does not collapse — no rule has to detect the intention, because the
    difference *is* the intention.

22. **Where a photograph is kept is observed, never set.** A control whose only
    effect is to make the app start reporting a discrepancy is a trap however
    well it is worded. Moving content is a job with a confirmation, and it is
    the only thing that changes where a photograph lives; the app's record
    follows the bytes. `ResidencyIsObservedTests` fails if a hand-set path
    returns.

23. **The answer comes first, and it is the worst true thing.** Every screen
    that reports safety leads with one sentence, ordered: nothing yet, no drive,
    damaged, in no place at all, asking for more copies than there are drives,
    behind, in one place only, safe (`SafetyAnswer`). One archive has one answer
    — two screens working it out separately is how a damaged copy came to be
    described as still copying on the screen people open first.

24. **A photograph in one place is never called safe**, even where one copy is
    all its set asked for. Meeting a one-copy policy is reported as met; it is
    not reported as safety, because the archive's own definition needs two
    places and a green tick beside a warning is the app contradicting itself one
    click apart.

25. **Where photos came from and how they are kept are two rows.**
    `PhotoArchiveSource` records where photos came from and never changes; `StorageGroup` records how they are kept
    and is the user's to change. Every asset points at one of each, and
    membership on the group side is a strict partition — a policy needs one
    answer, and "this photo is in three groups naming three devices" has none. A
    group made by hand has policy and no provenance, which is the case the
    single-row model could not represent without inventing a history.

    **A source is its own first group.** Adding a folder or an export creates
    one group carrying the source's id and name, so a person meets *one* thing —
    a name, where it came from, and a rule — rather than two rows that happen to
    agree. "Group" only becomes a separate idea when a second one exists, which
    is the moment it is worth learning. Every route that makes a source does
    this; it was true of the migration and of exports and coincidental for
    folders, which is the worst of the three states to be in.

    The two stay distinct in what they *mean*, and diverge the moment anything
    is regrouped or renamed. Sharing an id is not sharing a row: provenance is
    still immutable, policy is still the user's to change, and a group can
    outlive the source it was named after or belong to no source at all.

    **Policy is a storage group's, and nothing else's.** Not the archive's, not
    a source's, and never an asset's: `Asset` carries no copy count and no
    destinations, and must not gain them. Per-asset storage was considered and
    refused — it makes "what does this photo want" answerable as many ways as
    there are photos, with no object to read the answer off, and no way to say
    what a set of photos is for. A group is the smallest thing policy may attach
    to, and a group of one is still a group.

    The one exception is a stop-gap and is treated as one: a photo in *no* group
    follows the add-sheet defaults, because placing nothing would stop protecting
    content that was protected yesterday. That state is reachable (an import
    through no source flow names no group), so it is surfaced under Keep safe
    and fixable there — never left as a silent answer nobody can see.

26. **There is no archive-wide copy count**, and no remembered answer standing
    in for one. Not as a policy, and not as a default that binds anything: the
    only surviving global is
    `newSourceDefaults`, and it is **derived, never stored**: a new set of photos
    starts from the count most of the archive already keeps, and from devices
    worked out through the one call every new group starts from
    (`AppStore.startingDestinations`). It governs nothing once a source exists.

    Both halves used to be remembered and both went stale. The device list froze
    new groups onto whatever was plugged in the first time anybody touched it, so
    a drive bought later was never proposed again — and the Google export path
    reached the same state by another route, omitting the mode and inheriting
    `chosen` from `StorageGroup`'s own default. The count then drifted on its
    own: one real archive had a stored answer of one copy while every set of
    photos in it kept two, so the app stood ready to propose less protection than
    it was already providing. A remembered answer is a second source of truth
    about something the archive can be asked directly. Every protection
    verdict, every placement and every reclamation precondition reads the
    number off the asset's own source, through
    `AppStore.placementPolicy(forAsset:)`, and an asset with no source recorded
    falls back to the same defaults as a photo in no group, above.

---

## The path

### The end state, stated once

So the target is legible without reading the steps.

**One archive. Any number of devices. No dependency that can be withdrawn.**

- A person with two devices, a phone and a work PC has **one** archive. Each device
  holds whichever photographs it holds, and all of them agree about what exists,
  where the copies are, and what is at risk.
- They are kept in step by **the drives already being carried between them**.
  Plugging one in is the whole interaction; there is nothing to sign into and
  nothing to configure.
- **Non-Apple clients read the same archive.** Windows and Android are not
  ports of this app — a client needs to read JSON off a mounted volume and
  reproduce a specified set of hashes. Read-only is enough to be worth having:
  browse the archive, see where copies are, see what is at risk.
- **Nothing about it can be taken away.** No account to be suspended, no API to
  be deprecated the way Google's was in March 2025, no company that has to still
  exist. The bytes are plain files; the catalog is portable SQLite; the sync
  format is documented text.

Two things are true of that end state and are not defects:

- **Two devices that never share a drive never converge.** The alternative is a
  network, and the network is what brings back the dependency.
- **Every device is pointed at each drive once, by hand.** A permission macOS
  gives an app for a drive cannot be transferred to another device, and Android
  works the same way. It is a floor, not a bug — the thing to get right is that
  it happens *once* per device, and that a new device is told what to expect
  rather than meeting an empty app.

### Next — multi-device

The machinery is built and tested; these are what stand between it and being
something to rely on.

1. **Testing on real removable media.** Everything is proven against directories
   standing in for drives, plus direct tests of the conditions a real volume
   adds — macOS's hidden files, a read-only mount, non-segment files, a torn
   tail. What has not happened is a drive actually being pulled out of a socket.
   `docs/TESTING-SYNC.md` is the procedure.

2. **A read-only client on one other platform.** The conformance vectors are
   what make this safe rather than hopeful. Read-only first: it needs only the
   shared tables, and it is where the format either proves portable or does not.
   Nothing structural is in the way any more — the zip reader was the last
   thing, and it is built.

### Next — no connector required

1. **In-place replicas on the host device.** A folder anywhere on this device's
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
   staging) as the asset's group asks for; every copy read back and matched at
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
8. **A courier, if it earns its place.** A share on the local network fixes the
   "two devices on one desk never share a drive" case with no account and no
   vendor. A folder in somebody's cloud storage would do the same over distance.
   Both are the same adapter — a place that lists, reads and appends files — and
   both are optional by construction (invariant 15).

---

## Loose ends, named rather than left

Things that are true of the code today and would otherwise be discovered by
somebody reading it and drawing the wrong conclusion.

- **`projected_version` is deliberately not journalled**, though it lives in a
  shared table. It records that *this* device has read a payload with *this*
  version of the reader — work, not archive. Its conclusions do travel.
- **The pre-split `drives` columns are still written and no longer read.** A
  build that predates the split reads them, so they stay until no such build is
  in use; `fetchTargets` takes all three from `drive_local_state`.
- **Invariant 13 is enforced at registration, and nowhere else.** A drive
  carrying another archive's marker is offered rather than overwritten
  (`DriveMarkerConflict`, `MarkerConflictTests`). Nothing checks a marker that
  changes *after* registration, because nothing writes one there — but that is
  an absence of a path, not a guard.

---

## Appendix: lessons

Earned against a real 248 GB archive. Each is a defect that shipped, with the
numbers it cost, because the number is what makes it memorable — and a lesson
compressed past its evidence is a slogan.

Rules that must not regress are invariants, above; these are the findings that
produced them and the ones too specific to be rules. Ten were removed for
saying what an invariant already says.
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
15. Risk belongs to the asset, not the replica. A copy read yesterday makes its
    asset safe no matter how stale the other copy is, and two copies both read
    six months ago are in more danger than either one alone suggests — so
    "oldest replica first" aims the reads at the wrong files. Order by the age
    of an asset's *freshest* copy.
16. "Move" is two operations wearing one word. Bytes the app wrote can be
    deleted after the new copy verifies; bytes the user put there can only
    stop being counted. A retarget sheet that does not separate them is
    promising to free space it will not free, or threatening a deletion it
    will not perform.
17. Removing a file is not removing what held it. Replicas are filed under the
    first two characters of their id, so draining a device left up to 256
    empty directories the app could not see and the user could — a folder tree
    still sitting there after the app said it had stopped using the drive.
    Deletion has to clean up the shape it made, not only the contents.
18. A moved folder is repointed, never re-copied.
19. Preferences live in ⌘,; the working screens show the archive itself.
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
26. Show the path even when the disk is not here. A path is the answer to
    "where is my stuff", and that question is asked most often precisely when
    the thing is unreachable; hiding the answer exactly then leaves the reveal
    button useful only when it is not needed.
27. A source is not only where content came from; it is somewhere that content
    still is. An export knew which drives held it and a folder did not, and
    that asymmetry was in the rendering, not in the model — the replica states
    were there the whole time.
28. An `UPDATE` cannot find a row that has not been inserted yet. The import
    claimed its assets for their source before writing them, so the claim
    matched nothing, and the reload at the end of every import replaced the
    in-memory answer with the empty one from disk — placement was right and
    the record of why was gone.
29. Unmeasured is not full. A device nobody can reach reports unknown free
    space, and reading that as zero made the archive refuse to owe anything to
    an unplugged drive — including, for one scan's worth of time, a drive that
    had just been registered.
30. A device that was never asked to hold something does not owe it. Export
    parts were graded against every registered device rather than the ones
    their export names, so a device holding none of the zips owed a copy of all of
    them for ever — and no change to the export's settings could clear it,
    because its settings were never consulted.
31. Withdrawing the task is not withdrawing the intention. Archive-level
    redundancy cancelled the queued copy for every asset an export covered, on
    every device, but only rewrote the pending replica rows on devices holding
    a part — leaving 15,345 rows on a device reporting work that nothing would
    ever do.
32. Two facts in one row is one fact too many. A source recorded both where
    photos came from and where they should be kept; the first cannot change and
    the second must, and the moment a group is made by hand there is no history
    to put in it. Splitting them cost a migration and removed a whole class of
    question with no answer.
33. Complete means "holds what it was asked to hold", not "holds everything".
    A device no group names fell through to `.complete` on the Drives map and
    read "Complete copy" while the card beneath it said "Nothing to hold yet" —
    the same screen contradicting itself, in the voice of the model that was
    replaced two revisions ago.
34. A source does not own a group; its photos merely happen to be in one. The
    source's card offered "change where these are kept" whenever a group could
    be found, so once photos had moved, editing one export's settings reached a
    group holding a different export's photos and changed those too. Membership
    moves and ids do not, so resolving a group by the id it was created with
    goes wrong exactly when it matters.
35. Two doors into one room is the whole cost. The elaborate rule about when a
    source's card could safely edit a group existed only because the card could
    edit at all; deleting that affordance deleted the rule, the question "does
    this override that?", and the class of bug underneath both. One setting,
    one place to change it.
36. Policy needs an object to hang on. Per-asset storage sounds like the
    simplest model right up to the first question about a *set* of photos —
    what do these want, why, and what else shares that answer — at which point
    there is nothing to ask. A group of one costs nothing and keeps the
    question answerable.
37. One thing at first contact, two when the second one exists. Sources and
    their groups are 1:1 until something is regrouped, and showing both from
    the start taught a distinction nobody had made yet — down to a Policies row
    reading "Recovered import (Google Takeout) — from Recovered import (Google
    Takeout)". A concept introduced before it does any work is a concept read
    as noise.
38. Requiring two drives at once is requiring a second cable. The export
    comparison checks filtered for parts whose every copy was readable, which
    on a one-cable setup is no part, ever — so an archive could sit for years
    reporting "not checked against the other copy yet" with no way to ever
    check it, and the message read as pending rather than impossible.
39. Copies and photos are two numbers, and the gap between them is the size of
    the archive. Counting replica rows and calling the total "assets" told a
    user with 24,639 photos that 49,236 had been checked — twice their whole
    archive. Nothing false was claimed about the checking; the label was simply
    on the wrong noun, which under invariant 2 is the same defect.
40. `unzip` cannot read a real Google export. It mangles every non-ASCII byte
    to a literal `?` — in its listing as well as on disk — then aborts
    mid-archive with a "disk full" error that has nothing to do with the disk,
    taking every entry after it. One Mac screenshot exported with a narrow
    no-break space in its name cost 4,673 of 6,660 sidecars from a single part,
    silently, down a code path that returned success. `tar` (libarchive) reads
    the same archive correctly. Reading entries to stdout does not rescue it:
    the only name to ask for comes from the same mangled listing, and the `?`
    it contains is unzip's own wildcard.
41. A partial read is worth more than no read. The extraction discarded
    everything it had already written whenever the tool exited non-zero, so a
    failure two thirds of the way through a part produced nothing at all — the
    status was treated as the answer, when the answer was on disk.
42. A capture date and a provider's timestamp are not the same clock. Google
    writes `photoTakenTime` in UTC; a date read from a photo's own EXIF carries
    no timezone at all, so the two differ by whatever the camera was set to.
    Matching them exactly looked right, passed its tests, and missed every
    photo whose clock was not on UTC — on a real archive, most of them.
    Anything within fourteen hours is explicable as a timezone rather than as a
    different photograph.
43. An album is a selection, not a screen. The photos in one are the same
    photos shown the same way, so albums and people are filters on the Library
    rather than a second grid — which would have duplicated the thumbnails, the
    hover previews, the protection marks and the selection mode, and given them
    somewhere to drift apart.

44. A provider's day is the provider's day. Google timestamps an album in UTC
    and prints the UTC day beside it; rendering that instant in the viewer's
    timezone moved it, so an album titled "Wednesday night in Northgate" came
    out as Thursday, and would have read differently again on a device
    elsewhere. Showing a recorded date in local time is a reinterpretation, and
    this archive does not reinterpret dates — see the timeline banner, which
    promises the same thing about capture dates it knows to be wrong.

45. Unknown kinds are skipped, never guessed at. Google's `enrichments` is a
    list of single-key objects and `locationEnrichment` was the only kind the
    first cut knew; the real archive also had `mapEnrichment`, a trip rather
    than a pin. Reading it as two more places would have said a weekend was
    spent in both its endpoints. What is not understood stays in the payload
    for a projection that understands it, which is the whole reason payloads
    are kept verbatim.

46. A backup is not complete because the photos are in it. Snapshot
    verification checked `integrity_check` and the asset count, which was the
    whole catalog when it was written. A snapshot taken later held all 24,639
    assets and none of the 24,417 provider payloads captured beside them —
    `asset_tags` was not even present — and was logged as verified. The test is
    now the general one: no table the live catalog holds rows in may be empty
    or absent in the copy, with the tables read from the schema so one added
    later is covered without anybody remembering to. Counts are not compared;
    tables legitimately shrink, and a whole category going missing is the
    failure that matters.

47. A row is withdrawable because nobody asked for it. Withdrawal of copies to
    revoked devices was gated on `pending`, the state a revoked copy starts in.
    But a scan reaching the row first looks where it claims, finds nothing, and
    marks it `missing` — after which withdrawal could never see it again.
    Twelve rows sat on a real archive reading as absent files on a device
    correctly told to hold nothing. The state a leftover is sitting in is
    incidental; what matters is whether anyone named that device. The one
    distinction worth keeping is between rows that assert nothing is there
    (`pending`, `missing`, withdrawable) and rows that assert bytes are on a
    disk (`present`, `drift`, never forgotten — releasing them is a separate
    decision the user makes).

48. Do not offer a choice whose right answer the app already knows. Four of the
    five actions on a drive were its own bookkeeping wearing a menu — confirm
    your own consistency, clear a queue, sweep folders a sweep already sweeps
    after every sync, and one that was the button it was listed inside. None is
    a decision a person has information to make. The related rule: an action
    belongs at the moment it means something. "Look for copies this drive
    already has" is right when a drive is plugged in and pointless as a menu
    item months later.

49. A reassurance that fails open is worse than no reassurance. The dialog for
    forgetting a Takeout download counted the photos that would be left with no
    copy — and built its lookup from the export's set id while replicas record
    the part's file name. Nothing matched, so it reported zero and said the
    download could be forgotten safely, on an archive where 21,380 photos live
    only inside it. The test agreed, because it had been written from the same
    assumption. When a number exists to stop somebody, check it against the
    real shape and assert that the wrong shape finds nothing.

50. One decision, one rule, wherever it is applied. The device picker counted
    devices and the screen that judges the result counted drives, so choosing a
    drive and this device satisfied "two copies" in silence and came back as an
    orange warning. The app let somebody build the arrangement it goes on to
    complain about. Wherever a choice is made and wherever its result is
    judged, the same question has to be asked the same way — and the place to
    say something is where the choice is made, not only afterwards.

51. Check the slogan against the code. "This device is the device your drives
    exist to survive" sounded like a reason and was used as one, to discount a
    copy on the host and to warn somebody off choosing it. It does not survive
    reading: a copy on a registered host target is written to the same replica
    root, verified the same way, and removed only when a group stops naming it
    — `reclaimStaging` frees the staging area, never a target's replicas. If
    the device dies, a photo on it and on a drive still has the drive. Automatic
    placement still prefers drives, for the reason that is true: a boot disk
    rarely has room. A sensible default is not the same claim as a lesser copy.

52. A test written from the code's assumption confirms the assumption. Four
    times in one day: the truncated content hash, the export set id, the
    `zipmember:` prefix, and the host-is-not-a-place split. Each had a passing
    test asserting exactly what the code already believed. A test earns its
    keep by being written from the *shape of the real data* — which means
    looking at the data — or by asserting that the wrong shape finds nothing.

53. A subset is counted in the units of the set it sits under. Keep safe led
    with "Every photo is in 2 places", totalling 21,401, and said directly
    underneath that "24,618 of them are inside your Google Takeout files" — a
    subset larger than the set it was drawn from, printed one line apart. Both
    numbers came off the same pass over replicas; only one of them had been
    filtered to photos, because a Live Photo is one photo and two files. A
    reader who notices that stops believing the rest of the screen, and they
    are right to. Where two numbers appear in one sentence, they are counted
    by one rule.

54. A walk of the whole archive must not hide behind a computed property.
    `photoCountByStorageGroup` looked like a field and walked 24,639 assets on
    every read. That was survivable while one list read it once, and became a
    ten-second freeze when the grid read it per cell — and from inside a sort
    comparator, where every comparison paid for a full pass. What made it hard
    to find is that it did not present as slowness: the top row of the grid
    simply did not respond to clicks, three times in a row, while the rows
    below it opened instantly. Cost that scales with the archive belongs where
    the archive changes, not where it is drawn.

55. Verify against an idle app, or verify nothing. The same freeze was being
    caused a second way — the Takeout pipeline and the volume scan run on the
    main actor after a drive connects — so for the first minute after launch
    every click appeared to be ignored and every screenshot showed the state
    before the last one. Two real bugs and one harmless startup were producing
    the same symptom. Watch the process settle before believing what the
    screen says about a click.

56. A draft is where illegal states are allowed to exist. A sheet of checkboxes
    could only offer legal moves, so it never needed the idea. Direct
    manipulation cannot: picking a group's last placement up off a device is
    half of putting it down somewhere else, and turning the copy count past the
    number of devices named is how you discover you need another one. Both are
    reasonable things to be in the middle of and neither is a reasonable thing
    to save. So the edit is composed in a value the catalog never sees,
    `problem` says whether it could be saved, and the whole of it is committed
    in one write or discarded. Prevent the *commit*, not the gesture — refusing
    the drag hides the rule and leaves somebody guessing why the app fought
    them.

57. A control with two ways in needs testing both ways. The cell that accepts a
    dragged placement also accepts a click to add one. `dropDestination`
    silently swallows `onTapGesture`, so the drop worked and the click did
    nothing — and the reverse arrangement, a `Button`, takes the mouse-down a
    drag begins. Neither failure is visible while testing the other. A
    synthetic click cannot start a macOS drag session either, so the gesture
    itself is only ever verified by hand: what can be tested is the rule
    underneath, which is why it lives in `StoragePlacementDraft` and not in a
    view.

58. Reload what changed, not everything. Three places wrote a little and re-read
    the whole catalog: queueing forty background verification reads, recording
    archive-level redundancy that recorded nothing, and the Takeout pipeline's
    closing refresh after a drive turned out to hold exactly what was expected.
    Each cost a full read of every table and a rebuild of every derived one, on
    the main actor. The queue has nothing derived from it at all. Reach for the
    narrow reload, and make the wide one conditional on having done something to
    justify it.

59. Version both layers, and know which one you are in. Reading a provider
    export happens twice over: **capture** takes bytes out of the export and
    keeps them verbatim, **projection** decides what those bytes mean. Only
    projection was versioned. That is the cheap half — being wrong about
    meaning costs a re-derivation from rows the catalog already holds, which
    is why `currentProjectionVersion` can sit at 4 without anyone noticing the
    first three. Being wrong about *capture* is only recoverable while the
    export still exists, which is the entire reason the exports are kept. So
    the reader has a version too, recorded per export part — keyed by the part
    rather than by the drive's copy of it, because a zip on one drive and its
    unzipped twin on another are the same content and reading either reads the
    same sidecars. A part with no record counts as behind: everything imported
    before the reader was versioned was read by something older than version 1
    by definition, and treating silence as current would exempt every existing
    archive from the one check this exists to make.

60. Moving a file moves everything that names it. An export can be relocated
    into the app's folder on the drive it already sits on — a same-volume
    rename, instant however large. The bytes are the easy part. On a real
    archive 42,754 recorded copies name their export by its *stem*, which no
    move can disturb, and 6,482 name it by its **path inside the mount**: a
    photo counted inside a zip records that zip's location. Moving the folder
    without rewriting those leaves 6,482 copies reading as present, on a
    connected drive, at a path with nothing there — the worst kind of wrong,
    because every check that only consults the catalog agrees the archive is
    fine. So the rewrite happens with the move, the count is on the preview
    before anybody agrees to it, and it is a prefix swap rather than a search
    and replace: the folder's name can occur again further along the same
    string, inside the zip's own entry list, where it is an album and not a
    location.

61. State the fact whether or not the drive is here; gate only the doing. The
    line saying a drive holds an export twice was first shown only for
    connected drives, which is the rule the *button* needs, not the rule the
    *sentence* needs. 254 GB that disappears from the screen when somebody
    unplugs a drive is 254 GB nobody ever gets round to deciding about — and
    the catalog knows it either way. What needs the drive present is removing
    something from it, and that gates itself.

62. Name a button after what it does, not after what it is for. "Copy them out
    of the download" unpacked a zip into a folder beside it — and a photo in
    that folder is still counted as being inside a download, so the one thing
    the name promised was the one thing it did not do. What it actually buys is
    a copy that can be re-read without decompressing 127 GB; what it costs is
    the same bytes again, which the name never mentioned. Both belong in the
    label.

63. A check that reads nothing may not set the field that means "read". The
    background patrol exists because reading bytes is the only thing that finds
    rot. For a copy counted inside an export part there are no bytes of its own
    to read, so it was confirmed by looking for a file with the right name — and
    then stamped `lastVerifiedAt` anyway. That is how 21,117 photos came to be
    reported as *all read back*: the reassurance the patrol exists to earn,
    awarded for the one check incapable of earning it. Worse, finding that name
    meant enumerating a 2 TB volume from its mount point, once per photo, to
    rediscover a path the catalog already held — so the forty files read every
    half hour were almost never files, almost never read, and cost a recursive
    walk of the disk each. Ask what a check proves before deciding what it is
    allowed to record.

64. Ranking by staleness is not the same as knowing something is stale. The
    patrol sorted candidates by how long since their freshest copy was read and
    took the top forty, without ever asking whether the top one was old enough
    to be worth reading. On a large archive that is invisible — something is
    always genuinely old — and it hid the defect completely. On a small
    eligible set it means reading everything, over and over: thirty-three
    candidates against a budget of forty is a drive marked in use forty-eight
    times a day to re-read the same thirty-three files. A floor fixes it, and
    belongs to the *background* pass only: somebody who asks for a check is
    never answered with "I looked this morning".

65. Two copies in different shapes are still two copies. A part held as a zip
    on one drive and as the folder unpacked from it on another cannot be
    compared by size or hash — they are different encodings of the same photos,
    so the numbers will never match and no amount of checking will make them.
    The grading fell through to `singleCopy`, so every part of an export went
    orange reading "one copy only" directly beneath a line saying it was on
    every drive. "Enough drives hold it and I cannot compare them" is not "one
    drive has it": the first is information, the second is an alarm, and only
    one of them was true. Note that the archive-wide safety headline was right
    throughout — it counts replicas per photo, which do not care what shape the
    bytes are in. Two subsystems reading different tables can disagree, and the
    one drawing a conclusion is the one to doubt.

66. A detail panel accretes, because every feature adds a line and none removes
    one. The group panel ended a day's work with four stacked sentences saying
    overlapping things, a caption naming the row the reader had just clicked,
    per-device photo counts already printed in the cell directly above, and six
    controls — re-read, relocate per drive, unpack, spot check, full check, stop
    tracking — laid out across a box that has to fit under a table row. Every
    one of them was added for a good reason and none was weighed against what
    was already there. The rule the rest of the app already follows applies
    hardest here: the *finding* stays on screen and the paragraph explaining it
    goes behind the mark, one verb stays visible and the housekeeping goes in a
    menu.

67. Do not reach for a layout container that measures what you have already
    decided. The table's widths are constants, so `Grid` was aligning columns
    it did not need to measure — and a cell spanning every column, inside a
    grid, inside a horizontally scrolling view, sized itself hundreds of points
    taller than its contents and pushed every row below it off the screen.
    Stacks with explicit frames do the same job and cannot do that.

68. Two controls that look redundant may mean different things — say which.
    Naming devices and asking for a number of copies look like the same
    question asked twice, and are not: the devices are *n*, the count is *k*,
    and the planner walks the named devices in order and stops at k, so a third
    device with the count at two is a spare for when one of the first two is
    full, away, or already holds the photo. That is the whole k-of-n design and
    the editor never said it — a tick list and a stepper side by side, with
    nothing between them to explain why both exist. The fix is not to remove one
    but to write the arrangement out: *every photo on all three*, or *two
    copies — A and B first, and C when one of those cannot take it*.

69. Preserve the arrangement somebody is already in. Ticking another device
    almost always means "and this one too", so if every named device held a
    copy, the new one does; if spares were already in use, it becomes another
    spare. Removing one works the same way, which also stops the app answering
    a deletion with a complaint about an arrangement nobody asked for. Doing
    neither leaves the count quietly meaning something else than it did a
    moment ago, and nobody notices until a drive is emptier than expected.

70. Weight a control by the size of what it does. Renaming a group sat in a
    menu beside removing one — the lightest change in the app and the heaviest,
    two clicks each, indistinguishable. A name is renamed by double-clicking
    it, the way a name is everywhere else, and the menu keeps the thing that
    deserves a menu.

71. A way out that the framework can route away is not a way out. Escape was
    supposed to abandon an in-place rename and simply did nothing: neither
    `onExitCommand` nor `onKeyPress(.escape)` reached a focused `TextField`.
    That mattered more than a missing shortcut, because clicking away *commits*
    — so a name typed by accident had no way back at all, and the app would
    have quietly kept it. The fix is a control on screen, which cannot be
    swallowed by a responder chain. Reach for the visible affordance when the
    invisible one is the only thing standing between somebody and an
    irreversible-looking change.

72. Move the files first, then the catalog. A catalog told about a move that
    did not happen describes an archive nobody has, and nothing will ever
    correct it. A file that moved with the catalog not yet updated is found
    again by the path repair that already runs on every connect. Only one of
    those two is recoverable by doing nothing, and that is the one to fail
    towards.

73. A rule named after a place stops being the rule it meant when the place
    gains a second purpose. `ExportSetLayout.home` excluded the whole of the
    app's folder, on the reasoning that a part parked there is waiting rather
    than living — true while the only thing in that folder was the waiting
    room. Relocation put a *deliberately chosen* home inside the same folder,
    and the rule then read it as no home at all: `rehomeDeliveredParts` had
    nowhere to take a delivered part, so it would have sat in the waiting room
    for ever. Nothing failed, nothing was logged, and the archive was left one
    delivery away from a silent no-op. Exclude the thing the reason is about —
    the waiting room — not the folder it happened to be the only occupant of.

74. Stamping every column of a write is row-scoped last-writer-wins in
    disguise. Every upsert here rewrites the whole row, so the obvious
    implementation has each write claim authorship of every field — and a device
    that changed one column overwrites another device's edit with the stale
    value it happened to be carrying. The per-field test caught it at once:
    *both* devices lost the rename. Stamp only what actually moved, which means
    reading the row before and after, because an upsert cannot say which values
    it changed.

75. A coverage test at the wrong granularity is worse than none, because it is
    believed. "Every shared table records something" passed while eleven
    separate statements wrote to those same tables and recorded nothing —
    assigning a photo to a group, pointing it at a source, repointing a copy
    that moved, deleting a photo. Test the write *paths*, not the tables.

76. A sync test that creates and modifies in one breath passes with the bug
    still in it. A new row's creation stamp expands to every column at send
    time, reading current values — so an unrecorded change to a row the other
    device has never seen travels anyway, carried by the creation. It only bites
    once the row is known elsewhere. Sync first, then change, then sync again;
    and prove the test fails without the fix.

77. Measure the path nobody is watching, not only the one they are. An import is
    slow in front of somebody who asked for it; a first sync is slow on a device
    that has just had a drive plugged in. That one was five and a half minutes
    and nobody would have known until it happened to them.

78. Assert in seconds against a real archive, not in multiples of a baseline.
    The import baseline is a bare INSERT at ten microseconds, so any bookkeeping
    at all looks like a large multiple while costing nothing anybody can feel.
    A threshold should fail when a person would notice.

79. Anything stored and later compared must have a defined encoding, or the
    language quietly supplies one. Swift dictionaries have no iteration order,
    so re-saving an asset whose EXIF had not changed produced different text
    every time — invisible while the column was only written and read back, and
    with a journal it would have made every routine rescan look like the whole
    archive being rewritten.

80. Sorting is an encoding. Swift's `String` ordering is Unicode collation, not
    bytes; Rust, Kotlin and C# each do something else, and the differences only
    appear outside ASCII — so the mistake ships, and surfaces years later on one
    person's archive. Found three times in this codebase before it bit anything.

81. A protocol earns its place when a second implementation is real and when
    failure is otherwise untestable. One seam — a place that lists, reads and
    appends files — bought the drive, the future courier, and the ability to
    test a yanked drive without a drive. Everything else stayed concrete.

82. Interrupting a write is not the whole failure; resuming after one is. A
    torn tail cost the records inside it, which was expected. What was not: the
    writer believed it had sent them, so nobody would ever offer them again —
    and appending after a half-written line splices onto it, which a reader stops
    at, blocking everything written afterwards for ever. Three fixes, and the
    first two alone left it broken.
