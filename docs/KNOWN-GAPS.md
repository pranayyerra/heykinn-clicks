# Known gaps

What is wrong with the app that nobody has fixed yet, what will not be built,
and what an earlier draft claimed was missing when it already existed.

**This was `PRODUCTION_READINESS.md`, a checklist of what stood between the app
and its first user.** That question is answered — 1.0, 1.1 and 1.2 have shipped
through the App Store — and the file went on describing a review that finished,
blockers that cleared, and a screen called "Drives" that no longer exists. What
survives is the half that is not about a milestone.

Each gap below was checked against the code on **24 August 2026**. What shipped
and when is in [`releases/`](releases/README.md).

---

## Open

**The Takeout importer does not adopt.** It dedupes against a set of hashes and
records nothing about *where* a duplicate was found, so a drive already holding
an export is credited by `TakeoutReconciler` afterwards rather than by the
import itself. Folder imports learned this; this path did not. Two mechanisms
where one would do, and the second only runs on connect.

**Errors are strings on `lastError`.** Every failure becomes one line in an
alert. Some are whole explanations — *"Not registering X: holding a copy here
needs 98 GB…"* — and some surface a raw `localizedDescription`, which says what
failed and not what to do. Worth an audit of the throw sites rather than the
alert.

**`._` files on exFAT.** Cosmetic. exFAT has no extended attributes, so macOS
writes an AppleDouble sidecar beside every replica. The app's sweeps skip
dotfiles, but it doubles the file count somebody sees in Finder.

**A physical drive pulled mid-write.** A forced detach is covered, on exFAT,
with the volume checked sound afterwards — see [`TESTING-SYNC.md`](TESTING-SYNC.md).
What no disk image reproduces is power lost to a drive's controller mid-flush,
where its own write cache may hold bytes that never reach the flash. Needs a
USB stick somebody is willing to lose.

---

## Deliberately not doing

Recorded so they stop coming back as omissions.

- **One permission model for both distribution routes.** The Developer ID build
  stays unsandboxed so it can discover unknown mounted volumes; the App Store
  build is sandboxed and reaches user-selected drives through app-scoped
  bookmarks. Both verify a drive's marker before trusting it.
  See [`../Packaging/README.md`](../Packaging/README.md).
- **Perceptual duplicates, faces, semantic search, map view.** Out of scope for
  a tool whose job is "two copies, verified".

---

## Already done — do not re-add these

An earlier draft listed these as work. They exist.

| Claimed missing | Reality |
|---|---|
| Search and filtering | `LibraryView` has search text and filters |
| Lazy loading in the Library grid | `LazyVStack` + `LazyVGrid` with pinned headers |
| Activity log persistence | `audit_events` is a SQLite table, not in-memory |
| Cancelable long operations | Sync cancels and resumes; export-part transfers too |
| Progress indication | `SyncProgress`, `TakeoutActivity` |
| Import interruption and resume | `reconcileAfterRestart`, `DurabilityTests` |
| Drive disconnect during sync | Transient failures stay queued, `SourceUnavailableTests` |
| Protection state at scale | `ScalePerformanceTests` proves it linear, not quadratic |
| A drive belonging to another archive claimed silently | `DriveMarkerConflict` — invariant 13 |
| Help menu, diagnostics export, catalog restore | `AppCommands`, `DiagnosticsReport`, Settings → Safety |

---

## Corrections kept so they do not return

- **"At least 2 external drives required"** reached the onboarding copy and was
  wrong. A target is a *device*: this Mac, or an external drive. Mac plus one
  drive is an ordinary setup.
- **"248 GB / 24,626 photos"** used two different measurements as one. 248 GB is
  the downloaded Google export — twelve zips — and the archive built from it is
  smaller. Say which of the two a number is.
- **Staging is not user-choosable.** It is the `Staging` folder inside the
  resolved archive directory: transit, not a library.
- **Sandbox entitlements alongside `app-sandbox = false` are inert**, and
  `allow-dyld-environment-variables` is not needed — `HEYKINN_ARCHIVE_DIRECTORY`
  is read through `ProcessInfo`, and the entitlement would weaken the hardened
  runtime for nothing.
