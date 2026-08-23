# Packaging

`bundle.sh` assembles `HeykinnClicks.app` around the SwiftPM executable.

```bash
./Packaging/bundle.sh                    # debug, ad-hoc signed, runs on this Mac
./Packaging/bundle.sh --release
./Packaging/bundle.sh --release --sign "Developer ID Application: Name (TEAMID)"
./Packaging/bundle.sh --release --appstore --sign "Apple Distribution: Name (TEAMID)" --build-number 153
```

Privacy-safe App Review media is generated locally—no real Photos library and
no downloaded or third-party images are involved:

```bash
swift Packaging/make-review-fixtures.swift /tmp/Heykinn-Review-Fixtures
```

The result contains an ordinary 12-image folder and a four-image extracted
Google Takeout-shaped tree with synthetic sidecars.

The icon is generated, not checked in as an opaque binary:

```bash
swift Packaging/make-icon.swift          # BrandMark.png -> AppIcon.icns
```

`make-dmg.sh` wraps whatever is in `build/` in a disk image to hand somebody:

```bash
./Packaging/make-dmg.sh --sign "Developer ID Application: Name (TEAMID)" --notarize heykinn
```

A zip unpacks wherever it was downloaded, so the app ends up being run out of
Downloads, and every macOS release makes that a worse place to run something
from. The image opens onto a window holding the app beside a link to
Applications, which is the one gesture everybody already knows.

The image is signed and notarised **in its own right**. A notarised app inside
an un-notarised image still warns on first open, because Gatekeeper judges the
thing that was downloaded, and the thing that was downloaded is the `.dmg`.

## Two shipped builds, one codebase

| | Developer ID (website) | App Store |
|---|---|---|
| Entitlements | `HeykinnClicks.entitlements` | `HeykinnClicks-AppStore.entitlements` |
| Sandbox | off | **on, not optional** |
| Build | `bundle.sh --release --sign "Developer ID Application: …"` | `bundle.sh --release --appstore --sign "Apple Distribution: …"` |
| Finds an unknown drive on mount | yes | no — the user picks it |
| Reaches a known drive again | marker sweep, bookmark as backup | bookmark only |

The difference is not packaging. A sandboxed app may not read the root of a
volume nobody handed it, and reading the marker file at every mounted volume's
root is how this app knows which drives are which. So the App Store build cannot
notice a drive appearing; a device is registered by choosing it, and reached
again through a security-scoped bookmark taken at that moment
(`Services/TargetBookmarks.swift`).

The same timing issue exists for a selected Google Takeout root in a less
obvious form: discovery and import are separate actions. The App Store build
therefore converts the file-panel grant into a per-machine source bookmark
before discovery starts and resumes it at launch
(`Services/SourceBookmarks.swift`). A catalog path alone is not sandbox
permission.

Both builds take the bookmark, and both check the marker before trusting what it
resolves to — a bookmark is permission to look, and it can resolve onto a disk
that has since been reformatted or replaced. One mechanism would have been
simpler; two are needed because they answer different questions, and conflating
them is how an archive writes its replicas onto a stranger's volume.

### One archive, both builds

A sandboxed app gets a container of its own, so left alone the two builds would
each keep an archive on the same Mac — two catalogs describing overlapping
halves of the same photographs, with every screen quietly reporting the wrong
total. Both therefore declare an **app group**, which is the one place a
sandboxed and an unsandboxed app can both reach, and the archive lives there:

```
~/Library/Group Containers/344B87D3CV.com.heykinn.HeykinnClicks/HeykinnClicks
```

`App/ArchiveLocation.swift` decides, in this order: an explicit
`HEYKINN_ARCHIVE_DIRECTORY`; the group container when the process is entitled to
ask; the group container **by path** when it exists but this process cannot ask
— which is what stops `swift run` starting a second archive after a signed build
has moved the first one; and otherwise the pre-group location. An existing
archive is moved into the shared container once, by rename. If both places hold
one, the app says so and changes neither.

### Upgrading into the sandbox loses the drives, once

A bookmark is taken when a device is registered, so every device registered
before bookmarks existed has none. That costs the Developer ID build nothing —
the marker sweep finds drives regardless. For the App Store build it is total:
reading the root of every mounted volume is exactly what the sandbox forbids, so
a drive with no bookmark is invisible rather than slow, and somebody upgrading
would find every one of their drives reading as *away* while plugged in.

So Keep safe leads with **Show the app where these are** and asks for each one
once. The marker still decides — a folder that is not that device is refused,
and so is a different device the archive happens to know, because a bookmark
recorded against the wrong disk would have the archive writing copies onto a
stranger's drive and counting them.

