# Product decisions — what a person should have to understand

*Five decisions about the interface, in the shape of `ARCHITECTURE-DECISIONS.md`:
what is true today, what the options are, what each costs, and a recommendation.*

**P1, P3, P4 and P5 are built. P2 has been withdrawn and replaced**, and steps 1
and 2 of its replacement are built, leaving step 3 — the only thing on this page
still to do.

Companion to invariant 19 and requirement R8: *a person who is not technical can
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

**Status:** partly built, and the first part was not what this section
predicted.

The queue of questions is real but secondary. The measured problem was harder:
**a fresh install with no drive plugged in could not add photographs at all.**
Automatic placement considers external drives only — deliberately, because a
copy on the device the drives exist to outlive is not redundancy — so with no
drive the destination set came back empty, and `AddSourceSheet` disables its
confirm button on exactly that. A person who had not plugged anything in yet was
told nothing except that the button did not work.

Fixed by falling back to this device when there is no drive. Drives stay
preferred; "prefer drives" and "refuse to proceed without one" were always
different rules and only the first was intended. One copy is reported as one
copy, in the same words as any other shortfall, and the rest arrive when a drive
is registered. `SafeByDefaultTests`.

**And the softer half is now done too.** The sheet stated the arrangement as a
form — a copy count, a device list, a link to pick by hand — with every answer
already correct, in front of somebody who had not yet seen a photograph. It now
states it as a sentence, with `Change…` revealing the same form unaltered.

What made that possible was not a decision about forms. It was that placement
acquired a reason: it takes the drives with the most room, so the sentence can
say which and why. While the answer was "whichever were registered first" there
was nothing worth saying, and the controls were the only honest way to show the
arrangement.

**The reason is only given when a choice was actually made.** Two drives and two
copies took both, so it says "Every photo on New Drive and Old Drive." and
claims no judgement about room. A fresh install with no drive falls back to this
device, where "the roomiest" would be flatly untrue. Checked on screen, and
`StoragePlacementIntentTests` fails if either case starts explaining itself.

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

**Status: withdrawn.** The recommendation above is wrong, and wrong in a way
worth keeping on the page rather than quietly editing out.

**Hiding groups removes a decision without supplying the judgement to replace
it.** A group is currently the only place "which drives should hold what" is
expressed. Take it out of the interface and nothing else is capable of deciding,
because the machinery underneath cannot:

- `StorageGroup.automaticDestinations` is one line — `Array(eligible.prefix(copies))`.
  It takes the drives in the order they were registered. Not the ones with room,
  not the ones that fit, not the ones nearest the import. **Fixed** — see step 2.
- `PlacementPlanner` never reads capacity. The app knows free space — it shows
  it, and checks it before an import — but placement is blind to it. **Still
  true, and correct**: the planner honours a named list, and space is a
  constraint there, never a policy. The choosing moved a layer up.
- A drive records nothing about **whose it is**. Name, marker, volume id, last
  seen. Every registered drive is equally a place the archive may spread onto.
  **Fixed** — see step 1.

That last one is not hypothetical. A drive plugged in may be a friend's, or a
work one, or one being handed back. The app should be able to know that, and
today the only way to say it is to leave that drive out of a group's
destinations — precisely the control this section proposed to hide.

### What replaces it

The sequence matters, and it is the reverse of what was written here:

1. **Ask about a drive once, when it is registered.** Whose it is, and whether
   the archive may live on it. Ownership is a fact about a drive, not a property
   of a group, and it belongs where the drive is introduced. **Done** — one
   question with two named buttons, asked only for a drive nobody has claimed;
   the other cases are decided from the ID file already on it. See P5.
