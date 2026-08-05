# Production Testing Checklist

Before shipping any production release of Heykinn Clicks, validate against this checklist. Each item should pass on a clean macOS installation with no prior app state.

## Pre-Release Testing Matrix

### Environment Setup
- [ ] Fresh macOS 14.0 installation (minimum supported version)
- [ ] macOS 15.x (current)
- [ ] **A Mac that has never had Xcode on it.** Photos access currently works
      in development because Xcode is the responsible process and already holds
      the grant. A Mac with Xcode cannot tell you whether the bundle earns its
      own permission — which is the entire reason the bundle exists.
- [ ] Two devices to hold copies. A target is a *device*, so this can be **this
      Mac plus one external drive** — two external drives are not required, and
      anything claiming otherwise is wrong. Two DMG volumes work for
      replication testing.
- [ ] At least one run where the two drives are **never mounted at the same
      time**, which is an ordinary constraint (one port, one bay) and the case
      the Mac-side bridge exists for
- [ ] An exFAT drive among them — it behaves differently: no native extended
      attributes, so macOS writes a `._` sidecar per file, and its timestamps
      have two-second granularity
- [ ] Clean `~/Library/Application Support/HeykinnClicks/` (delete existing catalog)
- [ ] Clean preferences for `com.heykinn.HeykinnClicks`

> Use `HEYKINN_ARCHIVE_DIRECTORY=/some/scratch/dir` and
> `HEYKINN_NO_BACKGROUND_WORK=1` to point a build at a throwaway archive. Every
> manual pass that is not specifically about the real archive should use it —
> otherwise testing a screen means changing an archive somebody depends on.

---

## 1. Installation & First Launch

### App Bundle
- [ ] App launches from `/Applications` (not from SwiftPM `swift run`)
- [ ] Icon displays correctly in Dock and Finder
- [ ] App name shows as "Heykinn Clicks" (not "HeykinnClicks" or bundle ID)
- [ ] Gatekeeper allows launch (must be notarized for external testing)
- [ ] No "damaged app" or "unknown developer" warnings

### First Launch Experience
- [ ] Welcome screen appears on truly first launch
- [ ] Can navigate through all 4 onboarding pages
- [ ] Settings from page 4 are applied (`desiredCopies`, auto-sync, auto-Takeout)
- [ ] Clicking "Get Started" dismisses welcome and shows main window
- [ ] Second launch does NOT show welcome screen again
- [ ] Main window opens to Overview (not blank screen)

### Permissions
- [ ] App requests Photos library access when connecting Apple Photos
- [ ] Photos permission appears in System Preferences > Privacy & Security > Photos
- [ ] App requests file access when selecting external volume
- [ ] Can grant/revoke permissions in System Preferences
- [ ] App handles "permission denied" gracefully (error message, not crash)

---

## 2. Core Functionality

### Import from Mac
- [ ] Can select files via file picker
- [ ] Can drag-and-drop files onto window
- [ ] Import progress shows with current file name
- [ ] Can cancel import mid-flight (gracefully stops)
- [ ] Cancelled import resumes from checkpoint on retry
- [ ] Imported assets appear in Library immediately
- [ ] Import batch recorded in audit log
- [ ] Duplicate detection works (re-import same file = recognized as duplicate)

### External Drive Registration
- [ ] Can register first external drive (shows in Storage & Health)
- [ ] Drive marker file created at drive root (`.heykinn-clicks-target-<UUID>`)
- [ ] Can register second drive (up to `desiredCopies`)
- [ ] Cannot register more drives than `desiredCopies` allows (error shown)
- [ ] Drive persists across disconnect/reconnect via bookmark
- [ ] Drive name displayed correctly (volume name, not `/Volumes/...`)

### Replication
- [ ] Importing asset with 2 drives connected queues to both
- [ ] Replication starts automatically (if auto-sync enabled)
- [ ] Progress bar shows current file and completion %
- [ ] Can cancel sync (stops after current file)
- [ ] Disconnecting drive mid-sync pauses for that drive
- [ ] Reconnecting drive resumes sync from where it stopped
- [ ] Replicated files copied to drive under `HeykinnClicks/replicas/`
- [ ] Replica paths recorded in catalog
- [ ] Protection state updates: StagedOnly → ReplicatedToOne → FullyReplicated

### Verification
- [ ] Freshly replicated files start as "Awaiting First Check"
- [ ] Verification reads replica and compares hash
- [ ] Matching hash promotes to "Fully Replicated"
- [ ] Mismatched hash triggers "Drift Detected" (test: manually edit replica)
- [ ] Drift detection queues re-replication task
- [ ] Verification failure logged in audit log

---

## 3. Google Takeout Workflow

