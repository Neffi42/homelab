# Incident: garage HDD read-only remount, second occurrence (2026-09-03)

## Symptom

Every scheduled `Snapshot` across all 6 kopiur-backed apps on `oliver`
(`kanidm-data`, `fb-quantum-data`, `ferdium`, `forgejo-data`, `continuwuity-data`,
`jellyfin-config`) started `Failed`ing on **2026-08-29** and kept failing daily
through **2026-09-02**, all with the identical error:

```
error writing pack file: unable to complete PutBlob(...) despite 10 retries:
Internal error: Could not reach quorum of 1 (sets=Some(1)). 0 of 1 request
succeeded, others returned errors: ["...: IO error: Read-only file system (os error 30)"]
```

`ClusterRepository/garage-raspberrypi` still reported `Ready`/`BackendReachable`
throughout — health probes are reads, which succeeded fine against the
read-only filesystem, so kopiur's own health check never caught it. Every
namespace failing on the same day with the same error was the tell that this
was the shared backend, not a per-app problem.

## Root cause

`/dev/sda2` — the external USB HDD at `/mnt/nabil/k3s` on raspberrypi, backing
garage's `data-garage-0` PVC via the `local-path-hdd` StorageClass — hit SCSI
command timeouts under the UAS driver and force-remounted read-only:

```
Aug 28 09:48:04 raspberrypi kernel: sd 0:0:0:0: [sda] tag#6 timing out command, waited 360s
Aug 28 09:48:04 raspberrypi kernel: sd 0:0:0:0: [sda] tag#6 Sense Key : 0x2 [current]
Aug 28 09:48:04 raspberrypi kernel: sd 0:0:0:0: [sda] tag#6 ASC=0x4 ASCQ=0x7
Aug 28 09:48:04 raspberrypi kernel: I/O error, dev sda, sector 973847320 op 0x1:(WRITE) ...
Aug 28 09:48:04 raspberrypi kernel: Aborting journal on device sda2-8.
Aug 28 09:51:24 raspberrypi kernel: EXT4-fs error (device sda2): ext4_journal_check_start:87: comm tokio-runtime-w: Detected aborted journal
...
Aug 28 10:00:04 raspberrypi kernel: EXT4-fs (sda2): I/O error while writing superblock
Aug 28 10:00:04 raspberrypi kernel: EXT4-fs (sda2): Remounting filesystem read-only
```

`ASC=0x4 ASCQ=0x7` ("logical unit not ready, operation in progress") plus
repeated `uas_eh_abort_handler` aborts on `tag#N ... inflight: CMD OUT` in the
minutes before the timeout is the classic signature of a UAS-over-USB3
enclosure dropping commands under sustained write load — not a one-off
cosmic-ray bitflip. This is the **second** `emergency_ro` event on this exact
disk in 6 days (see [[incident-2026-08-27-garage-disk-kopiur]], which fixed
the *previous* occurrence on 2026-08-27 — this one started the very next day).
Drive: `Bus 002 Device 002: ID 0bc2:61b6 Seagate RSS LLC Maxtor HX-M101TCB/GM
[M3 Portable 1TB]`.

Once remounted `ro`, the filesystem doesn't self-heal — it stayed
`emergency_ro` untouched for the full 6 days until manually fscked, because
nothing in the k8s stack (garage, kopiur, kubelet) can force an `fsck` on a
live-mounted device.

## Fix

1. `kubectl --context raspberrypi -n storage scale statefulset garage --replicas=0`
   (sole consumer of that StorageClass).
2. `sudo umount /mnt/nabil/k3s` (lazy `-l` if busy) then `sudo fsck -fy /dev/sda2`.
   - To check progress on a long-running `fsck.ext4` from another shell: find
     the real pid with `ps aux | grep fsck.ext4` (not `pgrep -f e2fsck` — the
     binary's actual `comm` is `fsck.ext4`, not `e2fsck`, even though it's the
     e2fsprogs `e2fsck` under the hood), then `sudo kill -USR1 <pid>` — prints
     a % to the fsck's own controlling terminal. No progress at all during the
     initial "recovering journal" line; that's expected, it's just journal
     replay.
3. Remount (`mount | grep sda2` confirmed `rw,relatime`, no `emergency_ro`),
   scale garage back to 1.
4. `kubectl --context oliver annotate clusterrepository garage-raspberrypi
   kopiur.home-operations.com/reverify-requested-at=$(date -u +%FT%TZ) --overwrite`
   per the [[kopiur-known-issues]] workaround, since the repo's own health
   conditions don't reliably re-evaluate.
5. Manually triggered a `Snapshot` per app (same pattern as the pre-existing
   `jellyfin-config-manual-*` object — `kind: Snapshot`, `spec.policyRef.name:
   <policy>`) for `kanidm-data`, `fb-quantum-data`, `ferdium`, `forgejo-data`,
   `continuwuity-data` rather than waiting for the next scheduled run, to
   confirm writes actually succeed post-fix.

## Advice going forward

### 1. Buy a new disk

