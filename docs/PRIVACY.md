# Privacy Policy — Heykinn Clicks

_Last updated: 14 August 2026_

Heykinn Clicks collects nothing.

There is no account, app-operated server, advertising, or analytics. The app
does not upload your photographs, file names, catalog, or diagnostics. If you
connect the Photos library, Apple's PhotoKit framework may download a full-size
original from your own iCloud Photos library when that original is not already
on the Mac; that transfer is between the Photos library you authorized and
Apple's iCloud service, and the app uses the downloaded original only to build
your local archive.

## What the app reads

- **Your Photos library**, if you connect it. Read only. The app looks through
  the library to work out which photographs it already holds and which it is
  missing, and can copy full-size originals into your local archive. It never
  changes, deletes, or adds anything in Photos.
- **Folders you choose**, and Google Takeout downloads you point it at. Read
  only. Files are copied *into* the archive; the originals are left exactly as
  they are.
- **Drives you register**, so it can keep and verify copies on them.

Nothing is read until you point the app at it.

## What the app stores, and where

Everything the app knows lives on your own Mac, in a catalog file, and in copies
on the drives you chose. Nothing else holds any of it.

The catalog records what you would expect a tool like this to record: which
photographs exist, where their copies are, when each copy was last checked, and
descriptions, album names and people's names that were already written inside
the Google export you imported. It also keeps a log of what the app did — what
was imported, copied, verified.

On this Mac, app preferences also keep security-scoped bookmarks for the
Takeout folders and drives you selected. A bookmark is macOS permission to
return to that location after relaunch; it contains no photograph or catalog
content and is not copied into catalog snapshots or sent anywhere.

Verified copies of that catalog are written to the drives you register, so that
losing the Mac does not lose the record of what is on them.

## What leaves your Mac

The app sends none of your content or catalog data anywhere in the course of
ordinary use.

Related network or sharing events are:

- **PhotoKit may download an original from iCloud Photos**, as described above,
  only after you connect Photos. The app never uploads to or modifies Photos.
- **macOS may contact Apple for system services**, including checking the app's
  signature and providing iCloud Photos content. Those connections are made by
  macOS frameworks, not an app-operated service.
- **A diagnostics report**, if you choose to save one and send it to us. It is
  redacted before it is written: drive names become "Target A", file paths and
  file names are replaced with placeholders. You can read it before sending it,
  and nothing sends it for you.

## Children

The app is not directed at children and collects nothing from anybody.

## Removing everything

Drag the app to the Trash. Your photographs and your drives are untouched. The
app's own records are in
`~/Library/Group Containers/344B87D3CV.com.heykinn.HeykinnClicks/`, and copies
it made are in a `HeykinnClicks` folder on each drive you registered — delete
those if you want them gone. An App Store installation also keeps its local
preferences and permission bookmarks under
`~/Library/Containers/com.heykinn.HeykinnClicks/`; delete that container if you
want the remembered permissions removed as well.

## Changes

If this policy ever changes, the change will be described here and dated. The
version of this file in the repository's history is the record.

## Contact

Questions about this policy, or about anything the app does with your files:
open an issue at https://github.com/pranayyerra/heykinn-clicks/issues
