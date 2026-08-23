# The three open decisions

*Investigated so each can be taken. Facts first, then what each option costs,
then a recommendation.*

Companion to `ARCHITECTURE-DECISIONS.md` §Still open. **O1 is built and O2's
first tier is done**; both are kept as short entries rather than deleted,
because the recommendation each carries is what the next tier is measured
against.

---

## O1 · How zip members get read — **decided and built**

Written when it looked like a choice between vendoring a dependency and writing
a DEFLATE decoder by hand. It was neither: zip stores raw DEFLATE, which every
platform's own library already decodes, so the only thing to write was the
container reader. `ZipContainer` and `Inflate` are in `Domain/Portability/`, no
dependency was added, and the shell-outs to `unzip`, `tar` and `ditto` went with
it — `ditto` remains as a recorded fallback.

The investigation that reached that is in git history. What it was worth keeping
is one finding, because it was a live defect rather than an argument: reading
entry names through `unzip` output **lost non-ASCII filenames**, which is not a
portability concern at all. It was fixed by the same change.

---

## O2 · Whether other platforms read only, or also write

### What was assumed

Two tiers — read-only or read-write.

### What is actually true

**Three tiers**, and the middle one is the interesting one.

| Tier | Needs | Can show |
|---|---|---|
| **Status reader** | SQLite and the schema. **None of the kernel.** | What exists, where every copy lives, what is at risk, what is owed |
| **Browser** | The above, plus zip reading (O1) | The photographs themselves |
| **Writer** | The above, plus **the whole kernel** reimplemented and correct | Editing the archive from that device |

The split falls where it does because of two facts:

- **The catalog already holds the answers.** Photo rows, copy records, group
  membership and risk are all plain columns. A reader needs no clock, no device
  identity, no journal, no merge and no segment codec.
- **21,380 of 21,401 photographs live inside zips**, so displaying one requires
  O1. Thumbnails do not help — they live in a local `Caches` directory and never
  travel on the drive.

The writer tier is where the risk concentrates: the merge, the clock, journal,
segment codec and checkpoint, reimplemented on a platform with no test coverage,
where a mistake is silent and corrupts the shared archive for every device.

### Recommendation

**Read-only, and start at the status tier.** It needs nothing from the kernel, so
it can be built before O1 lands and gains photographs when O1 does. Defer the
writer tier until there is a concrete reason a person needs to *change* the
archive from a PC — and note that the conformance vectors already exist for it if
that day comes.

---

## O3 · A migration job advanced on two devices

### What is actually true

**Migration execution is not shipped.** There are no PhotoKit change requests
anywhere in the codebase — the state machine stops at user-confirmed manual
steps, exactly as `SPEC.md` describes.

So the scenario needs two devices independently advancing a job that neither can
execute. The state only moves when a person confirms a step, on the device in
front of them.

### Recommendation

**Defer, with a trigger.** Revisit when migrations execute end to end, which is
the point at which two devices could genuinely advance the same job. Recorded as
a deferral on evidence rather than a guess.

If it becomes live, the cheapest correct answer is likely the third option
already listed: keep migration jobs device-local and do not sync them, since a
migration is work happening where the drives are.

---

## The three calls

| | Recommendation | Blocking? |
|---|---|---|
| **O1** | Write the zip container reader, use the platform's inflate | **Yes** — a live defect, and R4 |
| **O2** | Read-only, status tier first, photographs when O1 lands | No |
| **O3** | Defer until migrations execute | No |

Taking O1 and O2 leaves no undetermined decisions in the architecture.
