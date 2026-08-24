# Testing sync between devices

Three levels, cheapest first. Do them in order — each one rules out a class of
problem before the next one costs you a drive plug.

**Start on a spare USB stick, not on the drives holding your archive.**
Everything here writes to a drive. The writes are confined to `HeykinnClicks/Sync/` and
touch no photographs, but a first run on the drives holding your only copies is
not the moment to find that out.

---

## 1. The automated checks — nothing to plug in

```bash
swift test
```

The sync tests cover: two archives converging, the same thing edited on
both, deletions not coming back, a drive read twice doing nothing the second
time, a drive pulled out mid-write, a drive written by a newer build being
refused, and the conditions a real volume adds — macOS's hidden files, a
read-only mount, non-segment files sitting beside real ones.

### Watch it happen

```bash
HEYKINN_DEMO=1 swift test --filter DemoSyncTests
```

A narrated run of two devices and a drive: an edit travelling, both devices editing
the same thing and agreeing afterwards, the drive yanked mid-write losing a
change, that change coming back on the next plug-in, and a deletion travelling
without being resurrected.

---

## 2. Two archives on this device, one real drive

This is the highest-value manual test: real removable media, real mount, real
filesystem — with only one device needed. The app can be pointed at a different
archive directory, so two copies behave as two devices.

```bash
mkdir -p /tmp/heykinn-deviceA /tmp/heykinn-deviceB
```

**Terminal 1 — "Device A":**

```bash
HEYKINN_ARCHIVE_DIRECTORY=/tmp/heykinn-deviceA swift run HeykinnClicks
```

Register your spare USB stick under **Keep safe**, make a storage group, then
quit.

**Terminal 2 — "Device B":**

```bash
HEYKINN_ARCHIVE_DIRECTORY=/tmp/heykinn-deviceB swift run HeykinnClicks
```

Point it at the same stick. It should learn the group Device A made.

### What you are looking for

- The drive's card shows a line like **"Shared 6 changes in, 0 out · just now"**.
- The group Device A made appears on Device B without you creating it.
- **Activity** records `received … and sent … changes about the archive`.
- On the drive: `HeykinnClicks/Sync/` holds `manifest.json` and one directory per
  device. Two device directories after both have run.

```bash
find /Volumes/YOUR_STICK/HeykinnClicks/Sync -type f | head -20
```

### Then try to break it

| Do this | Should happen |
|---|---|
| Plug in again with no changes | No new line, nothing written |
| Edit the same group's name on both, sync both | Both end with the *same* name |
| Delete the group on A, sync both | Gone on both, and it stays gone |
| Eject the stick **during** a sync | Reported, not crashed; the change arrives next time |
| Lock the stick (or `chmod a-w` the Sync folder) | An orange line saying it could not sync; photos unaffected |

---

## 3. Two real devices

Only worth doing once §2 passes. Same procedure without the archive override, a
drive carried physically between them.

The one thing this tests that §2 cannot: **each device must point at the drive
once**, because the permission macOS gives an app for a drive cannot be
transferred between devices. That is a floor, not a bug — Android has the same
rule. What should *not* happen is being asked twice on the same device.

---

## What "working" looks like on your archive

A first sync of 20,000 photographs is around **10 seconds** on the receiving
device and adds about **2.3 seconds** to an import. Both are measured by
`ChangeJournalCostTests` against that reference size, so if either is wildly different
on real hardware, that is worth knowing and worth reporting back.

---

## Known limits, so they are not mistaken for faults

- **Photographs do not move.** This carries what the app *knows* — which photos
  exist, where copies are, how they are grouped. Copying bytes is the existing
  sync and is unchanged.
- **Nothing converges without a shared drive.** Two devices that never see the same
  drive never agree. There is no network path.
- **Logs are never pruned yet.** They grow. Fine for months; not forever.
- **Windows and Android cannot read the Takeout zips**, so a client on either
  would see almost nothing of this archive. Tracked as H3 in
  `MULTI_DEVICE_STATE.md`.

## Yanking a drive

```bash
hdiutil create -size 400m -fs ExFAT -volname YANKTEST /tmp/yank -quiet
hdiutil attach /tmp/yank.dmg -nobrowse
HEYKINN_TEST_VOLUME=/Volumes/YANKTEST HEYKINN_TEST_VOLUME_IMAGE=/tmp/yank.dmg \
  swift test --filter testADriveYankedMidWriteLosesNothingPermanently
```

**Format it exFAT.** That is how large drives arrive, it has no journal to
replay, and it is what the author's own drives use. The test takes its format
from whatever volume you point it at, and had only ever been run on APFS — where
the answer to "did the volume survive" is easier.

It asserts two different things. That no photograph is lost for good: the
watermark never advances past a tear, so whatever was cut short comes back on
the next sync. And that the **volume itself** is still sound afterwards, by
running `fsck_exfat -n` over it — everything else would pass on a drive that
came back needing repair, which is the failure a person actually notices.

**What it still cannot reach.** A forced detach invalidates the mount; it does
not cut power to a drive's controller mid-flush, where the drive's own write
cache may hold bytes that never reach the flash. Nothing on a disk image
reproduces that. It needs a USB stick somebody is willing to lose.
