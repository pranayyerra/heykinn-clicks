# Production readiness

What is genuinely left before somebody other than the author runs this, ranked
by what it costs to get wrong.

Everything below was checked against the code on 2026-08-05, not inferred from
the README. Where an earlier draft of this document was wrong, the correction is
recorded at the bottom rather than quietly dropped — a checklist that invents
work is worse than no checklist, because the invented work crowds out the real
work.

**State of play:** 392 tests across 47 classes, all passing. Author's archive:
24,627 assets, 98.2 GB logical, across two external drives. No dependencies
outside the standard library and system frameworks.

---

## Blockers

Nobody else can run this until these are done.

### App bundle — **done, needs finishing touches**

`Packaging/bundle.sh` assembles, signs and verifies `HeykinnClicks.app`. See
`Packaging/README.md` for why the app is deliberately unsandboxed and what that
costs (no Mac App Store; Developer ID and notarisation instead).

- [x] Bundle with a real `CFBundleIdentifier` and `Info.plist`
- [x] `NSPhotoLibraryUsageDescription` — without it the first PhotoKit call
      terminates the process instead of prompting
- [x] `NSRemovableVolumesUsageDescription` for macOS 13+
- [x] Hardened runtime, no exceptions needed
- [ ] App icon — drop `Packaging/AppIcon.icns` in and the script picks it up
- [ ] Developer ID signature, notarisation, stapling
- [ ] **Verify the Photos prompt actually appears standalone.** Access works
      today because Xcode is the responsible process and already holds the
      grant. The bundle exists to give the app its own identity; that it works
      is an assumption until somebody launches it from `/Applications` and sees
      the prompt.

### Import can fill the boot disk

`runFolderImport` stages every file from an unmanaged source with **no
free-space check at all**. Registering a host-device target refuses when the
archive plus a 20 GB reserve will not fit ([AppStore.swift:2884]); importing
400 GB from a borrowed drive has no equivalent guard and will simply fill the
disk until writes start failing.

The parts are already there — `TakeoutExtractor.availableCapacity(onVolumeOf:)`
and `ExportPartTransferPlanner.holdingAreaReserveBytes`. This is the same check,
applied one level earlier, plus a way to say "this folder needs more room than
you have" before the sweep starts rather than in the middle of it.

### No route back from a bad catalog

`CatalogBackupService` writes snapshots to the drives. Nothing reads them: there
is no `restoreCatalog` anywhere in the app. Recovery today means quitting,
finding a snapshot by hand, and copying it over `catalog.sqlite`.

- [ ] List snapshots found on connected targets, with date and asset count
- [ ] Restore with the current catalog backed up first, and verify the restored
      file opens and its counts are sane before switching to it

---

## Real gaps, ranked

Not blockers, but each has a consequence somebody will hit.

**1. Ingest through a target when both slots are full.** Importing from an
unmanaged drive offers to register it *if a slot is free*; with two targets
already registered it silently stages instead. The better answer — copy into a
registered target as a real folder and adopt in place — is not built. Same
number of writes, but the bytes land somewhere that counts toward the policy.

**2. The Takeout importer does not adopt.** `TakeoutImporter` still dedupes
against a `Set<String>` and records nothing about where a duplicate was found
([TakeoutImporter.swift:115]). Folder imports learned to credit a target with
content it already holds; this path did not, and relies on `TakeoutReconciler`
instead. Two mechanisms where one would do.

**3. Two-target ceiling is UI-only.** `DriveConnectPrompt` gates registration on
`targets.count < 2`, but `registerVolumeTarget` enforces no such cap and the
redundancy policy is clamped to however many targets exist. Either make the
ceiling real or let people register a third device.

**4. ~~No Help menu.~~ Done.** `AppCommands.swift` declares the app's menus:
File gets Add Photos (⌘I), Search for Google Downloads (⇧⌘I), Back Up the
Catalog (⌘S) and Save a Diagnostics Report (⇧⌘D); View gets ⌘1–⌘4 for the four
sidebar questions and ⌘R for a drive rescan; Help (⌘?) opens `HelpView`, which
explains the five ideas the screens assume you have met — a target is a device,
residency is one place, "safe" means enough copies exist, sources are only read,
nothing is fixed behind your back.

**5. ~~No diagnostics export.~~ Done.** `DiagnosticsReport.swift` builds the
report from catalog state and `AppCommands` writes it through a save panel. It
is redacted rather than trimmed: every registered target becomes "Target A" /
"Target B" wherever its name appears in the log, absolute paths become `‹path›`,
and anything carrying a media extension becomes `‹file›`. Worth spot-checking the
redaction against a real log before telling anyone to send one.

