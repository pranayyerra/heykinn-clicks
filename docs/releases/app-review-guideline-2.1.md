# App Review response — Guideline 2.1

This file is the submission checklist and the draft reply for the first Mac App
Store review. It describes the implementation in `Sources/` and `Packaging/`,
not planned features in `docs/SPEC.md`.

Do not paste the draft into App Store Connect until every bracketed value is
replaced and the attached recording has been watched from beginning to end.

## What the submitted app actually contains

| Review topic | Shipped behavior |
|---|---|
| Accounts | None. There is no registration, login, account deletion, or demo account. |
| Monetization | None. There are no purchases, subscriptions, paid features, ads, or payment processors. |
| User-generated content | None. The app displays only the user's own local photo library and files; there is no publishing, sharing, feed, messaging, reporting, or blocking flow. |
| Sensitive access | Photos-library access is requested only after **Add photos → Connect Photos**. Folder access begins with a system file picker. User-selected Takeout roots and registered external drives persist through app-scoped security-scoped bookmarks; the exact submitted-build physical test below remains a release gate. |
| Tracking | None. There is no App Tracking Transparency prompt, advertising identifier use, telemetry, crash-reporting SDK, or analytics SDK. |
| Network behavior | The app has no backend and does not upload user data. Apple's PhotoKit may download an original from the user's iCloud Photos library when the user has connected Photos and the original is not local. Google Takeout files are processed locally; the app does not call Google APIs. |
| Third-party code | None. The executable uses Swift and macOS system frameworks only. |

The relevant permission declarations are
`NSPhotoLibraryUsageDescription` and `NSRemovableVolumesUsageDescription` in
`Packaging/Info.plist`. The App Store entitlements are in
`Packaging/HeykinnClicks-AppStore.entitlements`.

### Review-critical implementation status

New-drive registration now starts at **Keep safe → Add Drive** and requires the
drive root to be chosen in the macOS file panel. The same picker gate is used
by the automatic drive-connect prompt and the "keep this drive" import offer.
The sandboxed monitor never sweeps ungranted mounted-volume roots; registered
devices return through app-scoped security-scoped bookmarks. Registration is
refused before writing a marker or catalog row if the persistent bookmark
cannot be created, and a failed or cancelled action is not remembered as a
successful decision. Folder and Takeout tasks retain their selected-file scope
until asynchronous reading finishes, and a selected Takeout root is converted
to a persistent per-machine bookmark before discovery begins so a later import
or relaunch does not lose access.

Unit coverage proves root validation, bookmark persistence, failure ordering,
and bookmark-only discovery. The signed TestFlight build has now completed the
Powerbox and relaunch gate on the physical test Mac:

1. Install the exact App Store/TestFlight build on a clean physical Mac.
2. Attach a writable external drive, register it, write one sample copy, quit,
   relaunch, and confirm the drive and sample remain reachable without another
   grant.
3. If registration or relaunch access fails, stop and diagnose the signed-build
   permission path, ship another build, and record only the replacement. Do not
   submit a video that omits external storage while the listing presents it as
   a core feature.

## Screen recording to attach

Record the exact submitted/TestFlight build on a physical Mac running the
latest public macOS. Use a clean macOS user account and non-personal sample
photos. Keep the full macOS menu bar visible so the device context and system
permission sheets are clearly genuine.

Recommended flow:

1. Start recording before launch, then launch **Heykinn Clicks** from
   `/Applications`. Show the empty Overview and its two setup steps.
2. Open **Add photos**. Briefly show the three supported inputs: Photos app,
   Google Photos download, and ordinary folders.
3. Choose **Connect Photos**. Capture the macOS Photos permission prompt and
   grant it. Answer the in-app iCloud Photos question truthfully for the test
   library, choose **Look through the library**, and let the small sample
   library finish importing.
4. Open **Photos** and one asset detail to show the unified library, metadata,
   and copy state.