### Scan
- [ ] "Scan for Takeout" finds `takeout-*.zip` on drive
- [ ] Detects extracted `Takeout/` folders
- [ ] Groups split parts into export sets (e.g., `takeout-20250101-001.zip` + `-002.zip`)
- [ ] Warns when part numbers have gaps (e.g., 001, 002, 004 missing 003)
- [ ] Re-scan updates size/part info without losing import state

### Extract
- [ ] Can extract zip in place on drive (not to Mac scratch space)
- [ ] Extraction shows progress (files processed)
- [ ] Creates `.extracting` temp folder, renames on completion
- [ ] Interrupted extraction (force quit) leaves `.extracting`, not broken `Takeout`
- [ ] Startup reconciliation deletes abandoned `.extracting` folders
- [ ] Free space check prevents extraction if drive too full

### Import
- [ ] Import processes media files + JSON sidecars
- [ ] Google capture date from JSON wins over EXIF
- [ ] GPS coordinates extracted from JSON
- [ ] Live Photos paired across parts (still in 001, motion in 002)
- [ ] Unpaired motion videos importable as standalone videos
- [ ] Edited variants linked to originals
- [ ] Assets appear in Library incrementally (not all at end)
- [ ] Import progress shows: "Processing part 3 of 12: 1,842 / 2,156 files"

### Archive-Backed Replicas
- [ ] Assets imported from Takeout folder use folder files as replicas
- [ ] No duplicate copy written to same drive (only to second drive)
- [ ] Drive-only assets (no staging copy) still appear in Library
- [ ] Previews work when drive connected
- [ ] Previews show placeholder when drive offline

### Reconciliation
- [ ] Second drive with same Takeout zips claims via hash verification
- [ ] Fingerprinting shows: "Verifying existing copies on DriveB"
- [ ] Matched zips avoid re-copying (backlog tasks cancelled)
- [ ] Reconciliation skipped for drive already backing this part
- [ ] Reconciliation succeeds even if zips renamed (structure match)

---

## 4. Protection & Health

### Protection State Computation
- [ ] Overview card shows breakdown: X staged, Y awaiting check, Z fully replicated
- [ ] Breakdown matches individual asset states in Library
- [ ] Protection updates in real-time during sync
- [ ] "Verification Overdue" appears for assets not checked in 90 days (test: mock timestamp)

### Catalog Backup
- [ ] Snapshot created on launch (if >24h since last)
- [ ] Snapshot created after import completes
- [ ] Snapshot created when drive connects
- [ ] Snapshot written to `HeykinnClicksCatalogBackups/` on each drive
- [ ] Snapshot verified (asset count matches) before publishing
- [ ] Failed verification deletes bad snapshot, logs error
- [ ] Five newest snapshots kept per drive, older deleted

### Backup Restore
- [ ] Can list snapshots from connected drives
- [ ] Shows snapshot date and asset count
- [ ] Restore creates backup of current catalog first
- [ ] Restore copies snapshot over live catalog
- [ ] Relaunch after restore shows correct asset count

---

## 4A. Placement, adoption, and reclamation

The newest behaviour and the least exercised by hand. One of it deletes files,
so it gets walked deliberately rather than assumed from a green test run. Use a
throwaway archive (see Environment Setup) for all of it.

### A drive credited with what it already holds

- [ ] Import a folder that sits on a drive **before** registering that drive.
      Confirm the photos are staged on the Mac.
- [ ] Register the drive. Confirm a copy is queued for it.
- [ ] Let the connect sequence finish. **No file should ever appear under
      `HeykinnClicks/Replicas/` on that drive** — the copy is withdrawn, not
      written and then removed. Check the drive in Finder, not just the UI.
- [ ] The Sources screen marks that folder as holding the archive's copy.
- [ ] Rename the folder on the drive, reconnect: the copy is repaired, not
      re-copied.

### Cleaning up a duplicate that already exists

- [ ] Same setup, but let the sync run first so the app writes its own copy
      alongside your file.
- [ ] Use "Look for copies this drive already has" on the drive card.
- [ ] The catalog now points at **your** file; the app's duplicate is gone;
      **your original is untouched.** Verify all three in Finder.

### Releasing a staged copy

- [ ] With one target only, confirm nothing is released — one copy is not
      enough, whatever the disk pressure.
- [ ] With both targets holding a photo and each read back, confirm the staged
      copy goes and the Drives screen says so *before* it happens.
- [ ] Turn the setting off and confirm staging is kept, and that the screen
      still reports what it would free.
- [ ] Quit mid-release and relaunch: no photo loses its last copy, and staged
      files nothing references are swept up.

### Two drives that are never connected together

The case that deadlocks without the bridge.

- [ ] Import something, sync it to drive A only, then let the staged copy be
      released.
- [ ] With **only A** connected, confirm the app holds on the Mac what B is
      owed, and says so in the audit log.