2. **Make placement able to decide. Done, and smaller than this line
   implies** — three rules, and only two of the four inputs listed here.

   > 1. Only drives that are yours.
   > 2. Emptiest first. Ties break on which was registered first.
   > 3. Take as many as the group asks for.

   Rule 1 is free: a drive that is not yours is never registered, which is what
   step 1 bought. Rule 2 reads a free-space figure **recorded when the drive was
   last seen**, not measured live — so a drive plugged into another device still
   counts, and every device reaches the same answer. Measuring live would have
   each device answer from whatever it could see, and a group's destinations
   would flip at every sync.

   *"What actually fits" and "which device the import is from" were dropped.*
   Fit is already a constraint the planner reports against by name, and adding
   it here would duplicate that in a second place with worse information.
   Which device the import is from is not a property of the archive and would
   make two devices disagree — the one thing this must not do.

   Spreading and running short both fall out of rule 2 rather than being rules:
   three drives and two copies takes the two emptiest, and as they fill the
   choice moves on its own. `PlacementRulesTests`.
3. **Then groups can recede** — because by then something else is doing their
   job, and hiding them costs nothing. **Now unblocked.** Still not free: an
   automatic group can now choose sensibly, but `.chosen` is what somebody uses
   to keep one drive offsite, and no rule can see a building. Hiding groups has
   to leave that sayable.

A few honest questions at the moment a drive or an import appears are not the
problem this document set out to solve. A queue of questions in front of somebody
who has not seen a photograph yet is. The two were run together here.

**The original recommendation is left above rather than deleted**, because the
reasoning that produced it — "most people want everything kept twice" — is still
true, and is exactly why it was tempting.

---

## P5 · What a person is asked when a drive is plugged in

**The question.** Three answers, a "remember this" toggle and a "not now" — five
things, for a drive somebody had just plugged in.

**What was wrong with it.** The list mixed two kinds of thing. *Keep my photos
on it* is a lasting fact about whose drive it is. *Look for Google downloads on
it* is something you do once. Putting an action inside a question about
ownership is what made the list long — and the action already had a home under
Add photos, which works on any drive without registering it.

**And two of the three cases need no question at all.** A drive already in use
asks nothing, and always did. A drive belonging to somebody else asks nothing
either, because the app can see whose it is from the ID file on it: the answer
it would be asking for is one it already has.

That leaves one case the app genuinely cannot decide — a drive nobody has
claimed. It cannot tell a new backup drive from a friend's stick, and guessing
either way is bad: claim every drive and it writes onto things it should not;
claim none and the drive somebody bought for this does nothing.

> **Use Field Drive for your photos?**
> `Yes, use it`

**Closing means no, and is remembered**, so there is no toggle — the question
does not come back, because whose a drive is does not change on Tuesday. Being
asked at every mount is worse than turning it on later, and later is one screen
away.

**Taking somebody else's drive** is not on this path at all. It is done from
Keep safe, deliberately, and confirms before anything is written.

**What it costs.** You can no longer say "always search this drive for downloads
when I plug it in". Anyone who already set that keeps it; it cannot be set from
here any more.

**Status:** decided and built.

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

**This was written up as an open decision in error.** It had already been taken
and built — `8d6c612`, "Let Overview be the short answer it says it is", five
days before the session that produced this document. The overview opens with
`theAnswer`: a seal or a warning, and one sentence — *"Every photo is in 2
places."* The description of "today" below was written from assumption rather
than from reading the screen, which is the mistake the rest of this document was
careful to avoid.

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

**Status:** already built, and the decision recorded here after the fact. What
this document adds is one line the overview did not have: how much of the
archive no longer needs its iCloud copy — see `ReclamationPlanner.Plan.plainSummary`.

---

## Taken together

P1 and P4 are the two that changed how the app feels on first use, and neither
removed anything. P5 turned five things into one question. P3 removed a control
and was the only one that took a capability away.

None of them touched the machinery — the archive, the merge, the drives and the
verification are unaffected by all five, and this was entirely a question of
what crosses into the interface.

**Except P2, which is why it was withdrawn.** Hiding groups was written up as
another interface question and was not one: it removed the only place "which
drives hold what" could be said, and nothing underneath was capable of deciding
in its place. Making it capable meant a new recorded fact on every drive, a
column in the catalog, and a rule with a reason. That is the one lesson on this
page worth carrying to the next decision — an interface question that cannot be
answered by changing the interface is a machinery question wearing a disguise.
