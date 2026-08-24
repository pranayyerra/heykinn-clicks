# Testing checklist

Manual passes before a release. Everything here was checked against the code on
2026-08-23 — paths, filenames and thresholds are the real ones, so a step that
fails is a bug rather than a typo in this document.

**Re-check this date against the code before trusting the file.** Between
14 and 23 August it described an app that had changed underneath it in four
places: it promised a source folder was never touched, tested a setting that had
been removed, quoted a test count wrong by two hundred, and said nothing at all
about the screens most of the week's work went into.

**Rule for adding to this file:** if you cannot point at the code that does it,
it does not go in. A checklist that describes features nobody built is worse
than no checklist — a tester files bugs against vapour and stops trusting the
rest of it.

---

## Setup

Point every pass that is not specifically about the real archive at a throwaway
one. Otherwise testing a screen means changing an archive somebody depends on.

```bash
HEYKINN_ARCHIVE_DIRECTORY=/tmp/scratch-archive HEYKINN_NO_BACKGROUND_WORK=1 \
  ./build/HeykinnClicks.app/Contents/MacOS/HeykinnClicks
```

- [ ] macOS 14.0 (the minimum) and current macOS
- [ ] **A Mac that has never had Xcode on it.** Photos access works in
      development only because Xcode is the responsible process and already
      holds the grant. A Mac with Xcode cannot tell you whether the bundle earns
      its own permission, which is the whole reason it exists.
- [ ] Two devices to hold copies. A target is a **device**: this Mac (holding
      its copy in a folder you choose) or an external drive. **Mac plus one
      drive is a valid setup** — two external drives are not required.
- [ ] One pass where the two drives are **never mounted together**, which is an
      ordinary constraint and the case the Mac-side bridge exists for
- [ ] One exFAT drive: no native extended attributes, so macOS writes a `._`
      sidecar per file, and timestamps land on two-second granularity
- [ ] Use a clean macOS user or a test archive. A signed release normally keeps
      the archive under
      `~/Library/Group Containers/344B87D3CV.com.heykinn.HeykinnClicks/HeykinnClicks`;
      `~/Library/Application Support/HeykinnClicks` is the legacy fallback.

## Automated first

```bash
swift test                                    # green, with the environment-dependent ones skipped
HEYKINN_DMG_TESTS=1 swift test --filter DriveIdentity
HEYKINN_VOLUME_TESTS=1 swift test --filter 'DriveResilience|TargetMonitorThreading'
```

The DMG and mounted-volume tests are **skipped** without their flags — a green
run without them does not mean they passed. Mounted-volume tests deliberately
require an opt-in because enumerating every root can touch or block on a real
USB drive attached to the developer's Mac. Manual testing is for what a test
cannot see: whether a screen is comprehensible, whether a prompt appears,
whether an operation feels finished when it says it is.

---

## Not built — do not test these

Listed because an earlier draft of this document tested all of them.

| | |
|---|---|
| Welcome / onboarding screen | No such view exists |
| Drag-and-drop import | No `onDrop` anywhere |
| Cancelling or resuming an import | Only *sync* can be cancelled |
| Drift queueing a re-copy | Drift marks the replica; nothing queues repair from it |

Two rows left this table rather than being deleted from history: **restoring a
catalog from a snapshot** is built and is tested under section 6, and the **Help
menu and keyboard shortcuts** exist — `HeykinnClicksApp` declares `Commands`
through `HeykinnCommands`. Both were listed here as not built long after they
were.

---

## 1. Bundle and first launch

- [ ] Launches from `/Applications`, not via `swift run`
- [ ] Shows as "Heykinn Clicks" in the Dock and menu bar
- [ ] Console is quiet — no `com.apple.linkd.autoShortcut` failures. Their
      absence is what says the bundle identity took