- [ ] Unmount A, mount B. Confirm B receives the photo from the Mac with A
      absent the whole time.
- [ ] Confirm the held copy is then released, so the bridge does not become
      permanent storage.
- [ ] With the boot disk near full, confirm it bridges what fits and leaves the
      rest rather than filling the disk.

### An export arriving down the wrong path

- [ ] Choose an extracted Google export via "Choose a folder…". Confirm it is
      refused and the export route is offered instead.
- [ ] Confirm a renamed export is still recognised, by structure rather than name.
- [ ] Sweep a whole drive that has an export sitting on it. Confirm the export
      is stepped over, not exploded into individual copies.

### Sweeping again is cheap

- [ ] Re-import a large folder that has not changed. It should take seconds and
      report everything as already held.
- [ ] Modify one file in it and re-import: only that file is read again.

---

## 5. Error Handling & Recovery

### Insufficient Space
- [ ] Import to full Mac staging shows actionable error
- [ ] Replication to full drive shows error with space needed/available
- [ ] Error suggests freeing space or changing location

### Drive Disconnection
- [ ] Disconnecting drive during sync pauses gracefully (no crash)
- [ ] Reconnecting resumes from last completed file
- [ ] Drive offline during verification skips that drive, continues others

### File Access Errors
- [ ] Unreadable file during import logs error, continues with rest
- [ ] Bookmark stale (volume renamed) shows re-authorization prompt
- [ ] Permission denied handled gracefully, not crash

### Catalog Corruption
- [ ] Opening corrupt catalog shows recovery screen
- [ ] Can select snapshot from drive to restore
- [ ] Cannot proceed without valid catalog (prevents data loss)

### Crash Recovery
- [ ] Force quit during import: relaunch resumes from last checkpoint
- [ ] Force quit during sync: relaunch requeues interrupted tasks
- [ ] Force quit during extraction: startup deletes `.extracting` folders
- [ ] Orphaned staged files (no catalog entry) deleted on startup

---

## 6. User Experience

### Performance
- [ ] Library with 5,000+ assets scrolls smoothly (60fps)
- [ ] Thumbnail generation doesn't block UI
- [ ] Search returns results in <1 second (test: filename search)
- [ ] Protection state computation completes in <5s for 10K assets

### Keyboard Navigation
- [ ] Tab order makes sense on all screens
- [ ] Cmd+W closes window
- [ ] Cmd+, opens Preferences
- [ ] Cmd+Q quits app cleanly (no stuck processes)
- [ ] Escape dismisses modals/sheets

### Accessibility
- [ ] VoiceOver reads all interactive elements
- [ ] VoiceOver announces state changes (e.g., "Protection state changed to Fully Replicated")
- [ ] Can navigate entire app with keyboard only
- [ ] Color-blind safe (protection states distinguishable by icon, not just color)

### Visual Polish
- [ ] No placeholder/"Lorem ipsum" text
- [ ] Empty states have helpful prompts ("Import photos to get started")
- [ ] Loading states show spinners, not frozen UI
- [ ] Error alerts have "OK" button, not just red text
- [ ] Toolbar/navigation consistent across all screens

---

## 7. Edge Cases

### Live Photos
- [ ] Live Photo pair imports as one asset (not two)
- [ ] Hover plays motion in Library
- [ ] Both files replicate to drives
- [ ] Both files verified (not just still)
- [ ] Split Live Photo (still on one drive, motion on another) still plays

### Large Files
- [ ] 4K video (>1GB) imports successfully
- [ ] Progress shows bytes, not just "1 file"
- [ ] Replication handles large files without timeout
- [ ] Hash verification doesn't run out of memory

### Unicode & Special Characters
- [ ] Filenames with emoji import correctly
- [ ] Non-ASCII characters in volume names handled
- [ ] Paths with spaces work (no escaping errors)

### Time Travel
- [ ] Photos from 1970 (epoch) don't crash
- [ ] Photos from 2099 (far future) display correctly
- [ ] Missing capture date shows "Unknown date" (not blank or "Invalid")

### Duplicates
- [ ] Exact hash duplicates grouped correctly
- [ ] Can view duplicate groups
- [ ] Duplicate count accurate (not counting originals twice)

---

## 8. Migrations (If Implemented)

### State Machine
- [ ] Can create Local → AppleCloud migration
- [ ] Migration progresses: Pending → CopyingToTarget → VerifyingTarget → ClearingSource → Completed
- [ ] Can cancel migration before ClearingSource (reversible)
- [ ] Cannot cancel after ClearingSource started (destructive)

### Safety Checks
- [ ] Cannot start migration if source unreachable
- [ ] Cannot start migration if destination has insufficient space
- [ ] Cleanup requires explicit confirmation (destructive action)
- [ ] Cleanup only removes from source, never touches destination

