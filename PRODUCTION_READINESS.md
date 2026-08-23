# Production readiness

What is genuinely left before somebody other than the author runs this, ranked
by what it costs to get wrong.

Everything below was checked against the code on 2026-08-14, not inferred from
the README. Where an earlier draft of this document was wrong, the correction is
recorded at the bottom rather than quietly dropped — a checklist that invents
work is worse than no checklist, because the invented work crowds out the real
work.

**State of play:** the suite passes; the tests that need hardware or a benchmark
flag skip themselves and say so. Run against the author's own archive — a little
under 25,000 assets and about 100 GB across two external drives, as it stood in
August 2026, which is a measurement of one archive on one day and not a claim
about the app. No linked dependencies outside the standard library and
system frameworks. The App Store package has uploaded; the current review is
waiting for the seven-part reviewer information package and physical-device
recording in `docs/releases/app-review-guideline-2.1.md`, not for a code change.

---

## Blockers

Nobody else can run this until these are done. **All three are now done**, and
the last of them was only ever an assumption until somebody watched it fail.

### ~~App bundle.~~ Done, and verified somewhere it had never run

`Packaging/bundle.sh` assembles, signs and verifies `HeykinnClicks.app`. See
`Packaging/README.md` for why the app is deliberately unsandboxed and what that
costs (Developer ID and notarisation for the website build, a second sandboxed
build for the App Store).

The last line was the one that mattered, and it is the one that failed.

- [x] Bundle with a real `CFBundleIdentifier` and `Info.plist`
- [x] `NSPhotoLibraryUsageDescription` — without it the first PhotoKit call
      terminates the process instead of prompting
- [x] `NSRemovableVolumesUsageDescription` for macOS 13+
- [x] Hardened runtime, no exceptions needed
- [x] App icon — the Hey Kinn otter, white on the brand gradient, built from
      `Packaging/BrandMark.png` by `Packaging/make-icon.swift`. A generator
      rather than a checked-in binary, so the sizing is a number somebody can
      change and re-run. The mark exists only as raster (228×275 inside the
      800×800 lock-up), so 512 and 1024 upscale about 2.2× — fine for a flat
      shape, but **a vector from the designer would be sharper** and is the one
      improvement worth asking for.
- [x] Developer ID signature, notarisation, stapling. Submission
      `7780fe4c-9bab-4f84-91b9-3863ef284f18` came back `Accepted`, the ticket is
      stapled, and a quarantined copy unzipped elsewhere reports
      `accepted, source=Notarized Developer ID`. Sequence in
      `Packaging/README.md`.

      Two things had to be fixed to get there, both of which fail in ways worth
      remembering. `bundle.sh` signed with `--timestamp=none`: fine locally,
      and an automatic rejection from the notary service, which requires a
      secure timestamp. It now asks for one unless the signature is ad-hoc,
      where a network round trip in every local build would buy nothing. And
      the archive that gets uploaded is the *un-stapled* one — the ticket is
      attached afterwards — so the build to hand round has to be re-zipped after
      stapling, or every recipient gets a copy that must reach Apple to open.
- [x] **Verify the Photos prompt actually appears standalone.** Done, on a
      fresh macOS user account with no history of this app: the prompt appears
      and access is granted. It was an assumption for the app's whole life and
      it turned out to be a wrong one — see below.

      It failed the first three times, and none of the reasons were the obvious
      ones. The app was refused the Photos library **silently**: no prompt, and
      no entry under Privacy & Security → Photos, which from inside the app is
      indistinguishable from somebody having declined. The cause was a single
      missing entitlement,
      `com.apple.security.personal-information.photos-library`, absent from the
      Developer ID file and present in the App Store one.

      That key reads as a sandbox entitlement and is not only one: the
      `personal-information.*` keys are **Hardened Runtime** resource-access
      entitlements too, and this app runs hardened because notarisation
      requires it. Nothing about an unsandboxed app suggests it needs
      permission to be permitted.

      It hid behind the development loop for months. `swift run` produces a bare
      binary with no hardened runtime and Xcode holds the grant, so connecting
      Photos always worked at the author's desk — seven times over two days, in
      the audit log. Only the bundled, signed, notarised build was refused,
      which is the only build anybody else runs. This document warned about that
      exact gap from the day it was written; it still took a clean account to
      walk into it.

      Guards, since the mistake was in a file nothing read: `bundle.sh` prints
      what each signature actually carries and says so loudly when Photos is
      missing, and `EntitlementTests` reads both entitlement files as source.

### ~~Import can fill the boot disk.~~ Done

`runFolderImport` refuses before it copies anything when the sweep would eat
into the Mac's reserve, and says how much it needs against how much there is —
`AppStore.stagingSpaceRefusal`, over `ImportService.stagingBytesNeeded`.

The estimate is not the folder's size. A file the archive already holds is
recognised by its `stat` against the scan memo and never copied, so a re-sweep
of an imported folder — the cheapest import there is, and an ordinary thing to
do — is not refused for needing room it does not need. Everything else is
counted in full, including a remembered file that has changed since: the guard
errs high, because over-reserving costs a message somebody can ignore and
under-reserving fills the disk. If the volume will not report its capacity the
import proceeds; this is a guard rail, not an accounting system.

