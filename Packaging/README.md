# Packaging

`bundle.sh` assembles `HeykinnClicks.app` around the SwiftPM executable.

```bash
./Packaging/bundle.sh                    # debug, ad-hoc signed, runs on this Mac
./Packaging/bundle.sh --release
./Packaging/bundle.sh --release --sign "Developer ID Application: Name (TEAMID)"
```

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

## Why the app is not sandboxed

`HeykinnClicks.entitlements` sets `com.apple.security.app-sandbox` to `false`,
and that is a decision rather than an omission. The app manages an archive
spread across whatever volumes the user registers, reads folders they point it
at anywhere on disk, and identifies drives by a marker file it writes at the
volume root. A sandboxed app reaches none of that without a security-scoped
bookmark per location — and the app's identity model (marker token first,
volume UUID as fallback) is stronger than bookmarks for what bookmarks would be
solving here, because it survives a rename, a remount, and a different mount
path.

The consequence to accept: **no Mac App Store.** Distribution is Developer ID
plus notarisation.

With the sandbox off, `com.apple.security.files.*` and
`com.apple.security.personal-information.*` do nothing — they are sandbox
exceptions and there is no sandbox to except from. Photos access comes from
`NSPhotoLibraryUsageDescription` and the user's answer to the prompt, not from
an entitlement. They are left out rather than kept looking load-bearing.

Hardened runtime is a codesign flag (`--options runtime`), not an entitlement,
and none of its exceptions are needed: no JIT, no unsigned executable memory,
no library validation to disable. `allow-dyld-environment-variables` in
particular is absent on purpose — the archive redirect this app reads
(`HEYKINN_ARCHIVE_DIRECTORY`) is an ordinary variable read through
`ProcessInfo`, nothing to do with DYLD, and the exception would weaken the
runtime for nothing.

The entitlements file carries no XML comments because `codesign`'s parser
(AMFI) rejects them outright — hence this file.

## Still to do before anyone else runs it

- An icon. Drop `AppIcon.icns` in this directory and `bundle.sh` picks it up.
- A real Developer ID signature, then notarisation and stapling.
- Confirm the Photos prompt appears and is granted when launched standalone,
  which is the thing the bundle exists to make possible.