Worth remembering when the App Store build is first handed to an existing user:
their drives are not lost, they are unintroduced.

### Testing both routes at once, without touching your own archive

Sharing one archive is right for somebody who owns one. It is the wrong thing
for whoever is publishing both, who will have the App Store build and the
website build installed at the same time and pointed at the same catalog.

Two copies of the app in one archive do not corrupt the database — SQLite
handles concurrent access. They corrupt the *archive*, which is worse, because
it stays perfectly readable: every screen is drawn from state loaded into memory
at launch and written back as whole rows, so the second instance to write wins
without ever having seen the first's changes, and the catalog carries on
describing an archive that no longer matches the disks.

So the app refuses. The first one in takes an advisory lock on the archive
directory (`App/ArchiveLock.swift`) and the second shows "this archive is
already open" instead of the app. The kernel releases the lock when a process
dies, however it dies, so there is no stale lock to clear after a crash.

To run both **at the same time**, that screen offers *Open a test archive
instead*. It starts that copy on an empty archive of its own and restarts into
it; an orange bar across the top says which one you are looking at, with a
button back. The choice is a preference and is per copy, so the App Store build
can sit in test mode while the website build stays on the real archive.

The test archive lives beside the real one and never inside it — nested, it
would be swept, counted and backed up as though it were content. Sandboxed, it
goes inside that build's own container, which is the only place it may write.

There is still an environment variable, and it beats everything including test
mode, so a suite pointed at its own directory is never diverted by a preference
left on from somewhere else:

```bash
HEYKINN_ARCHIVE_DIRECTORY=/tmp/scratch swift run
```

It cannot redirect a sandboxed build, though — a path outside the container is
one thing the sandbox will not allow — which is why the button exists.

**Provisioning profiles** are picked up automatically. Download one from
developer.apple.com carrying `344B87D3CV.com.heykinn.HeykinnClicks` and drop it
into `Packaging/`:

| File | Used by |
|---|---|
| `HeykinnClicks.provisionprofile` | the Developer ID build |
| `HeykinnClicks-AppStore.provisionprofile` | `--appstore` |

`bundle.sh` copies it to `Contents/embedded.provisionprofile` before signing,
which is the only moment it can be added — a profile put there afterwards is
ignored, and the result is an app that builds, signs, launches, and quietly does
not have the entitlements it asked for.

The App Store build **needs** one; App Store Connect rejects an upload without
it. The Developer ID build turns out not to: macOS hands a non-sandboxed process
its group container regardless, which is how the archive migrated here before
any profile existed. Worth having anyway rather than depending on that.

Every build prints what its signature actually carries — the *values*, not just
the keys, since `app-sandbox` is present and `false` in the Developer ID build:

```
Entitlements in the signed binary:
  · not sandboxed (Developer ID build)
  ✓ app group 344B87D3CV.com.heykinn.HeykinnClicks — shares one archive with the other build
  · no provisioning profile embedded
```

## Shipping it to somebody else

Everything up to here produces an app that runs **on this Mac only**. Three
things stand between that and a build anyone can open, and the first is a
prerequisite for the other two.

**1. A Developer ID Application certificate.** The keychain currently holds
*Apple Development* (local runs) and *Apple Distribution* (App Store). Neither
can notarise; Developer ID is a third kind. Create it at developer.apple.com →
Certificates, IDs & Profiles → Certificates → **Developer ID Application**,
which needs an Apple Developer Program membership and, on a team, the Account
Holder role. Check what is installed with:

```bash
security find-identity -v -p codesigning
```

**2. Sign and notarise.** Store the credentials once — this prompts for an
Apple ID and an app-specific password (**not** the account password; generate
one at appleid.apple.com), and keeps them in the keychain so they are never
typed into a script:

```bash
xcrun notarytool store-credentials heykinn --apple-id you@example.com --team-id TEAMID
```

Then, per release:

```bash
./Packaging/bundle.sh --release --sign "Developer ID Application: Name (TEAMID)"
ditto -c -k --keepParent build/HeykinnClicks.app build/HeykinnClicks.zip
xcrun notarytool submit build/HeykinnClicks.zip --keychain-profile heykinn --wait
xcrun stapler staple build/HeykinnClicks.app

# The zip that went up is the *un-stapled* one. Ship this one instead.
ditto -c -k --keepParent build/HeykinnClicks.app build/HeykinnClicks-notarized.zip
```

