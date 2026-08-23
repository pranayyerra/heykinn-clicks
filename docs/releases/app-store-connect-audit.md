# App Store Connect audit — macOS 1.0

Initial read-only inspection performed on 2026-08-14 against app record
`6799953111`. The code and signed binary remain the source of truth.

On 2026-08-14, with the account holder's approval, the proposed promotional
text, description, and keywords below were saved in App Store Connect, and the
incorrect **Sign-in required** setting was turned off. Reviewer notes,
attachments, screenshots, build selection, and the review reply were not
changed as part of that update.

## Completed corrections

1. **Sign-in required** is now off, consistent with the app having no account
   or login.
2. Replacement build `1.0 (153)` has been uploaded and passed export-compliance
   questioning. It is available for exact-build TestFlight testing.
3. The code-accurate promotional text, description, and keywords in this
   document are now live in App Store Connect.
4. The exact TestFlight build `1.0 (153)` was selected for the macOS 1.0 app
   version and updated into the rejected review item.
5. The complete seven-part response was saved in App Review Information
   Notes, **Sign-in required** was confirmed off, the build-153 walkthrough
   was attached, and four 1440×900 screenshots from the synthetic archive
   replaced the older images.
6. `Heykinn-Review-Fixtures.zip` was attached to the App Review conversation,
   and a reply identifying the updated build and evidence was sent to Apple.
7. Submission `c2dd29a6-0bbc-41f9-b15c-209645e5de47` was resubmitted on
   2026-08-14 at 4:49 PM local time. App Store Connect reported build 153 as
   **Waiting for Review** after submission.

## Resubmission evidence completed

1. [`app-review-notes-1.0.txt`](app-review-notes-1.0.txt) was saved to the
   live Notes field (3,890 of 4,000 bytes).
2. `HeykinnClicks-1.0-153-App-Review-Walkthrough.mov` was attached to the app
   version.
3. `Heykinn-Review-Fixtures.zip` was attached to the App Review conversation
   as generated, non-personal sample data.

## Product-page metadata inconsistency

The previous description said assets could live in "a chosen cloud" and
described user-driven migration between local and cloud. The shipped executable
has no cloud-provider connection, app backend, authentication, or cloud
verifier. It can read Apple Photos through PhotoKit; PhotoKit may download an
iCloud Photos original, but that is not a selectable storage destination
offered by this app. The code-accurate replacement below was saved on
2026-08-14.

### Promotional text

Build a photo archive you can verify: import from Photos, folders, and Google
Takeout, then keep readable copies on the Mac and drives you choose.

### Description

Hey Kinn Clicks is a local-first photo and video archive manager for macOS. It
helps people who keep personal media on a Mac and external drives answer a
simple but important question: are there enough independent, readable copies
of every photo?

Import from:

• Apple Photos, after granting the macOS Photos permission
• Ordinary folders you select
• Google Takeout downloads already stored on your Mac or drives

Choose how many copies each group of photos needs and which registered devices
may hold them. Hey Kinn Clicks copies files to those devices, verifies them by
reading the bytes back, and clearly reports anything missing, changed, or still
waiting for another copy.

The app also:

• Deduplicates byte-identical files
• Preserves source and capture metadata where available
• Keeps an on-device audit history of imports, copies, and checks
• Recognizes registered drives through user-granted macOS access
• Leaves source folders and Apple Photos originals unchanged

Everything is processed locally. There is no Hey Kinn account, app-operated
server, advertising, analytics SDK, payment system, or AI service. Google
Takeout support reads files you already downloaded; it does not sign in to
Google or call Google APIs. Apple PhotoKit may retrieve an original from your
iCloud Photos library when that original is not stored locally.

Your archive remains plain media files plus a portable local catalog, so the
files do not depend on an online account or proprietary cloud service.

### Keywords

`photo,archive,backup,storage,local,privacy,photos,verify,integrity,Takeout`

## Screenshots

The four submitted screenshots were replaced on 2026-08-14 with build-153
screenshots from the generated review fixture and temporary `Heykinn Review
Drive`. They show the running app rather than title art, login pages, or splash
screens, in this order:

1. Overview with the synthetic archive's protection summary.
2. Photos with the generated sample grid.
3. Keep safe with `This Mac` and `Heykinn Review Drive`.
4. Activity showing only generated fixture names and successful copy checks.

## Already consistent

- App Store version: `1.0`.
- Category-oriented product copy: Photo & Video / utility behavior.
- Support and marketing URLs point to the project repository.
- Four screenshots show actual app UI.
- No in-app purchases or subscriptions are configured.
- The signed app contains clear Photos and removable-volume purpose strings.