### ~~No route back from a bad catalog.~~ Done

`AppStore.restoreCatalog(from:)` is the read half, reachable from Settings →
Safety → Restore. Snapshots on every connected drive are listed with their date,
asset count and how many kinds of record they hold — the count being the figure
that matters, since a snapshot holding a fraction of the assets the
archive has is what a catalog going wrong looks like from outside.

- [x] List snapshots found on connected targets, with date and asset count
- [x] Restore with the current catalog kept first, and verify the restored file
      opens and its counts are sane before switching to it

Three things worth knowing about how it behaves:

- **The outgoing catalog is kept, never deleted** — moved aside as
  `catalog-replaced-<stamp>.sqlite`, so there is a way back from the way back.
  The write-ahead log is checkpointed into it first; without that the kept copy
  would be missing the most recent work, which is exactly what somebody would be
  trying to recover.
- **Unreadable snapshots are not offered.** A file that will not open, fails its
  integrity check, or holds no assets is dropped from the list rather than shown
  and disabled. Restoring an empty catalog would drop every record of photos
  still sitting on the drives.
- **Refused while work is in flight.** A sync, an import or an extraction is
  writing rows into the catalog about to be replaced.

---

## Real gaps, ranked

Not blockers, but each has a consequence somebody will hit.

**1. ~~Ingest through an unmanaged drive only while a slot is free.~~ Done.**
There is no registration cap. A folder chosen on an unmanaged drive always
offers to register that drive first, which credits the files where they already
sit instead of staging a duplicate on the Mac.

**2. The Takeout importer does not adopt.** `TakeoutImporter` still dedupes
against a `Set<String>` and records nothing about where a duplicate was found
([TakeoutImporter.swift:115]). Folder imports learned to credit a target with
content it already holds; this path did not, and relies on `TakeoutReconciler`
instead. Two mechanisms where one would do.

**3. ~~Two-target ceiling is UI-only.~~ Done.** Registration is unbounded in
both `DriveConnectPrompt` and `registerVolumeTarget`. Copy count is a per-source
policy and no longer doubles as a cap on how many devices can be known.

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

**6b. A drive already belonging to another archive is claimed silently.**
Registering writes a marker file at the volume root and overwrites whatever is
there, so the second archive to register a drive takes it and the first can no
longer identify it by the primary mechanism. Two archives on one Mac stopped
being exotic when the app started offering a test archive beside the real one.
Found by doing it — see invariant 13 in `docs/SPEC.md`. Nothing is moved or
lost, because the volume UUID is a fallback and it holds, but an archive
quietly demoted to its backup identity for a drive that is plugged in is not
something it should keep to itself. The fix belongs in registration, beside the
read-only refusal: read the marker first, and ask when it names somebody else.

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

- **One permission model for both distribution routes.** The Developer ID build
  remains unsandboxed so it can discover unknown mounted volumes. The Mac App
  Store build is sandboxed and reaches user-selected folders/drives through
  app-scoped security-scoped bookmarks. Both still verify a drive's marker
  before trusting it. See `Packaging/README.md`.
- **Perceptual duplicates, faces, semantic search, map view.** Out of scope for
  a tool whose job is "two copies, verified".

---

## Ship gates

**Private beta** — ~~blockers cleared; the free-space guard in; the app launched
from `/Applications` with the Photos prompt observed on a machine that had never
run it~~. **All in.** The prompt was watched appearing on a fresh account, which
is what turned a months-old assumption into a fixed bug.

**Public beta** — ~~catalog restore in the app; diagnostics export; a Help
menu~~ (all three in); `TESTING_CHECKLIST.md` walked end to end on a real
archive, including the menu bar and the first-run screen on an empty catalog
(`HEYKINN_ARCHIVE_DIRECTORY=/tmp/empty swift run`). Restore wants a pass of its
own on that walk: it is verified against snapshots this app wrote in tests, and
has never been run against a snapshot sitting on a real drive that was
unplugged half way through.

**1.0** — gaps 2 and 6b closed, or consciously accepted and documented for
users; the former unmanaged-ingest and device-count gaps are closed.

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
- **"248 GB / 24,626 photos."** Two different measurements used as one. 248 GB
  is the size of the downloaded Google export — twelve zips — and the archive
  built from it is smaller. Whichever number appears, say which of the two it
  is; they are not interchangeable and the copy treated them as though they
  were.
- **"Core engine tests + one DMG integration test."** The suite passes in the
  ordinary run, with the environment-dependent tests skipped unless their
  prerequisites are enabled.
- **"Choose staging location on Mac (default ~/Pictures/HeykinnClicks)."**
  Staging is the `Staging` folder inside the resolved archive directory
  (normally the shared app-group container) and is not user-choosable. It is
  transit, not a library — content is released from it once the policy is
  satisfied.
- **Sandbox entitlements alongside `app-sandbox = false`.** Inert. They are
  sandbox exceptions and there is no sandbox to except from.
- **`allow-dyld-environment-variables`.** Not needed;
  `HEYKINN_ARCHIVE_DIRECTORY` is read through `ProcessInfo`. It would weaken the
  hardened runtime for nothing.