That last line is not a formality. The ticket is attached to the app by
`stapler`, after the upload, so the archive that was submitted does not contain
it. Shipping that archive gives everyone a copy that has to reach Apple to be
checked and fails on a machine that is offline or behind a filter — the one
failure nobody can reproduce at their desk.

### Changing signing identity revokes your permissions

Not obvious, and it looks exactly like a bug in the app. macOS records a privacy
grant against the *code identity* that asked for it, not just the bundle
identifier. Re-signing with a different certificate — ad-hoc → Apple
Development, or Apple Development → Developer ID — leaves a recorded decision
that no longer matches the running app, and `PHPhotoLibrary.requestAuthorization`
then returns **denied without ever showing a prompt**. The app reports "Photos
access was declined", which is true and reads as though somebody clicked no.

It happened here on the first Developer ID build: the library had connected
happily seven times under the development signature, and the notarised build was
refused in silence.

```bash
tccutil reset Photos com.heykinn.HeykinnClicks
```

Then relaunch and grant it again. This is a one-time cost per identity change,
so it stops mattering once the Developer ID certificate is the one in use —
that signature is stable across rebuilds, which is the whole reason to prefer a
real certificate over ad-hoc.

**3. Prove it.** The check that matters is not that the commands exited zero:

```bash
spctl -a -vvv -t exec build/HeykinnClicks.app
```

It reports `rejected` for a development signature — that is the expected answer
today — and `accepted, source=Notarized Developer ID` once the above is done.
If notarisation fails, `xcrun notarytool log <submission-id> --keychain-profile
heykinn` says why, and the answer is usually a missing hardened runtime, which
`bundle.sh` already sets.

## Why a bundle at all

The package builds a bare Mach-O binary. macOS runs it and it mostly works, so
it is easy to assume nothing is missing. Two things are:

- **No bundle identifier, so no stable identity for privacy grants.** Photos
  access currently works because Xcode is the responsible process and Xcode
  already holds the grant. Run the same binary on its own and there is nothing
  for TCC to attach a decision to.
- **Console noise.** macOS registers every windowed process with the App Intents
  daemon and the process instance registry, both of which read the bundle
  identifier. With none, every launch logs `connection to service named
  com.apple.linkd.autoShortcut` failures. Harmless, and it hides real errors.

## Why the website build is not sandboxed

`HeykinnClicks.entitlements` keeps the Developer ID website build outside the
sandbox. That build can discover a newly mounted volume and read its marker
before the user has picked it. It still records security-scoped bookmarks as a
secondary route and uses the marker token/volume identity before trusting what
a bookmark resolves to.

The Mac App Store build is deliberately different:
`HeykinnClicks-AppStore.entitlements` enables the sandbox, user-selected
read/write access, app-scoped bookmarks, Photos access, and the shared app
group. It cannot sweep unknown mounted volumes, so the user chooses a drive
once and the bookmark is the only route back to it. This is why the two builds
are separate entitlement variants rather than two packages around identical
permissions.

Both builds use the hardened runtime. Both need the Photos entitlement in the
effective signature; without it, macOS can refuse PhotoKit silently even when
the purpose string is present. `bundle.sh` reports that effective entitlement,
and `make-pkg.sh` additionally refuses an unsandboxed App Store package, a
missing application identifier/profile, and known unsupported entitlements.

## What is in this folder

| | |
|---|---|
| `bundle.sh` | Assembles `HeykinnClicks.app` around the SwiftPM binary and reports which entitlements the signed result actually carries. Everything else starts here |
| `make-pkg.sh` | The installer package the App Store takes. Refuses rather than producing something that would be rejected after an upload and a wait |
| `make-dmg.sh` | The disk image for the website build |
| `make-icon.swift` | Redraws `AppIcon.icns` from `BrandMark.png`. Needed when the branding changes, not otherwise |
| `make-demo-photos.swift` | Photographs for listing screenshots. The real archive cannot appear in a public listing — it holds real drive names and real people read out of a Google export |
| `make-review-fixtures.swift` | Privacy-safe media for an App Review recording, for the same reason |
| `make-review-volume.sh` | A disposable writable volume, so a reviewer's functional pass exercises the picker, bookmark, copy and relaunch paths without a personal disk |
| `validate-app-review-packet.sh` | Preflight on the reviewer notes: the 4000-byte limit, no unreplaced placeholders, every required heading, and that the version named matches `Info.plist` |

The last four are release tooling. What shipped, when, and the reviewer notes
themselves are in [`docs/releases/`](../docs/releases/README.md).

`prune-empty-replicas.sh` was here and is gone: a one-time sweep of empty
replica directories left by an older version, which the app has pruned as it
removes for months. Its own header said nothing called it.
