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

## Blockers — all cleared before 1.0

Three, and each is worth one line because the fix is in the code and the
reasoning is in the commit that made it.

- **The app bundle.** `swift run` produces a bare binary with no bundle
  identity, so privacy grants attach to whatever launched it. `Packaging/bundle.sh`
  is the fix, and it reports which entitlements the signed binary actually
  carries — the Photos grant was silently refused for months because one was
  missing.
- **An import could fill the boot disk.** Staging now refuses when a batch
  would eat into the reserve, and says what it needs against what there is.
- **No route back from a bad catalog.** Verified snapshots ride along on every
  connected drive, and Settings → Safety → Restore installs one, keeping the
  replaced catalog beside it.

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
