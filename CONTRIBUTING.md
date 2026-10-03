# Contributing

## Setup

No dependencies outside the standard library and system frameworks — a clone
and `swift build` is the whole setup. Xcode is not required.

```bash
swift build        # compile
swift test         # core-engine tests
swift run          # launch the app (SwiftPM executable; window activates itself)
```

Work against a throwaway archive rather than your own photo library:

```bash
HEYKINN_ARCHIVE_DIRECTORY=/tmp/scratch-archive swift run
```

**Photos access needs a real app bundle.** `swift run` and Xcode's own Run
button produce a bare binary with no bundle identifier, so macOS has nothing
to hang a Photos permission on — see the README section ["Signing, and what an
unsigned build cannot do"](README.md#signing-and-what-an-unsigned-build-cannot-do).
To test the Photos connector:

```bash
./Packaging/bundle.sh
open build/HeykinnClicks.app
```

## Read first

- [`docs/SPEC.md`](docs/SPEC.md) — the invariants that must never regress.
  Read this before changing anything in `Domain/` or `Services/`.
- [`docs/ARCHITECTURE-DECISIONS.md`](docs/ARCHITECTURE-DECISIONS.md) — why
  things are built the way they are, so you don't re-propose something already
  tried and rejected.
- [`docs/KNOWN-GAPS.md`](docs/KNOWN-GAPS.md) — what's deliberately unfinished
  and why, so you don't "fix" something that's an open decision instead of a
  bug.
- The [`Architecture`](README.md#architecture) section of the README for where
  things live.

## Running the opt-in test suites

Most of the test suite runs under plain `swift test`. A few suites are gated
behind environment variables because they need real hardware, take a long
time, or touch a real archive:

| Variable | Unlocks |
|---|---|
| `HEYKINN_DMG_TESTS=1` | Real-volume integration test: creates and mounts a temporary DMG, verifies marker-based drive identity including an unplug/replug cycle. Run with `swift test --filter DriveIdentity`. |
| `HEYKINN_VOLUME_TESTS=1` | Tests that inspect this machine's actually-mounted volumes. Only run this on a machine whose mounted volumes are safe to inspect. |
| `HEYKINN_BENCH=1` / `HEYKINN_BENCH_DIR=<path>` / `HEYKINN_BENCH_FILES=<n>` | Performance benchmarks (zip extraction cost, checkpoint cost, sidecar lookup speed) that are too slow or too hardware-dependent to run on every `swift test`. |
| `HEYKINN_LIVE_CATALOG=<path to a copy of a real catalog.sqlite>` | Schema-migration check against real data shape. Point it at a **copy**, never your live catalog — nothing in the test writes to it, but don't take the risk. |

None of these run in CI. They exist for whoever is debugging the area they
cover.

## Opening a PR

- CI must pass (`swift build && swift test`).
- A behavior change needs a test. The existing suites are the pattern to
  follow — most test one documented invariant or one fixed bug, by name.
- Don't edit [`docs/releases/README.md`](docs/releases/README.md) in a feature
  PR — that file is written only at release time and describes what actually
  shipped, not what's in flight.
- Keep changes scoped to what the PR is about. This codebase's docs (`SPEC.md`
  in particular) exist precisely so a PR doesn't have to re-derive or restate
  design decisions — link to the relevant section instead of repeating it.

## Sign off your commits (DCO)

Every commit must carry a `Signed-off-by` line, certifying you wrote it or
otherwise have the right to submit it under this project's license (the
[Developer Certificate of Origin](https://developercertificate.org/)):

```bash
git commit -s -m "Your commit message"
```

By contributing, you agree your contribution is licensed under
GPL-3.0-or-later plus the app-store permission in
[LICENSE-APPSTORE-EXCEPTION.md](LICENSE-APPSTORE-EXCEPTION.md), the same terms
as the rest of the project.

## If you fork this

The Apple team ID `344B87D3CV` is baked into the app group identifier, which
appears in four places that must all agree:

- `Sources/HeykinnClicks/App/ArchiveLocation.swift` (`appGroupIdentifier`)
- `Packaging/HeykinnClicks.entitlements`
- `Packaging/HeykinnClicks-AppStore.entitlements`
- `Tests/HeykinnClicksTests/ArchiveLocationTests.swift` (asserts the prefix)

Change all four together — `EntitlementTests` and `ArchiveLocationTests` fail
if they disagree, which is what those tests are for. You'll also need your own
Apple Developer Program membership and certificates; see
[`Packaging/README.md`](Packaging/README.md).
