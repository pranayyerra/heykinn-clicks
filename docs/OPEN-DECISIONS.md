# The three open decisions

*Investigated so each can be taken. Facts first, then what each option costs,
then a recommendation.*

Companion to `ARCHITECTURE-DECISIONS.md` §Still open.

---

## O1 · How zip members get read

### What was assumed

That this needs either a vendored dependency or a hand-written DEFLATE decoder,
and that it is a cross-platform concern for later.

### What is actually true

**The surface is six shell-outs across five files**, all macOS-only:

| Tool | Where | Doing |
|---|---|---|
| `unzip -Z1` | `ZipTools.listEntries` | listing entries |
| `unzip -p` | `HashingService.sha256OfZipEntry` | reading one entry to hash it |
| `unzip` | `ParallelZipExtraction`, `TakeoutScanner` | bulk extraction, scanning |
| `tar` | `ZipTools.extractEntries` | extraction that `unzip` gets wrong |
| `ditto` | `TakeoutExtractor` | extraction |

_All six are gone; see the status at the end of this section._

They reduce to **three operations**: list entries, read one entry as a stream,
extract many to disk.

**Inflate is already on every target platform.** This is the fact that changes
the decision:

| | |
|---|---|
| Apple | `Compression` framework — `COMPRESSION_ZLIB` is raw DEFLATE. A system framework, not a dependency |
| Windows | zlib, or the built-in Compression API |
| Android | `java.util.zip.Inflater`, in the platform |

So the work is **not** "write inflate" and **not** "vendor a library". It is
*parse the zip container and call the platform's inflate.* The container is a
well-documented format — local headers, central directory, end-of-central-
directory — with no compression logic in it, and published test files.

### And it is not only about other platforms

`unzip` is **already known-broken for this archive**, and the codebase documents
it. From `ZipTools.extractEntries`:

> A Mac screenshot exported by Google carries a narrow no-break space in its
> name. `unzip` mangles every non-ASCII byte to a literal `?` — in its *listing*
> as well as on disk — and then aborts mid-archive with a "disk full" error that
> has nothing to do with the disk, taking every entry after it. On one real part
> that was **4,673 of 6,660 sidecars lost, silently, with a zero exit path that
> looked like success.**

`extractEntries` was moved to `tar` because of this. **`listEntries` and
`sha256OfZipEntry` were not.** So today:

1. Entry names come from `unzip -Z1` — mangled where non-ASCII.
2. Those names are passed to `unzip -p` to hash the entry.
3. The `?` is unzip's own single-character wildcard, so the lookup matches by
   luck or not at all.

**A zip member with a non-ASCII name cannot be reliably claimed or verified on
macOS right now.** This archive has such files — that is where the quoted numbers
come from.

### The options

| | Cost | Gets you |
|---|---|---|
| **Write the container reader, use the platform's inflate** | ~200–300 lines plus vectors. No dependency. | Fixes the live bug; unblocks every platform; removes six shell-outs |
| Vendor a zip library | Fastest to write. First dependency, in the path that decides whether photographs are found. | Same, with a supply-chain question |
| Replace `unzip` with `tar` everywhere, stay on macOS | Small. | Fixes the live bug only. Leaves R4 blocked and keeps a subprocess per entry |
| Extract every zip on import and stop reading them | No reader needed. | Costs the disk space the zips exist to save — on this archive, most of it |

### Recommendation

**Write the reader.** It was mis-scoped as a large piece of work: the hard part
(inflate) is supplied by every platform, and the part that must be written is a
container parse with published test files. It is the only option that fixes a
defect which is silently mis-verifying this archive today, and unblocking
Windows and Android is a side effect rather than the justification.

### Decided and built

`ZipContainer` parses the central directory, including zip64, and reads names
from the archive's own bytes. `ZipReader` streams an entry through the
platform's inflate. `ZipTools.listEntries`, `HashingService.sha256OfZipEntry`
and `TakeoutScanner.zipListingLooksLikeTakeout` no longer run a subprocess.

**One correction to the analysis above.** The defect is narrower than first
stated: `unzip -p` works correctly *given a correct name* — exit 0, right bytes.
Everything downstream broke because the **listing** was the mangled source.
Fixing `listEntries` is what fixes it.

Measured with the old listing in place, on an archive of four files:

| Entry | Listed as | Readable |
|---|---|---|
| `Image 10-10-24 at 4.54 PM.jpg` | `…4.54???PM.jpg` | No |
| `café/naïve.jpg` | `cafe??/nai??ve.jpg` | No |
| `emoji 📷 shot.jpg` | `emoji ???? shot.jpg` | No |
| `plain.jpg` | `plain.jpg` | Yes |

**Three of four unreadable** — any accent, emoji or unusual space. Each one is a
photograph the app would record as absent from a drive holding it.

**Bulk extraction has since followed, and it was a separate question.** Those
paths write files to disk rather than producing recorded facts, so the case for
converting them was R4 and not correctness. That was checked rather than assumed:
`ParallelZipExtraction`'s `unzip` workers were tested against a fixture in
Google's exact shape — UTF-8 names with the UTF-8 flag *unset*, covering both the
ASCII-wildcard and the literal-escaped-name paths — and **every entry
round-tripped**. The mangling that broke the listing did not reach them, because
the patterns those workers are given are ASCII directory prefixes.

Converted anyway, for R4, and two things came of it:

- **1.39× faster than the four `unzip` processes it replaced** — 0.34s against
  0.47s for 1,200 photographs and their sidecars in a 229 MB archive. No process
  to spawn, no argument list to build, and no length limit on one either, which
  is why buckets can now be exact entry names rather than glob patterns.
- **A refusal nobody owned.** An entry named `../../.ssh/authorized_keys` was
  refused by `unzip` and `tar` in their own ways; extracting in process means
  owning that check rather than inheriting it.

`diskutil` remains and is allowed to: it picks a worker count, which is a speed
hint rather than a recorded fact.

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
| **Writer** | The above, plus **3,534 lines** of kernel reimplemented and correct | Editing the archive from that device |

The split falls where it does because of two facts:

- **The catalog already holds the answers.** Photo rows, copy records, group
  membership and risk are all plain columns. A reader needs no clock, no device
  identity, no journal, no merge and no segment codec.
- **21,380 of 21,401 photographs live inside zips**, so displaying one requires
  O1. Thumbnails do not help — they live in a local `Caches` directory and never
  travel on the drive.

The writer tier is where the risk concentrates: 3,534 lines of merge, clock,
journal, segment codec and checkpoint, reimplemented on a platform with no test
coverage, where a mistake is
silent and corrupts the shared archive for every device.

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
