# Releases

What went out, when, and what changed. One section per release, newest first.

**The rule for this file:** it records what was *released* — a version, a build
number, a date, and the changes somebody using the app would notice. It does not
record how many tests passed or which internal step was finished. Those belong
to the commit that made them true and are wrong here by the following week.

Each release is tagged: `git show v1.1.0`. The tag is the commit the build was
made from, which is the only reliable answer to "what was actually in it".

Also here:

| | |
|---|---|
| [`submitting.md`](submitting.md) | How to build, sign and upload. Read the version-train note before bumping a build number |
| [`app-review-guideline-2.1.md`](app-review-guideline-2.1.md) | The 1.0 rejection under Guideline 2.1 and the reply that resolved it. Kept because the next review can ask the same thing |
| [`app-review-notes-1.0.txt`](app-review-notes-1.0.txt) | The reviewer notes submitted with 1.0 |
| [`app-store-connect-audit.md`](app-store-connect-audit.md) | The listing as inspected on 14 August 2026 — description, keywords, and the settings that were wrong |

---

## 1.2 (155) — submitted 24 August 2026

Tag `v1.2.0`. Twenty-nine commits since 1.1, of which four change what anybody
sees; the rest are seams, tests and documents.

**Your own Mac could go missing from its own archive, silently.** When the
archive moved into the app-group container, the folder holding this device's
copy moved with it — and the path recorded for that device did not. The app then
looked for it where it used to be, so the device read *away* for ever while
being the machine the app was running on. Its photographs stopped counting
toward safety and nothing new was ever copied to it, with nothing on screen
saying anything was wrong.

Found on a real archive where it had been true for sixteen days. Fixed at
launch, and the folder is re-adopted only because it still carries the ID file
naming that device — never because it sits where one would expect. The audit log
records what was found and that nothing was copied.

**Clearing out a folder you imported from.** Photographs the archive holds on
your drives, and has read back, leave a duplicate behind in the folder they came
from. The folder's card now offers to move those to the Trash — recoverable,
never unlinked. It refuses on anything it did not import, on copies nothing has
read yet, and on a file edited since. This is the only place the app offers to
delete something that is yours.

**A photograph in one place is no longer called safe.** Its badge read *"Safe on
one copy"* in green while the archive warned about the same photographs in
orange, one click away. One copy now uses the same words everywhere.

### Known problem, fixed after 1.1

The device-path fault above affects anyone still on 1.1.

---

## 1.1 (154) — approved 19 August 2026

Tag `v1.1.0`. Thirty-nine commits since 1.0.

**Two fixes for copies that had quietly stopped being made.** If drives had ever
been chosen by hand, every later batch of photos stayed pinned to that same
list, so a drive bought afterwards was never used for anything new. Google
Photos downloads had the same fault by a different route. Both fixed.

**New photos go to the drives with the most room**, rather than whichever was
set up first. As a drive fills, the choice moves on by itself.

**Adding photos states its plan instead of asking.** One sentence naming where
the photos will go, with a link to change it, in place of a form.

**One answer to whether photos are safe.** Two screens had been working it out
separately and disagreeing: a damaged copy was described as still copying on the
screen most people open first.

**Plugging in a drive asks one question**, with two named buttons, and only for
a drive the app has never seen. A drive carrying another archive's ID file is
left alone rather than taken over.

**The storage screen shows one line** while every set of photos is kept the same
way. Anything kept differently keeps a row of its own.

**Plain language throughout** — drives, photos and copies, not the words the app
uses internally.

**Space is returned automatically** once the drives hold a photo and have read
it back, and the app says how much of the archive no longer needs its iCloud
copy.

### Known problem, fixed after this release

A device whose archive had migrated out of `Application Support` into the
app-group container showed as **away for ever** — the folder moved, the recorded
path did not. Its photographs stopped counting toward safety and nothing new was
copied to it. Silent: the app never reported anything wrong. Fixed on `main`
after 1.1 shipped; anyone still on 1.1 is affected.

---

## 1.0 (153) — approved August 2026

Nine commits since 0.1.0, almost all of them about shipping rather than the app:
sandbox permissions surviving the work they authorise, the app's identity signed
into the binary rather than only the profile, and a sandboxed build being
introduced to drives it already owned.

Rejected once under **Guideline 2.1** and resolved — see
[`app-review-guideline-2.1.md`](app-review-guideline-2.1.md).

---

## 0.1.0 — private beta, 10 August 2026

Tag `v0.1.0`. The first build anybody else ran.
