# Incident: garage/kopiur backup outage (2026-08-27)

## Symptom

`kopiur-config` Flux Kustomization stuck on `oliver`, cascading via `dependsOn` to
`kanidm`, `ferdium`, `fb-quantum`, `jellyfin`, and transitively `forgejo`,
`continuwuity`, `sableclient`. Root object: `ClusterRepository/garage-raspberrypi`
stuck `Degraded`, `BackendUnreachable`, since **2026-08-22T13:43:55Z**.

Three independent problems stacked on top of each other. Fixing #1 only exposed #2,
fixing #2 only exposed #3.

## Problem 1 — stale CoreDNS cache on oliver (started the outage)

CoreDNS (single replica, 49 days uptime, 52 restarts) returned persistent `NXDOMAIN`
for `s3.pi.neffi.fr` — while Pi-hole, Terraform state, and Tailscale's own resolver
(`100.100.100.100`) all had the correct record the whole time. `garage.pi.neffi.fr`
(same zone, same backend) resolved fine throughout, ruling out a real DNS/Pi-hole
problem.

Likely trigger: timing lines up with `iac/dns` automation work that day (new
`dns-reader` service account, several `push`/`workflow_dispatch` runs 14:45–15:34
UTC) — plausibly a transient record recreate that CoreDNS then cached wrong and
never recovered from on its own, for reasons not fully root-caused (not explainable
by the `cache 30` Corefile setting alone).

**Fix:** `kubectl -n kube-system rollout restart deploy/coredns`. Confirmed
resolution correct and stable immediately after.

**Lesson:** see [[coredns-oliver-stuck-cache]].

## Problem 2 — three interacting kopiur bugs

Once DNS was fixed, `ClusterRepository/garage-raspberrypi` still couldn't bootstrap.
Confirmed against `home-operations/kopiur` upstream issue tracker:

- **#231-class staleness**: `MaintenanceConfigured` condition only re-evaluates
  during initial bootstrap, then never again — ours had been stuck since
  2026-08-20.
- **#413** (open, filed 2026-08-27): the maintenance gate defers on any
  non-`Ready` repo, even one that's already-bootstrapped-but-degraded
  (`status.uniqueId` set) — exactly the repo that most needs maintenance to
  self-heal.
- **#414** (open, filed 2026-08-27): a hardcoded ~120s internal connect/probe
  deadline kills bootstrap, independent of the Job's own
  `spec.bootstrap.failurePolicy.activeDeadlineSeconds` (raising that field to
  600s had no effect — confirmed the pod still died at ~150s).

Deleting and recreating the `ClusterRepository` object (safe — kopiur's
create/connect is idempotent, never overwrites an existing repo; confirmed via
`docs/repositories.md`) did **not** help, because the real blocker was Problem 3.

**Lesson:** see [[kopiur-known-issues]].

## Problem 3 — real filesystem corruption on raspberrypi (the actual remaining blocker)

