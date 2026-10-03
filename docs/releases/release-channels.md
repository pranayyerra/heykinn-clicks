# Release channels

Three stages, the same two build pipelines (`bundle.sh` → `make-pkg.sh` for
the App Store, `bundle.sh` → `make-dmg.sh` for the website), and the same rule
throughout: **production promotes the build that staging already tested — it
never rebuilds it.** A rebuild between staging and production, even from the
same commit, is a different binary than the one that was actually tested.

## Dev

```bash
swift run                                            # no Photos, no removable-volume access
HEYKINN_ARCHIVE_DIRECTORY=/tmp/scratch swift run      # isolated from your real archive
./Packaging/bundle.sh                                 # a real .app, Apple Development signed —
                                                       # needed to test Photos access at all
```

Use the in-app **test archive** (the button `TestArchiveMode` adds once an
archive exists) to run two copies side by side without them fighting over one
archive — see [`Packaging/README.md`](../../Packaging/README.md#testing-both-routes-at-once-without-touching-your-own-archive).

## Staging

Tag `vX.Y.Z-rc.N`. Build once per platform target, then hand it to testers
without it reaching anyone else:

**App Store (TestFlight):**
```bash
./Packaging/bundle.sh --release --appstore --sign "Apple Distribution: …" --build-number N
./Packaging/make-pkg.sh
# Upload with Transporter, or:
xcrun altool --upload-app -f build/HeykinnClicks-<version>-<build>.pkg -t macos -u <apple-id> --wait
```
This goes to App Store Connect's **TestFlight** tab, not straight to review —
add internal testers there.

**Developer ID (website):**
```bash
./Packaging/bundle.sh --release --sign "Developer ID Application: …"
./Packaging/make-dmg.sh --sign "Developer ID Application: …" --notarize heykinn
```
Publish the resulting `.dmg` as a **GitHub pre-release** (`gh release create
vX.Y.Z-rc.N build/*.dmg --prerelease`) rather than the real Releases page.

## Production

**App Store:** submit the *same build* already sitting in TestFlight for
review — do not re-run `bundle.sh`. See
[`submitting.md`](submitting.md) for the full submission checklist.

**Developer ID:** re-tag the same commit without the `-rc.N` suffix
(`vX.Y.Z`) and re-publish the *same* notarized `.dmg` already tested in
staging, this time as the real GitHub release.

Either way, once a release is cut, append what shipped to the top of
[`README.md`](README.md) in this folder — that file is the record of what went
out, not of how it was built.
