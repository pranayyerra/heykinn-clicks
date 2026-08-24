# Submitting to the Mac App Store

Everything here needs an Apple account, which is why it is written down rather
than scripted. The parts that can be scripted already are:
`Packaging/bundle.sh --appstore` and `Packaging/make-pkg.sh`.

Work through it in this order; each step needs the one before it.

---

## 1. The installer certificate

Two different certificates are involved, and having the first without the second
is the ordinary situation — the first is what Xcode makes for you, the second
has to be asked for.

| Certificate | Signs |
|---|---|
| Apple Distribution | the `.app` |
| **3rd Party Mac Developer Installer** (a.k.a. Mac Installer Distribution) | the `.pkg` |

**Xcode → Settings → Accounts → your Apple ID → Manage Certificates → `+` →
Mac Installer Distribution**

Check it arrived:

```bash
security find-identity -v | grep "3rd Party Mac Developer Installer"
```

## 2. The App ID and the app group

At [developer.apple.com](https://developer.apple.com/account/resources/identifiers/list):

1. **Identifiers → `+` → App IDs → App**
   - Description: Heykinn Clicks
   - Bundle ID: **Explicit**, `com.heykinn.HeykinnClicks`
   - Capabilities: tick **App Groups**
2. **Identifiers → App Groups → `+`** and register the group, then come back to
   the App ID and assign the group to it.

> **Verify this before assuming it:** the app currently declares the group as
> `344B87D3CV.com.heykinn.HeykinnClicks`, which is the team-prefixed form macOS
> requires. Apple's portal has historically wanted app groups registered with a
> `group.` prefix. If the portal will not accept the identifier as it stands,
> register `group.com.heykinn.HeykinnClicks` and change the constant in
> `App/ArchiveLocation.swift` plus both `.entitlements` files to match —
> `EntitlementTests` will fail until all three agree, which is the point of it.
> The archive migration handles the move; existing users keep their archive.

## 3. The provisioning profile

**Profiles → `+` → Mac App Store Connect** (under Distribution) → choose the App
ID → choose the Apple Distribution certificate → download.

Drop it in as `Packaging/HeykinnClicks-AppStore.provisionprofile`. `bundle.sh`
embeds it automatically, before signing, which is the only moment it can be
added.

## 4. The App Store Connect record

At [appstoreconnect.apple.com](https://appstoreconnect.apple.com) →
**Apps → `+` → New App**:

- Platform: **macOS**
- Bundle ID: `com.heykinn.HeykinnClicks`
- SKU: anything stable and private, e.g. `heykinn-clicks-1`

## Before you start

Add the release to [`README.md`](README.md) in this folder — version, build,
date, and what somebody using the app would notice. Do it while you still
remember; reconstructing it from commit messages afterwards is how a release
ends up described as "various fixes".

Tag the commit the build was made from, matching the existing style:

```bash
git tag -a v1.2.0 -m "Heykinn Clicks 1.2 (155) — App Store"
```

The tag is the only reliable answer to "what was actually in that build", since
`main` moves on immediately.

## 5. Build and upload

The signing identity is whatever `security find-identity -v -p codesigning`
lists as `Apple Distribution: …`, team `344B87D3CV`.

```bash
./Packaging/bundle.sh --release --appstore --sign "$(security find-identity -v -p codesigning | grep -o 'Apple Distribution: [^"]*' | head -1)" --build-number 155
./Packaging/make-pkg.sh
```

`make-pkg.sh` refuses rather than producing something that would be rejected
after an upload and a wait: it checks the app is sandboxed and that a profile is
embedded.

Upload with **Transporter** (free, from the Mac App Store) — drag the `.pkg` in.
It handles the credentials, so nothing here has to. Or from the terminal:

```bash
xcrun altool --upload-app -f build/HeykinnClicks-<version>-<build>.pkg -t macos -u <apple-id> --wait
```

**Raise `CFBundleShortVersionString` too, not only the build number.** Once a
version has been approved, that train is closed: a new build under the same
version is rejected before it uploads, with *"the value for key
CFBundleShortVersionString must contain a higher version than that of the
previously approved version"* and *"the train version is closed for new build
submissions"*. The version lives in `Packaging/Info.plist` and nothing overrides
it — `--build-number` sets `CFBundleVersion` only. Build numbers do not have to
restart when the version changes.

## What the first upload actually cost

Three rejections, all the same shape: **signing by hand means nothing checks the
entitlements until Apple does.** Xcode papers over all of this, and none of it
is visible locally — `codesign` signs whatever it is handed, and the app builds,
launches and runs perfectly with every one of these faults in it.

| Rejected with | Cause |
|---|---|
| 90886 — missing application identifier | Xcode injects `com.apple.application-identifier` and `com.apple.developer.team-identifier` from the profile. Manual signing does not, so the app claimed to be nobody while carrying a profile naming it precisely. |
| 90285 — unsupported entitlement | `com.apple.security.device.removable-volumes` does not exist. The `device.*` family is camera, microphone, USB. An invented key is ignored locally and refused on upload. |
| *(caught before upload)* | `com.apple.security.personal-information.photos-library` missing from the **Developer ID** build. A Hardened Runtime entitlement as much as a sandbox one, and without it macOS refuses the Photos library silently — no prompt, no entry in System Settings. |

`make-pkg.sh` now refuses on the first two before building, and `bundle.sh`
prints what each signature actually carries. Expect more of these: Apple
validates a great deal server-side and documents little of it, so the guard list
grows from what has actually been met rather than from any published set.

## 6. What the listing needs

- **Privacy policy URL** — mandatory. `docs/PRIVACY.md` is written; it needs to
  be at a URL. GitHub Pages, or the raw file, both work.
- **Privacy questionnaire** — the honest answer to every question is *Data Not
  Collected*. There is no account, no server, no analytics.
- **Screenshots** — 1280×800 or larger. Overview and Keep safe are the two
  screens that show what this is.
- **Description, keywords, category** — Photo & Video, or Utilities.
- **Support URL** — the repository's issues page will do.

## 7. App Review information

The physical-device test record, evidence, and recording script live in
[`app-review-guideline-2.1.md`](app-review-guideline-2.1.md). The separate
[`app-review-notes-1.0.txt`](app-review-notes-1.0.txt) is the paste-ready
seven-part answer; it is deliberately kept below App Store Connect's
4,000-byte Notes limit. Fill its two placeholders from the exact submitted
build pass, attach the recording and generated sample archive, then validate
the packet before pasting it into **App Review Information → Notes** and the
review reply:

```bash
./Packaging/validate-app-review-packet.sh \
  app-review-notes-1.0.txt /path/to/review-recording.mov
```

There are no review credentials because the app has no account. Do not leave
the credentials fields looking accidentally incomplete: state explicitly in
Notes that no login or demo account is required.

---

## Before submitting, not after

Two things worth doing first, because a rejection costs a review cycle:

- **Register a drive in the sandboxed build and confirm it survives a
  relaunch.** The App Store flow now uses **Keep safe → Add Drive**, requires a
  system-selected drive root, and reaches returning drives only through
  bookmarks. Unit tests cover the contract; a signed physical-device pass is
  still the release evidence.
- **Discover a user-selected Takeout folder, quit, relaunch, then import it
  without choosing the folder again.** Discovery and import are separate
  actions, so the selected root must be restored through its own app-scoped
  bookmark; retaining only the file panel's temporary grant is not enough.
- **Remember the reviewer has no drive plugged in.** An app about external
  drives, opened on a machine with none, has to still make sense — the first-run
  screen is what they will see, and it should read as an app waiting for a drive
  rather than an app that is broken.
- **Use the submitted build for the recording.** A local source build is not
  evidence for the binary under review. Record a TestFlight/App Store-signed
  install on a physical Mac, and list only devices on which that build completed
  the manual flow.