- [ ] Gatekeeper allows it (needs notarisation for anyone else's Mac)
- [ ] Opens to Overview, not a blank window
- [ ] First launch starts empty — nothing is seeded, and the screens say what to
      do rather than showing zeroes

## 2. Permissions

- [ ] **On a Mac that has run an earlier build, reset first.** A privacy grant
      is recorded against the code identity that asked for it, so a re-signed
      build is refused with no prompt at all and the app truthfully says access
      was declined. `tccutil reset Photos com.heykinn.HeykinnClicks`. Not needed
      on a machine seeing the app for the first time — which is the machine this
      section is meant to be walked on.
- [ ] **Test the bundled app, never `swift run`.** This section is the one place
      that distinction decides the answer. `swift run` produces a bare binary
      with no hardened runtime, and Xcode holds the Photos grant on its behalf,
      so permissions appear to work at a desk where they are in fact untested.
      The bundled, signed app was refused the Photos library for months while
      development worked perfectly — one missing Hardened Runtime entitlement,
      and the refusal is silent. Check `bundle.sh`'s entitlement report says
      `✓ Photos library access` before starting.
- [ ] **Open it from `/Applications`, and eject the installer first.** An app
      launched from a mounted disk image is translocated to a randomised
      read-only path, and macOS refuses a translocated app every permission
      there is. The app now says so instead of blaming a setting, but a test run
      from the image tests nothing.
- [ ] Connecting Apple Photos prompts, with the wording from
      `NSPhotoLibraryUsageDescription`
- [ ] The grant appears under System Settings → Privacy & Security → Photos
      against **Heykinn Clicks**, not against Xcode or Terminal
- [ ] Denying it is reported as "macOS is blocking access" with a route to fix
      it, and does not crash
- [ ] First registration of an external drive prompts for removable-volume access
- [ ] In the sandboxed App Store build, a drive chosen once is reachable after
      quitting and relaunching; no mounted-volume sweep is assumed
- [ ] New external-drive registration obtains access through a real user choice
      in the sandbox (not merely a URL learned from volume enumeration), then
      writes its marker and a sample replica successfully
- [ ] **Keep safe → Add Drive** is present even when the sandbox cannot list
      any unregistered mounted volume

## 3. Sources

### Folders
- [ ] "Choose a folder…" imports photos and videos; hidden files and package
      contents are skipped
- [ ] The folder's **full path** is recorded and shown, with Reveal in Finder
- [ ] Re-importing the same folder recognises everything as already held
- [ ] The source folder is **untouched by the import** — verify in Finder.
      Clearing it out afterwards is the one thing the app will do to it, and
      only when asked; that is section 5

### Google Takeout
- [ ] Finds zips and extracted folders on a connected target
- [ ] Groups split parts into export sets and names the missing part numbers
- [ ] Extracts into a `.extracting` temp directory and renames on completion
- [ ] Force quit mid-extraction leaves `.extracting`, never a broken `Takeout`;
      startup clears it
- [ ] Refuses to extract when the drive lacks room
- [ ] Sidecar capture date wins over the file's own metadata
- [ ] Live Photos pair even when the still and motion halves are in different parts
- [ ] Assets appear in the Library as parts are processed, not all at the end
- [ ] A drive holding the export is credited with the photos inside it — **no
      per-photo copies written to that drive**

### Apple Photos
- [ ] Indexes the library and reports how many the archive already has
- [ ] Originals are copied in; ones already held byte-for-byte are recognised,
      not stored twice
- [ ] The iCloud question is asked, not guessed

## 3b. What the screens say

Added because the two defects a walkthrough found last time were both here, and
neither was reachable from a test: a sentence built inside a view, and a badge
whose colour disagreed with the screen next door.

- [ ] **Adding photos states its plan rather than asking.** Choosing a folder
      gives one sentence — *"Every photo on Nina's Back and My Passport"* — with
      `Change…` beside it, not a form. The form is still there behind the link,
      and opens by itself if the set already names its own drives
- [ ] **The reason is only given when there was a choice.** Two drives and two
      copies says just where they go; three drives and two copies adds *"the
      devices with the most room"*. On a fresh install with no drive it names
      this device and claims nothing about room
- [ ] **One answer to "are my photos safe".** Overview and Keep safe open with
      the same sentence, and a photograph's own badge agrees with it — a photo
      held in one place is never labelled safe while the archive warns about it
- [ ] **A damaged copy is reported as damaged**, not as still copying
- [ ] **Keep safe shows one line** while every set of photos is kept the same
      way, with `Show each set of photos` to expand. Give one set different
      drives or a different copy count and the rows come back on their own
- [ ] **Plugging in a drive nobody has claimed asks one question**, with two
      named buttons. A drive already in use asks nothing; a drive carrying
      another archive's ID file asks nothing and is left alone
- [ ] **Nothing on screen uses a word the app invented.** The photo library's
      filter reads *All photos · My drives · iCloud · Google Photos*. Registering
      a drive says an ID file, not a marker. `DocumentedRulesTests` enforces the
      list; a walkthrough is what catches a word that is technically allowed and
      still wrong

## 4. Targets and replication

- [ ] Registering writes `.heykinn-clicks-drive.json` at the volume root
- [ ] Registering **this Mac** works by choosing a folder, and is refused if
      that folder is really on an external drive
- [ ] Refuses a second target that shares storage with an existing one
- [ ] Refuses to register a folder that will not fit the archive plus reserve
- [ ] Copies land under `HeykinnClicks/Replicas/` — capital R
- [ ] A drive is recognised after being renamed and after mounting at a
      different path
- [ ] Disconnecting mid-sync leaves the rest queued; reconnecting resumes
- [ ] Protection moves staged → one copy → fully replicated, and the Library
      agrees with the Overview — including the wording, not only the counts
- [ ] **A new drive is used by imports that came before it.** Register a drive
      after importing, and a set that works out its own devices adopts it and
      queues the copies; the audit log says how many it took. A set given
      specific drives by hand is left alone, deliberately

## 5. Placement, adoption, reclamation

The newest behaviour, the least exercised by hand, and the only part that
deletes anything. Walk it deliberately.

### A target credited with what it already holds
- [ ] Import a folder that sits on a drive **before** registering that drive;
      confirm the photos are staged
- [ ] Register the drive, let the connect sequence finish. **No file should ever
      appear under `HeykinnClicks/Replicas/`** — the copy is withdrawn, not
      written and then removed. Check in Finder, not just the UI
- [ ] Sources marks that folder as holding the archive's copy
- [ ] Rename the folder on the drive and reconnect: repaired, not re-copied

### Reclaiming a duplicate that already exists
- [ ] Same setup, but let the sync write the app's own copy first
- [ ] "Look for copies this drive already has" on the drive card
- [ ] The catalog points at **your** file, the app's duplicate is gone, and your
      original is untouched — verify all three in Finder

### Releasing the working copy
- [ ] One target only: nothing is released, whatever the disk pressure
- [ ] Both targets holding it and each read back: the working copy goes, and
      Keep safe said so *before* it happened
- [ ] Quit mid-release, relaunch: nothing loses its last copy, and staged files
      nothing references are swept up
- [ ] **There is no setting for this any more.** Settings → Automation has three
      switches and none of them is about freeing space; the release condition is
      `.fullyReplicated`, which is every copy present *and* read back

### Clearing out a folder you imported from

New, and the only place the app offers to delete something that is yours.
Everything else it deletes is its own.

- [ ] Import a folder holding photographs **and something that is not one** — a
      `.txt`, a video it does not handle. Let the copies finish and be read back
- [ ] Add photos → the folder's row → **"Is this folder still needed?"**
- [ ] The sheet names how many files would go and how much that frees, and says
      the folder stays
- [ ] The thing it never imported is counted separately, and the sentence about
      it reads correctly for **one** file as well as several
- [ ] Confirm: the photographs are in the **Trash** — recoverable, not unlinked —
      and the stranger is still in the folder. Verify both in Finder
- [ ] Edit one photograph in the folder before clearing: it is not offered,
      because its bytes no longer match anything the archive holds
- [ ] With copies that have never been read back, the offer refuses and says so
- [ ] No drive needs to be plugged in for any of this

### Two drives never connected together
- [ ] Import, sync to drive A only, let the staged copy be released
- [ ] With **only A** connected, the app holds on the Mac what B is owed and
      says so in the audit log
- [ ] Unmount A, mount B: B receives the photo with A absent throughout
- [ ] The held copy is then released — the bridge must not become storage
- [ ] With the boot disk near full it bridges what fits and leaves the rest

### An export down the wrong path
- [ ] An extracted export chosen via "Choose a folder…" is refused, and the
      export route offered
- [ ] A renamed export is still recognised, by structure not name
- [ ] Sweeping a whole drive steps over an export sitting on it

## 6. Verification and health

- [ ] A fresh copy reads as awaiting its first check, not as verified
- [ ] Verification re-reads and confirms; a hand-edited replica is caught
- [ ] "Not checked recently" appears past **30 days** (`verificationMaxAge`),
      and is distinguished from never checked
- [ ] A drive that is merely absent is never reported as damaged
- [ ] Snapshots land in `HeykinnClicks/CatalogBackups/` on each target
- [ ] A snapshot is verified against the asset count before it is published; a
      bad one is deleted and logged
- [ ] The **three** newest are kept per drive (`CatalogBackupService.retainCount`)

### Restoring one

The half that had never been exercised outside tests. Settings → Safety →
Restore.

- [ ] Lists snapshots from every connected drive, newest first, each with its
      date, photo count and which drive it is on
- [ ] Import something, then restore a snapshot from before it: the archive goes
      back, and the imported photos are no longer in the Library
- [ ] The photos themselves are **completely untouched** on every drive — verify
      in Finder
- [ ] The replaced catalog is kept as `catalog-replaced-<stamp>.sqlite` in
      the resolved archive directory, and opening it shows the archive as
      it was *before* the restore, including anything imported minutes earlier
- [ ] The restore is written into the audit log of the restored catalog
- [ ] Refused mid-sync and mid-import, saying which
- [ ] **Unplug the drive between opening the sheet and pressing Restore** — the
      snapshot is re-read at the last moment, so this must refuse and say to
      reconnect, not fail half way
- [ ] A deliberately corrupted `.sqlite` in `CatalogBackups/` is not offered at
      all
- [ ] After restoring, reconnect each drive and confirm its copies are re-checked
      rather than treated as missing

## 7. Durability

- [ ] Force quit mid-import: no half-written asset, no batch counting photos
      that are not there
- [ ] Force quit mid-sync: backlog preserved, `.partial` files discarded
- [ ] Pull a drive during a copy: recorded as still owed, never as damaged
- [ ] Fill a target during a sync: fails clearly and stays queued
- [ ] Every audit event that should exist does — the log is the record of what
      happened to the archive

## 8. Data integrity

- [ ] A photo's hash matches after a full round trip through staging and both
      targets
- [ ] Counts agree across Overview, Library, Sources and Drives
- [ ] No asset points at a batch that does not exist; no replica at an asset
      that does not exist
- [ ] `PRAGMA integrity_check` returns `ok` after a heavy session

## 9. Uninstall

- [ ] Quitting leaves no stuck process
- [ ] Deleting the app leaves the archive on the drives intact and readable
- [ ] What remains in `Application Support` is documented
- [ ] Reinstalling and re-registering a drive adopts its content in place rather
      than copying it again

---

## Sign-off

- [ ] Exact submitted/TestFlight build tested on each device/OS listed in App
      Review Information
- [ ] Guideline 2.1 screen recording starts with launch, shows the complete
      typical flow and every permission prompt, and plays to completion after
      upload
- [ ] Every section above passed on a clean machine
- [ ] `swift test` green, including the DMG tests with the flag set
- [ ] Walked once against the real archive, read-only where possible
- [ ] Known gaps in `docs/KNOWN-GAPS.md` still accurate