Two `emergency_ro` events on the same physical drive in under a week, both
with matching UAS abort/timeout signatures, is a hardware reliability signal,
not bad luck. Treat this drive as failing. Once a replacement is in and
`replicationFactor` is bumped (below), migrate data off and retire this one —
don't wait for a third event, especially given [[garage-replication-factor-one]]
means the current single disk is one bad sector away from unrecoverable loss.

While buying, also fix the actual exposure this repo has flagged before:
`replicationFactor: 1` on garage means *no redundancy at all* on the only
remaining backup target. A second disk isn't just a replacement, it's the
minimum for `replicationFactor: 2` — worth doing at the same time as the swap
rather than as a separate future project.

### 2. Add S3 as a second, offsite `ClusterRepository`

Don't replace garage-raspberrypi — it's fast, local, and free. Add a real
S3-compatible backend as a **second repository** in each `SnapshotPolicy`'s
`spec.repositories` list (already a list-of-repos shape in
`apps/components/kopiur`), so every snapshot lands in both places. This is
belt-and-suspenders against exactly this failure class (single physical disk,
single node, single site).

Recommended: **Backblaze B2** (S3-compatible, ~$6/TB/month, free egress via
Cloudflare) or **Cloudflare R2** (~$15/TB/month, zero egress fees generally —
worth it if restores are expected to be large/frequent). Either plugs into
kopia natively — no shim needed. Skip rclone-fronted Google Drive: kopia
doesn't speak rclone remotes directly for its own repository backend (only
S3/GCS/Azure/WebDAV/filesystem natively), so it'd mean running `rclone serve
s3` as an always-on shim in front of Drive — one more moving part to babysit,
for a workflow kopia already handles at-rest-encrypted regardless of backend
(client-side AES-256-GCM/ChaCha20 before anything leaves the mover pod, so
"encrypted export" isn't a differentiator here).

### 3. Proposed: disable UAS for this enclosure (for review, not yet applied)

If the disk is kept (or as a stopgap before a replacement arrives), UAS is a
known-flaky transport for USB3 enclosures on Pi-class SBCs under sustained
write load — exactly this symptom (command aborts, then timeout, then I/O
error). Disabling UAS falls the kernel back to the older, more conservative
`usb-storage` (BOT) driver for just this device, by VID:PID
(`0bc2:61b6`, confirmed via `lsusb` — the Seagate Maxtor HX-M101TCB
enclosure), leaving every other USB device on the Pi unaffected.

**Proposed change** — append to `/boot/firmware/cmdline.txt` (all on the one
existing line, cmdline.txt must stay a single line):

```
usb-storage.quirks=0bc2:61b6:u
```

Full line would become:

```
console=serial0,115200 console=tty1 root=PARTUUID=192c1eb6-02 rootfstype=ext4 fsck.repair=yes rootwait cfg80211.ieee80211_regdom=GB cgroup_memory=1 cgroup_enable=memory usb-storage.quirks=0bc2:61b6:u
```

Requires a reboot to take effect (`usb-storage.quirks` is only read at driver
bind time). Verify after reboot:

```sh
cat /sys/block/sda/device/../../uevent   # or:
dmesg | grep -i "sd 0:0:0:0"             # should attach via usb-storage, not uas
lsmod | grep uas                         # module may still load for other devices, that's fine
```

**Trade-offs to weigh before applying:**
- BOT (non-UAS) is single-command-at-a-time — slower throughput than UAS,
  particularly for garage's small-object PUT-heavy workload. Backup windows
  may lengthen.
- It's a targeted fix for *this* drive, keyed to its VID:PID — if the disk is
  replaced anyway, the quirk becomes dead config (harmless, but worth removing
  or updating to the new drive's VID:PID at that point).
- Doesn't fix an actually-dying drive — if the enclosure/media itself is
  failing (rather than just UAS being flaky on this SBC+enclosure pairing),
  this delays the same failure rather than preventing it. Worth trying
  because it's free and reversible, not as a substitute for the disk
  replacement above if failures continue after applying it.

Not yet applied — needs a reboot and a decision on whether it's worth the
throughput trade-off given a replacement disk is likely incoming anyway.

## Key takeaways

- Same lesson as [[incident-2026-08-27-garage-disk-kopiur]], reinforced: an
  external USB HDD backing a `local-path` StorageClass carries independent
  hardware-failure risk, and apparently a *recurring* one on this specific
  drive/enclosure, not a single unlucky event.
- All scheduled snapshots failing on the same day with the identical error
  across every namespace is the fast tell that the problem is the shared
  backend (repository/disk/network), not any individual app's `SnapshotPolicy`
  or mover config — check `ClusterRepository` health and the node's mount
  state before digging into a specific app.
- `ClusterRepository.status` health probes are read-only and will report
  `Ready`/`BackendReachable` even while the backend is write-broken (e.g.
  filesystem remounted `ro`) — don't trust that condition alone when
  snapshots are failing; check actual `Snapshot` failure messages.
- `fsck.ext4`'s process `comm` is `fsck.ext4`, not `e2fsck`, despite being the
  same e2fsprogs binary under the hood — `pgrep -f e2fsck` finds nothing;
  match on `fsck.ext4` (or `fsck`) instead when trying to signal it.
