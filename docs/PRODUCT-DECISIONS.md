# Product decisions — what a person should have to understand

*Four decisions about the interface, in the shape of `ARCHITECTURE-DECISIONS.md`:
what is true today, what the options are, what each costs, and a recommendation.*

**All four recommendations are accepted. P3 is built; P1, P2 and P4 are not.**
Settled questions waiting for a turn, not open ones to be argued again.

Companion to invariant 15 and requirement R8: *a person who is not technical can
use this without learning our vocabulary.* That invariant has been satisfied for
words — the interface no longer says target, replica, catalog, marker or
residency domain. These are the decisions it does **not** settle, because
renaming a concept and removing it are different acts.

The frame for all four:

> **The app answers one question: are my photos safe?** Everything else is
> either how it knows, or something a person chose to care about. The first must
> never be visible. The second must never be compulsory.

---

## What is already true, before deciding anything

Checked rather than assumed, because two of these are better than they look from
the code:

- **The device this runs on is adopted as a place for copies on first launch**,
  automatically, if the disk has more than the reserve free
  (`adoptHostDeviceIfNeeded`). Nobody has to set that up.
- **Importing creates the group it needs.** A source brings its own storage
  group with it, taking the copy count and destinations from whatever was last
  chosen (`newSourceDefaults`). A person never has to create one first.
- **The add-source sheet still asks**, prefilled. So the questions are answered
  in advance but not removed.
- **Groups are a visible, first-class idea** — the storage matrix is a grid of
  groups against places.
- **"Where this should be kept" is an editable control** on a photo, and
  changing it moves nothing.

So the gap is not that the app is unusable without understanding it. It is that
the app *shows its reasoning*, and its reasoning is elaborate.

---

## P1 · How much must a person decide before their photos are safe?

**The question.** Between opening the app for the first time and having a second
copy of a photograph, how many decisions is a person asked to make?

Today: the device is adopted for them, and a group is created for them, but the
add-source sheet asks for a copy count and which places — prefilled, and still a
form. Plugging in a drive asks whether to manage it. Apple Photos asks about
iCloud, because the app cannot find that out for itself and guessing would break
R0.

**Options**

| | |
|---|---|
| Leave it | Every question is individually justified, and together they are still a queue in front of a person who has not yet seen a single photograph. |
| **Safe by default, questions later** | Import needs no answers. The app takes every place it already has and keeps the copies it can. The count and the places stay editable, and the app says plainly what it chose. |
| A guided first run | A wizard that asks the same questions in a nicer order. Moves the queue rather than removing it. |

**Recommendation: safe by default.** The strongest version is that a person can
install this, point it at a Takeout, walk away, and be safer than they were —
having answered nothing. The questions do not disappear; they stop being a gate.

**What it costs.** A default that is wrong is worse than a question, so the
default has to be defensible: *as many copies as there are places, up to two.*
And the app has to say what it did, in a line somebody can act on, or a silent
default is just a hidden decision.

**Not free of R0.** The iCloud question genuinely cannot be defaulted — the
answer changes what a photograph found in the Photos library *means*, and
guessing would have the app claiming a copy it has not checked. That one stays.

**Status:** decided, not yet built.

---

## P2 · Whether storage groups are a concept a person meets

**The question.** A group says how many copies a set of photographs should have
and which places should hold them. Should a person see that idea at all?

**Options**

| | |
|---|---|
| As today | Groups are visible, named and editable; the matrix is built around them. |
| **One group unless asked** | Everything lands in a single "All your photos" group. Groups remain in the model and in the code; the interface only reveals them if somebody splits their archive. |
| Remove them | One copy count for the whole archive. Simplest possible model. |

**Recommendation: one group unless asked.** Most people want "keep everything
twice" and would never open this screen. But removing groups outright is a real
capability loss, and not a hypothetical one: somebody with 2 TB of photographs
and three 1 TB drives *cannot* be served by a single archive-wide count, and
k-of-n placement is precisely what handles that. Keep the power, stop leading
with it.

**What it costs.** The matrix is a good screen and it becomes an advanced one.
That is the point, and it is still a loss for the person it was designed for.

**Status:** decided, not yet built.

---

## P3 · Whether "where this should be kept" is a control or an observation

**The question.** A photograph carries a residency — local, Apple's cloud,
Google's cloud — and today a person can change it from the detail pane. Changing
it moves nothing. It records an intention, and the app then reports the
photograph as being in the wrong place until something else moves it.

**This is the one with a tell.** The control needed a three-sentence warning
explaining that it does not do what it appears to do. Before rewriting, that
warning was *"Changing residency here only reassigns the logical domain. Keep
safe will list the presence mismatch until a migration moves the actual
content."* Plain language made it honest; it did not make it sensible.

**Options**

| | |
|---|---|
| Keep it as a control | Honest now, still a switch whose effect is to make the app start reporting a problem. |
| **Make it an observation** | The app tells you where a photograph is. Moving it is only ever a move, with the confirmation a move already has. |
| Hide it until a connector can act | Same as above, and the display goes too until there is something a person can do about it. |

**Recommendation: make it an observation.** A control whose only effect is to
create a discrepancy is a trap, however well it is worded. Moving content already
exists as a job with a confirmation; that is the honest way to change where
something lives, and it is the only one that ends with the photograph actually
there.

**What it costs.** Somebody correcting the app's record — "this really is in
iCloud, you have it wrong" — loses the way to say so. Worth knowing whether that
has ever been the reason anybody used it.

**Status:** decided and built.

**The open question answered itself in the code.** It was whether anybody used
the control to *correct* the app — "this really is in iCloud, you have it wrong".
They cannot have been, because that is a claim this app already refuses: earlier
versions let somebody state cloud presence and recorded the answer, and it was
withdrawn deliberately, because a claim with no evidence under it is not data
worth keeping (`CloudClaimWithdrawal`). The control was a leftover of the same
idea wearing a different hat, which makes the case stronger than the one argued
above rather than weaker.

**What went:** the picker in the photo detail pane, and `setManualResidency`,
whose only caller it was. **What stayed:** every path that changes residency
because something actually happened — a migration that moves the bytes, the
import default, placement, and the withdrawal above, which still runs on its own
and still rewrites residency to follow the content that exists.

`ResidencyIsObservedTests` covers those, and fails if a hand-set path returns.

---

## P4 · What the app says when nothing is wrong

**The question.** The interface is built to surface risk, which is right. But
most of the time the answer to *are my photos safe* is **yes**, and a screen
that only knows how to show work in progress and things at risk answers a
question nobody asked.

**Options**

| | |
|---|---|
| As today | Counts, groups, places, activity. Complete, and it asks the reader to assemble the answer. |
| **Lead with the answer** | One line at the top: *24,081 photos, every one on two drives, all checked this month.* Everything else stays, underneath. |
| A separate reassurance screen | Splits the audience rather than serving both. |

**Recommendation: lead with the answer.** It costs one line and a query the app
can already run, and it is the difference between a tool that reports and a tool
that reassures. It also gives risk somewhere to be *loud* against, which the
current design cannot do — everything is equally prominent.

**Status:** decided, not yet built.

---

## Taken together

P1 and P4 are the two that change how the app feels on first use, and neither
removes anything. P2 hides a screen. P3 removes a control, and is the only one
that takes a capability away — which is why it is the one I would take first, and
the one worth disagreeing with me about.

None of them touches the machinery. The archive, the merge, the drives and the
verification are unaffected by all four; this is entirely a question of what
crosses into the interface.