5. Return to **Add photos**, choose **Choose a folder**, select a small sample
   folder, show the copy-count/device setup sheet, and complete the import.
6. Open **Keep safe**. Show this Mac as a copy location. If an external test
   drive is part of the advertised flow, add it through the picker, capture any
   removable-volume prompt, register it, and show the copy progressing to the
   drive.
7. Show **Activity** to demonstrate the on-device audit trail and return to
   **Overview** for the resulting protection summary.
8. If Google Takeout is named prominently in the store description or
   screenshots, also use **Find a download** with a small synthetic Takeout
   folder and show discovery/import. Do not use a real export containing
   private data.

Generate the disposable sample folder and extracted Takeout tree with:

```bash
# fixtures were generated by a script since deleted; any folder of
# images works, provided no real photograph or name appears
```

Every pixel and metadata value in that fixture is generated locally; it
contains no people, places, accounts, credentials, location data, or
third-party media.

If no disposable physical drive is available, create a temporary writable APFS
volume with `hdiutil create -size 400m -fs ExFAT -volname REVIEW`, which is what `make-review-volume.sh` did before it was deleted. macOS reports it as External and
Removable, so it exercises the picker, sandbox bookmark, copy, verification,
and relaunch paths without touching a personal disk. Disclose in the device
record that this is a mounted disk image, not a physical USB unplug/replug test.

There are no account, purchase, subscription, UGC reporting/blocking, camera,
microphone, location, contacts, or tracking flows to record.

Before attaching the recording:

- Confirm it starts with app launch and has no cuts that hide a permission or
  setup step.
- Confirm all sample names and images are safe to disclose to App Review.
- Confirm the build number visible in App Store Connect is the build that was
  recorded.
- Confirm the recording opens and plays to completion after upload.

## Device test record

List only complete passes of the submitted build, not machines on which the
source merely compiled or unit tests ran.

| Device | Chip | macOS | Build | Full flow | Notes |
|---|---|---|---|---|---|
| MacBook Pro (Mac15,6) | Apple M3 Pro | 26.6.2 (25G82) | 1.0 (153) | 14 August 2026 | Exact TestFlight build: 12 folder assets and 4 Takeout assets imported with 0 failures; all 16 copied to and read back from the temporary removable volume; quit/relaunch; folder and volume bookmark persistence. Mounted APFS disk image, not physical USB unplug/replug. |

Physical submitted-build pass completed on **MacBook Pro (Mac15,6), Apple M3
Pro, macOS 26.6.2 (25G82)**.

### Current review-evidence record

- App Store package prepared: **1.0 (153)**,
  `build/HeykinnClicks-1.0-153.pkg`.
- App Store Connect upload succeeded on 2026-08-14 with delivery UUID
  `635fff52-370a-43ef-90f9-3bd024a08f7a`; build 153 processed under version
  1.0, its export-compliance answer was saved as no listed encryption
  algorithms, and TestFlight reports the build as ready to submit.
- Package SHA-256:
  `2fcbf18bd4476b4adbf34c7c98ae8c4243e67b5115b0ff0f291218773ef1d0cd`.
- App executable SHA-256:
  `93df35011b36557c3c056defd7f17a989befb02265f24cf1c29d978567966658`.
- Privacy-safe sample attachment prepared:
  `build/Heykinn-Review-Fixtures.zip` (SHA-256
  `b719ad48c06e156c60e78360a29a4dbbebdb9dbd351e922831dd954124882c9c`).
- Full automated pass: **718 passed, 11 environment-gated skipped, 0 failed**.
- Exact TestFlight build **1.0 (153)** installed at
  `/Applications/HeykinnClicks.app`; its bundle metadata, TestFlight Beta
  Distribution signature, designated requirement, and Team ID `344B87D3CV`
  were verified before launch.
