# Privacy Policy — Heykinn Clicks

_Last updated: 10 August 2026_

Heykinn Clicks collects nothing.

There is no account, no server, and no analytics. The app has no way to send
your photographs, your file names, or anything about you anywhere, because it
never makes a network connection for those purposes at all.

## What the app reads

- **Your Photos library**, if you connect it. Read only. The app looks through
  the library to work out which photographs it already holds and which it is
  missing. It never changes, deletes, or adds anything there.
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

Verified copies of that catalog are written to the drives you register, so that
losing the Mac does not lose the record of what is on them.

## What leaves your Mac

Nothing, in the course of ordinary use.

Two exceptions, both under your control and neither involving your photographs:

- **macOS checks the app's signature with Apple** the first time you open it,
  as it does for every app you install. That is macOS, not this app.
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
those if you want them gone.

## Changes

If this policy ever changes, the change will be described here and dated. The
version of this file in the repository's history is the record.

## Contact

Questions about this policy, or about anything the app does with your files:
open an issue at https://github.com/pranayyerra/heykinn-clicks/issues