**6. Errors are strings on `lastError`.** Every failure becomes one line in an
alert — now titled "That didn't finish" rather than "Something went wrong", and
with a Copy the details button, because several of these messages are whole
explanations somebody will want to paste. The underlying gap stands: some are
already good ("Not registering X: holding a copy here needs 98 GB…"); others
surface a raw `localizedDescription`. Worth an audit of
throw sites for messages that say what to do, not just what failed.

**7. `._` files on exFAT.** Cosmetic. exFAT has no native extended attributes,
so macOS writes an AppleDouble sidecar beside every replica. Harmless — the
app's sweeps skip dotfiles — but it doubles the file count a user sees in
Finder and is worth a sentence in the docs.

---

## Already done — do not re-add these

An earlier draft listed these as work. They exist.

| Claimed missing | Reality |
|---|---|
| Search and filtering | `LibraryView` has search text, residency filter and holding filter |
| Lazy loading in the Library grid | `LazyVStack` + `LazyVGrid` with pinned section headers |
| Activity log persistence | `audit_events` is a SQLite table, not in-memory |
| Cancelable long operations | Sync cancels and resumes; export-part transfers too |
| Progress indication | `SyncProgress`, `TakeoutActivity` |
| Import interruption and resume | `reconcileAfterRestart`, covered by `DurabilityTests` |
| Drive disconnect during sync | Transient failures stay queued, covered by `SourceUnavailableTests` |
| Protection state at scale | `ScalePerformanceTests` proves it is linear, not quadratic |

---

## Deliberately not doing

Recorded so they stop coming back as omissions.

- **Sandboxing / Mac App Store.** The app manages volumes the user registers and
  identifies them by a marker file at the volume root. See `Packaging/README.md`.
- **Security-scoped bookmarks.** Would be a second identity mechanism competing
  with the marker token and volume UUID, which already survive a rename, a
  remount and a different mount path. Bookmarks are what you reach for when you
  do not have that.
- **Perceptual duplicates, faces, semantic search, map view.** Out of scope for
  a tool whose job is "two copies, verified".

---

## Ship gates

**Private beta** — blockers cleared; the free-space guard in; the app launched
from `/Applications` on a Mac that has never had Xcode on it, with the Photos
prompt observed.

**Public beta** — catalog restore in the app; ~~diagnostics export; a Help
menu~~ (both in); `TESTING_CHECKLIST.md` walked end to end on a real archive,
including the menu bar and the first-run screen on an empty catalog
(`HEYKINN_ARCHIVE_DIRECTORY=/tmp/empty swift run`).

**1.0** — gaps 1–3 closed, or consciously accepted and documented for users.

---

## Corrections to earlier drafts

Kept so the same mistakes do not return.

- **"Storage & Health" is now "Drives."** The sidebar question is already called
  Safety; a tab inside it called Storage & Health gave the same place two names,
  one of them an ampersand-joined double noun. Every reference in the app and in
  the docs moved with it — search for the old name before writing it again.
- **Violations and Migrations are not destinations.** They stopped being pages
  when the sidebar became four questions, but Overview's attention tiles still
  navigated to them, which selected a section no sidebar row could highlight and
  left no way back. The tiles go to Drives, where both render as sections.

- **"At least 2 external drives required."** Wrong, and it had reached the
  onboarding copy. A target is a *device*: either the Mac running the app
  (holding its copy in a folder you choose) or an external drive. Mac plus one
  drive is a perfectly ordinary setup. `TargetKind`'s own comment says it — "a
  target *is* a device".
- **"248 GB / 24,626 photos."** 98.2 GB logical, 24,627 assets.
- **"Core engine tests + one DMG integration test."** 392 tests, 47 classes.
- **"Choose staging location on Mac (default ~/Pictures/HeykinnClicks)."**
  Staging is `Application Support/HeykinnClicks/Staging` and is not
  user-choosable. It is transit, not a library — content is released from it
  once the policy is satisfied.
- **Sandbox entitlements alongside `app-sandbox = false`.** Inert. They are
  sandbox exceptions and there is no sandbox to except from.
- **`allow-dyld-environment-variables`.** Not needed;
  `HEYKINN_ARCHIVE_DIRECTORY` is read through `ProcessInfo`. It would weaken the
  hardened runtime for nothing.