- Exact TestFlight physical pass: imported 12 ordinary-folder assets and 4
  Takeout assets with 0 failures, registered the temporary removable review
  volume, copied and read back all 16 assets there, quit, relaunched, and
  confirmed both the volume and source access returned without another picker.
- Review walkthrough prepared:
  `build/App-Review-Evidence/HeykinnClicks-1.0-153-App-Review-Walkthrough.mov`.
- Four replacement product-page screenshots prepared at 1440×900 in
  `build/App-Review-Evidence/`.
- Live App Store Connect update completed on 2026-08-14: build **1.0 (153)**
  was selected, the seven-part Notes response and four replacement screenshots
  were saved, **Sign-in required** was turned off, the walkthrough recording
  was attached to the app version, and the generated fixture ZIP was attached
  to the App Review conversation.
- The rejected item was updated to **Ready for Review** and submission
  `c2dd29a6-0bbc-41f9-b15c-209645e5de47` was resubmitted at 4:49 PM local
  time. App Store Connect then reported build 153 as **Waiting for Review**.
- A development-signed sandbox copy of the build 153 code completed the
  privacy-safe fixture flow on this physical Mac: 12 ordinary-folder assets
  and 4 Takeout assets imported with 0 failures; all 16 copy tasks completed
  and all 16 replicas were present. The stricter Takeout pass discovered the
  export, quit before import, relaunched, and imported all 4 assets without
  showing the picker again. This is implementation QA, not a substitute for
  the exact TestFlight build/device entry below.
- Installed TestFlight build **150** was used only for a preliminary physical
  check in the isolated test archive. Its folder-picker URL was no longer
  accessible when asynchronous enumeration began: the catalog recorded a
  zero-asset, zero-failure import from the 12-image synthetic folder. Build 152
  fixed that folder lifetime, but local sandbox QA then showed that a selected
  Takeout root was readable for discovery and not for the later import. Build
  153 persists that root and passed both flows above. **Do not upload, record,
  or cite builds 150 or 152 as passing device tests.** Upload/install build 153
  and repeat the complete flow before filling the table above.

## Draft App Review Notes / reply

The paste-ready version is
[`app-review-notes-1.0.txt`](app-review-notes-1.0.txt). It contains all seven
answers while staying below App Store Connect's 4,000-byte Notes limit. The
longer text below is retained as the evidence-rich source draft and must not be
pasted wholesale into the Notes field.

Validate the final note and attached recording before submission:

```bash
./Packaging/validate-app-review-packet.sh \
  app-review-notes-1.0.txt /path/to/review-recording.mov
```

During preparation, validate structure and size while allowing the two
deliberate `[[PLACEHOLDER]]` values:

```bash
./Packaging/validate-app-review-packet.sh --allow-placeholders \
  app-review-notes-1.0.txt
```

Replace the bracketed values, then paste this into both the reply and the App
Review Information Notes field so it remains available on future submissions.