---

## 9. Data Integrity

### Hash Verification
- [ ] Same file imported twice produces same hash
- [ ] Modified file detected (edit 1 byte mid-file)
- [ ] Truncated file detected (partial copy)
- [ ] Quick checksum samples head/tail/interior (test: modify between samples = undetected)
- [ ] Full hash catches corruption anywhere in file

### Audit Trail
- [ ] Every import logged with timestamp, file count, batch ID
- [ ] Every sync logged with target name, file count, duration
- [ ] Errors logged with full details
- [ ] Audit log persists across launches
- [ ] Can export audit log (via Diagnostics)

### Catalog Consistency
- [ ] `PRAGMA integrity_check` passes
- [ ] No orphaned replica states (every replica has an asset)
- [ ] No orphaned tasks (every task references existing asset + target)
- [ ] Foreign key constraints enforced (if using)

---

## 10. Uninstall & Cleanup

### Graceful Uninstall
- [ ] Quitting app releases all drive access
- [ ] Deleting app from `/Applications` succeeds
- [ ] App leaves behind only:
  - `~/Library/Application Support/HeykinnClicks/` (catalog + staging)
  - Drive folders: `HeykinnClicks/` replicas, `HeykinnClicksCatalogBackups/`
  - Drive marker files: `.heykinn-clicks-target-<UUID>`
- [ ] No zombie processes after quit
- [ ] No kernel extensions or LaunchDaemons

### Re-install
- [ ] Re-installing app over existing data works (catalog migrates if needed)
- [ ] Deleting catalog + relaunching shows welcome screen again
- [ ] Old replicas on drives can be re-associated (not orphaned)

---

## 11. Release Artifacts

### Distribution Package
- [ ] `.dmg` opens with drag-to-Applications visual
- [ ] `.pkg` installer (if using) completes without errors
- [ ] Sparkle appcast XML valid (if using auto-update)
- [ ] Code signed with valid Developer ID
- [ ] Notarized by Apple (check via `spctl -a -v /Applications/HeykinnClicks.app`)

### Documentation
- [ ] README.md accurate for current version
- [ ] User guide exists (in-app Help or website)
- [ ] License file included (if applicable)
- [ ] Privacy policy (if collecting any data)
- [ ] Known issues documented (if any)

---

## Automated test coverage

Everything below runs first. Manual testing is for what a test cannot see —
whether a screen is comprehensible, whether a prompt appears, whether an
operation feels finished when it says it is.

```bash
# The whole suite: 392 tests across 47 classes, ~12s.
swift test

# The ones that speak to a particular worry.
swift test --filter AdoptionTests            # a target credited with what it already holds
swift test --filter StagingReclaim           # releasing a copy, and the two-drive bridge
swift test --filter ImportParityTests        # both import paths, and the sweep memo
swift test --filter DurabilityTests          # interrupted runs
swift test --filter SourceUnavailableTests   # a drive that is not there
swift test --filter ProtectionVerdictTests   # what "safe" is allowed to mean

# DMG-backed drive identity — skipped without the flag, so a green run
# without it does NOT mean these passed.
HEYKINN_DMG_TESTS=1 swift test --filter DriveIdentity
```

There is no UI test target and no `xcodebuild` scheme; the package is opened
directly in Xcode. Section 6 below is how the UI gets checked.

### Coverage goals
- [ ] Every invariant in `docs/SPEC.md` has a test that fails if it regresses
- [ ] Every lesson recorded in SPEC has a regression test — that is what makes
      it a lesson rather than an anecdote
- [ ] Critical paths (import, adoption, replication, reclamation) covered for
      the failure case, not only the happy one
- [ ] No test asserts on a message string where it could assert on state

---

## Performance Benchmarks

Run against test archive with 25,000 assets:

- [ ] Cold launch: <2 seconds
- [ ] Library initial load: <3 seconds
- [ ] Protection state computation (all assets): <10 seconds
- [ ] Search (simple filename): <500ms
- [ ] Thumbnail generation: <100ms per image (cached)
- [ ] Import 100 photos: <30 seconds (excluding hash time)
- [ ] Full hash of 1GB file: <10 seconds on SSD

---

## Sign-Off

**Tested by:** _______________  
**Date:** _______________  
**macOS Version:** _______________  
**Build Version:** _______________  

**Blockers Found:** ___ (must be 0 to ship)  
**Known Issues:** ___ (documented, acceptable for this release)  

**Approved for Release:** ☐ YES  ☐ NO  

---

## Post-Release Monitoring

After shipping:

- [ ] Monitor crash reports (if integrated)
- [ ] Check user feedback channels (email, reviews, issues)
- [ ] Track adoption metrics (if applicable)
- [ ] Plan hotfix release within 1 week if critical bugs found