`/dev/sda2` (external HDD at `/mnt/nabil`, backing the `local-path-hdd`
StorageClass — the only PVC on it is garage's `data-garage-0`) hit SCSI command
timeouts and I/O errors independently, same day, ~17:22–18:01 CEST, and ext4
auto-remounted `emergency_ro` at 17:31:08 CEST. Unrelated to the DNS issue, just
badly-timed overlap. Garage's own logs showed `IO error: Read-only file system`
on WAL/object writes; CNPG's scheduled barman-cloud Postgres backups had also
been failing daily since 2026-08-23 for the same reason.

**Fix sequence:**
1. `kubectl -n storage scale statefulset garage --replicas=0` (only consumer of
   that StorageClass — confirmed via PVC list before touching anything).
2. `sudo umount /mnt/nabil && sudo fsck -y /dev/sda2` — recovered journal, fixed
   ~150 orphaned directory entries (all empty 4KB stubs, matching an
   `ext4_mkdir` mid-write in the kernel crash trace) into `lost+found`. ~14MB
   total, negligible against 2.4GB of real data — real data loss was minimal.
3. Remount, scale garage back to 1. Garage started clean.
4. One kopia manifest pack blob was still unreadable post-fix (confirmed via
   direct `kopia` CLI pods connected straight to garage, bypassing kopiur) — a
   genuine torn write from the crash, not recoverable (no redundancy, see
   [[garage-replication-factor-one]]). Deleted it directly, then:
   (raw blob deletion was done by the user directly via S3 client — easier and
   faster than going through a debug pod; the `kopia` CLI has no `blob delete`
   subcommand anyway, see takeaways below)
   - `kopia index recover --commit --dangerous-commands=enabled` — rebuilds the
     content index from whatever pack blobs still exist.
   - Still failed: a **separate, stale index blob**
     (`xn0_48559741...-sd05edeb785758913144-c1`) kept a dangling pointer to the
     deleted pack (kopia index blobs are additive/append-only, never
     auto-superseded). Identified it by the matching session-suffix in its
     name, deleted it too.
   - `kopia maintenance info` then succeeded cleanly.
5. `kubectl annotate clusterrepository garage-raspberrypi
   kopiur.home-operations.com/catalog-scan-requested-at=... ` +
   `kubectl -n storage rollout restart deploy/kopiur-controller` →
   `ClusterRepository` went `Ready=True` within a couple minutes.

## Cleanup once the repository was healthy

- All Flux Kustomizations self-resolved on oliver and raspberrypi (`flux get ks
  -A` clean on both).
- 5 backlogged scheduled `Snapshot`s (kanidm, ferdium, fb-quantum, forgejo,
  continuwuity — queued since the outage began) fired automatically and all
  **Succeeded**.
- jellyfin's `SnapshotPolicy` needed `media` added to
  `ClusterRepository.spec.allowedNamespaces` (separate, legitimate gap — pushed
  as `c8022af feat(kopiur): add media to allowed namespaces`), then blocked
  again on `PrivilegedMoverNotPermitted` (real security gate — jellyfin's mover
  needs elevated privileges the `media` namespace hadn't opted into). Fixed
  with `kubectl annotate namespace media
  kopiur.home-operations.com/privileged-movers=true`.
- Manual CNPG/barman-cloud Postgres backup triggered and **completed**
  successfully (see checking-commands below) — confirms the fix, though
  tomorrow's automatic 03:00 scheduled run is the real end-to-end confirmation
  that the *schedule* itself recovered, not just a manual poke.
- traefik on raspberrypi was a **separate, unrelated** issue found mid-incident:
  Renovate had bumped the HelmRelease to chart `41.4.0`, but the `HelmRepository`'s
  cached index was ~10h stale from before that publish. Fixed with `flux
  reconcile source helm traefik -n network` then `flux reconcile helmrelease
  traefik -n network`.

## Checking Postgres backup status going forward

```sh
# list backups and their phase (pending / started / running / completed / failed)
kubectl -n database get backup

# details + failure reason on a specific one
kubectl -n database get backup <name> -o yaml

# cluster-level view: continuous archiving + last backup outcome
kubectl -n database get cluster cnpg-cluster -o jsonpath='{.status.conditions}' | jq .
# look for: ContinuousArchiving=True, LastBackupSucceeded=True

# trigger a manual on-demand backup
cat <<'EOF' | kubectl -n database apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: cnpg-cluster-backup-manual-<date>
spec:
  cluster:
    name: cnpg-cluster
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
```

## Key takeaways

- `local-path` PVCs are just host directories — a StorageClass backed by an
  external/USB-attached HDD carries real, independent hardware-failure risk
  distinct from anything in the manifests.
- Symptoms at the top of a dependency chain (a stuck Flux Kustomization) can
  have multiple, unrelated causes stacked underneath — don't stop
  investigating at the first plausible-looking fix.
- kopiur's self-heal path for an already-degraded repository is currently
  broken (upstream, tracked). If `garage-raspberrypi` (or any `ClusterRepository`)
  gets stuck `Degraded` again with `Bootstrapped=False` and a mover pod that
  hangs then dies at ~120–150s regardless of `activeDeadlineSeconds`, don't
  assume it will self-heal — check upstream issue status first, then consider
  going around kopiur directly with the `kopia` CLI (same pattern as here:
  connect via a throwaway pod using `kopiur-garage-creds`, image
  `ghcr.io/home-operations/kopiur-mover` — no shell, so chain
  init-container-connect + main-container-command against a shared `emptyDir`).
- **If a raw blob ever needs deleting again, have the user do it directly** via
  their own S3 client (e.g. `mc rm`) rather than doing it through a debug pod —
  it's faster for them, and the `kopia` CLI has no `blob delete` subcommand to
  begin with (`kopia blob --help` only exposes `list`/`show`/`stats`), so a
  debug-pod route means either the raw S3 endpoint directly or some other
  client anyway. Same goes for stale index blobs (identify the name, hand it
  over, they delete it).