> Thank you for the opportunity to provide the requested review information.
>
> 1. Screen recording: **HeykinnClicks-1.0-153-App-Review-Walkthrough.mov**, recorded on a physical
> **MacBook Pro (Mac15,6, Apple M3 Pro)** running **macOS 26.6.2 (25G82)**,
> using Heykinn Clicks **1.0 (153)** installed through TestFlight. It begins
> with launch and demonstrates the typical
> flow in the isolated synthetic archive: the verified Overview, imported
> photo library, completed folder and Google Takeout sources, two readable
> copies, and the filtered replication activity log. The recording does not
> access the user's Photos library or show its permission prompt.
>
> The app has no account registration/login/deletion, purchases or
> subscriptions, paid content, user-generated publishing, reporting/blocking,
> advertising, or App Tracking Transparency flow.
>
> 2. Devices and operating systems tested before submission:
>
> - **MacBook Pro (Mac15,6)**, **Apple M3 Pro**, macOS **26.6.2 (25G82)**,
>   tested **14 August 2026**
>
> All entries above were tested with build **153** installed as the
> sandboxed distribution/TestFlight build, including relaunch after granting
> Photos and folder/drive access.
>
> 3. Functions and target audience: Heykinn Clicks is a local-first photo
> archive and copy-verification utility for Mac users who keep personal photos
> and videos on their Mac and external drives. It imports copies from the Mac's
> Photos library, user-selected folders, and user-provided Google Takeout
> downloads; deduplicates identical files; places copies on user-selected
> devices; verifies those copies by reading them back; reports missing or
> changed copies; and keeps an on-device audit history. It solves the problem
> of not knowing whether a personal photo archive has enough independent,
> readable copies. The app does not publish, share, or upload the user's media.
>
> 4. Setup and access: No login or credentials are required. The app opens to
> an empty Overview. To exercise the main flow, open **Add photos** and either:
> (a) choose **Connect Photos**, grant the macOS Photos prompt, answer whether
> that test library uses iCloud Photos, then choose **Look through the
> library**; or (b) choose **Choose a folder**, select any folder containing
> image/video files, accept the proposed copy location, and choose **Add and
> start reading**. Open **Photos** to view imported items and **Keep safe** to
> view/configure copy locations. This Mac is automatically available as the
> initial local copy device when it has sufficient free space. To test an
> external device, attach a writable drive, choose/register it under **Keep
> safe** (or answer the drive prompt if shown), and leave it connected while the
> queued copy completes. The attached `Heykinn-Review-Fixtures.zip` contains
> generated sample folders for both ordinary-folder and Google Takeout tests;
> it contains no personal or third-party media.
>
> 5. External services/tools/platforms: The app uses Apple's PhotoKit framework
> to access the Photos library only after the user grants permission. PhotoKit
> may retrieve a full-resolution original from the user's iCloud Photos
> library when it is not present locally. Google Takeout is supported only as
> files the user has already downloaded and selects; the app does not sign in
> to Google or call Google APIs. All cataloging, hashing, deduplication,
> copying, verification, thumbnails, and diagnostics are performed locally.
> There is no app-operated server, authentication provider, payment processor,
> advertising service, analytics service, crash-reporting SDK, or AI service.
>
> 6. Regional behavior: The feature set and content behavior are the same in
> all regions. The current interface is English-only; there are no
> region-locked features, catalogs, accounts, prices, or country-specific
> content.
>
> 7. Regulation/protected material: The app does not operate in a regulated
> industry and does not bundle or provide protected third-party media. It
> processes only photos, videos, and export metadata the user already owns or
> is authorized to access through their local macOS account. No special
> authorization documents or credentials are applicable.

## Resubmission record

### Completed for this review

1. Installed exact TestFlight build **153** on the physical Mac and completed
   the folder, Takeout, removable-volume, copy/read-back, and relaunch tests
   recorded above.
2. Filled the device table and inspected the privacy-safe walkthrough.
3. Saved the final Notes, recording, screenshots, and reviewer sample ZIP in
   App Store Connect.
4. Replied to App Review, updated the rejected item to build 153, and
   resubmitted it. The final observed state was **Waiting for Review**.

### Before the next binary submission

1. Ensure screenshots show the running app with real sample content, especially
   Overview, Photos, Add photos, and Keep safe—not only an empty state or title
   art.
2. Keep the public privacy policy aligned with the PhotoKit/iCloud download
   behavior described in `docs/PRIVACY.md`.
3. Recheck both purpose strings on a clean user account and capture the exact
   prompt wording in the release evidence.
4. Verify the signed app's effective entitlements and embedded provisioning
   profile with the checks already performed by `bundle.sh` and `make-pkg.sh`.

The text of this Guideline 2.1 request asks for information rather than a code
change. The external-drive sandbox path above is nevertheless a release gate:
the implementation is now picker-based, but the physical submitted-build pass
must still prove that macOS grants and restores access before the final reply.
