# Migration: fold `raspberrypi` back into `oliver` as a second node

## Context

`raspberrypi` is currently its own standalone, single-node k3s cluster with its own Flux
install, bootstrapped from the same git repo/branch as `oliver`. It hosts almost nothing
load-bearing anymore: `garage` (its object-storage backup target) was already decommissioned in
favor of `hetzner-1`, its `network`/`security`/`terraform` trees exist only to support the one
real workload left — the Forgejo Actions runner (`apps/raspberrypi/forgejo-runner/`) — and its
own Traefik `Gateway/private` (`*.pi.neffi.fr`) has zero HTTPRoutes attached to it. There's no PVC
data anywhere on the Pi worth preserving. Given how little is actually there, the goal is to
dissolve `raspberrypi` as an independent cluster and rejoin the physical Pi to `oliver` as a plain
k3s agent node, while explicitly keeping the Forgejo runner alive and pinned to that hardware (the
Pi's SD card has almost no free space, so nothing that needs a PVC should ever land there).

**No ingress controller change is part of this migration.** `oliver` keeps Envoy Gateway as its
only Gateway API controller — Traefik is not installed on `oliver`. `raspberrypi`'s own Traefik
install is not carried over either — it's retired outright along with the rest of
`apps/raspberrypi/network/` (see below), since it has zero HTTPRoutes attached and the node
becomes a plain tainted CI-only agent with no ingress workload of its own. There is therefore no
compensating change needed for Pi-hole's DNS-over-UDP listener — Envoy Gateway on `oliver` already
handles that today and nothing about it changes.

## Execution model

Any command that runs directly on a node's host OS — not through `kubectl`/`flux`/`tofu` against
the cluster, but actually executed on the Pi or on `oliver`'s host (installing/uninstalling k3s,
`k3s-uninstall.sh`, the `curl | sh` k3s installer, checking `/var/lib/rancher/k3s/server/node-token`,
etc.) — is run by **you**, not by the assistant. The assistant's job in those steps is to hand you
the exact command(s) to paste in; it does not SSH in or execute them itself. Everything else
(git commits, `kubectl`/`flux`/`tofu` operations against a live `KUBECONFIG` context) is done by
the assistant as usual.

## Decisions already made (don't re-litigate)

- **The Pi rejoins as a plain k3s *agent*, keeping its hostname `raspberrypi`.** Its current k3s
  install is a standalone *server* (embedded SQLite, no join flags) — that role is destroyed, not
  merged. `k3s-uninstall.sh` on the Pi, then a fresh `k3s agent` install pointed at `oliver`'s LAN
  IP (`192.168.1.42:6443` — same LAN, no reason to hairpin through Tailscale for cluster traffic).
- **The Pi is tainted CI-only.** Because its SD card has almost no headroom and its old HDD
  (`/mnt/nabil/k3s`) has a documented history of read-only-remount failures
  (`docs/incidents/2026-09-03-garage-hdd-emergency-ro.md`), no workload should ever be scheduled
  there by accident — including via `oliver`'s untopology-restricted default `local-path`
  StorageClass, which today has no `allowedTopologies` and could otherwise bind anywhere. Fix: a
  node taint (`dedicated=raspberrypi-ci:NoSchedule`) baked into the agent's k3s config, with a
  matching `toleration` + `nodeSelector: {kubernetes.io/hostname: raspberrypi}` added *only* to the
  Forgejo runner controller pod and its two ephemeral job-pod templates (the only workloads that
  need no PVC). Nothing else gets the toleration, so nothing else can land there — this is a
  general convention, not a one-off hack: any future non-PVC workload could opt in the same way,
  but nothing does today.
- **`raspberrypi`'s own StorageClasses (`local-path-hdd`, `local-path-sd`) are dropped, not
  merged.** Nothing consumes them today (confirmed: `garage` was their only consumer and it's gone),
  and the taint above means no PVC-needing pod will ever be scheduled onto that node anyway, so
  carrying them forward would be dead weight. (This also incidentally fixes a pre-existing bug: both
  currently carry `storageclass.kubernetes.io/is-default-class: "true"` simultaneously.)
- **Tailscale on the Pi stays installed and joined** — it's host-level, unrelated to k3s/Flux, and
  just loses its one in-cluster consumer (the retired `Gateway/private` object). Kept for
  independent SSH/admin access to the Pi.
- **`*.pi.neffi.fr` is retired outright** — its `Gateway`, `Certificate`, and OVH DNS-01 credentials
  are deleted with the rest of `apps/raspberrypi/network/`; nothing serves that hostname today.
  Its Traefik install goes with it — not merged into `oliver`, per the Context note above.

## What carries over unchanged

- Forgejo runner's actual workload manifests (`helmRelease.yaml`, both podspec templates,
  `externalSecret.yaml`) — only their scheduling stanza changes (add toleration + nodeSelector) and
  their path moves from `apps/raspberrypi/forgejo-runner/` to `apps/oliver/forgejo-runner/`.
  `dependsOn: external-secrets-config` resolves identically on `oliver` (same Kustomization name
  exists there).
- `iac/oauth`, Renovate, `mise.toml` — none reference `raspberrypi`, nothing to change.
- `iac/dns`'s Terraform itself — it already reads `Gateway`/`HTTPRoute` generically by name/live
  `KUBECONFIG` context; no `.tf` changes needed. Only its CI wiring changes (below).

## Steps

### Phase 1 — Land the Forgejo runner's new home on `oliver` (git only, no node change yet)

1. Copy `apps/raspberrypi/forgejo-runner/` → `apps/oliver/forgejo-runner/` unchanged, except:
   - `ks.yaml`: `path` fields updated to `./apps/oliver/forgejo-runner/...`.
   - `app/helmRelease.yaml`: add to the `runner` controller's pod spec:
     ```yaml
     controllers:
       runner:
         pod:
           nodeSelector:
             kubernetes.io/hostname: raspberrypi
           tolerations:
             - key: dedicated
               operator: Equal
               value: raspberrypi-ci
               effect: NoSchedule
     ```
     (adjust the controller key to match whatever it's actually named in the existing chart values).
   - `app/resources/podspec-default.yaml` and `app/resources/podspec-dind.yaml`: add the same
     `nodeSelector`/`tolerations` block at the Pod-spec level (these are raw Pod templates consumed
     directly by the `k8s-plugin` sidecar, not app-template values — edit the YAML directly).
2. Add `apps/oliver/forgejo-runner/` to whatever aggregates `apps/oliver/*/kustomization.yaml`
   (check how other oliver categories are wired into `flux/oliver/apps.yaml`'s tree — likely nothing
   extra needed if Flux's root Kustomization already scans `./apps/oliver` broadly; confirm against
   an existing category's inclusion pattern).
3. Commit. This Kustomization will apply — the `HelmRelease`/`ExternalSecret` reconcile fine — but
   the actual pod stays `Pending` (no node named `raspberrypi` exists in `oliver`'s cluster yet).
   That's expected; the `healthChecks` timeout on this Kustomization will just show not-Ready until
   Phase 2 completes. Do **not** delete `apps/raspberrypi/forgejo-runner/` yet — the live raspberrypi
   cluster still needs its own working runner until the physical cutover in Phase 2.

### Phase 2 — Physical node cutover

Per the Execution model above: the assistant gives you the exact commands below; you run them
yourself on the Pi (and read the token off `oliver`'s host) — the assistant does not SSH in.

1. On the Pi: back up nothing — confirmed no PVC/live data exists under any workload there.
2. Stop and fully remove the Pi's standalone k3s server. Run on the Pi:
   ```sh
   sudo /usr/local/bin/k3s-uninstall.sh
   ```
   This wipes its embedded datastore, Flux install, and every resource that was ever applied to it
   — this *is* the raspberrypi cluster's teardown, no separate `flux uninstall` needed.
3. Create the new agent config, replacing `k3s/raspberrypi/config.yaml` with
   `k3s/oliver/agents/raspberrypi.yaml` (new file, "for reference" like the existing per-cluster
   configs — not itself auto-applied):
   ```yaml
   server: "https://192.168.1.42:6443"
   token: "<from oliver:/var/lib/rancher/k3s/server/node-token, out of band>"
   node-taint:
     - "dedicated=raspberrypi-ci:NoSchedule"
   ```
4. Fetch the join token. Run on `oliver`'s host:
   ```sh
   sudo cat /var/lib/rancher/k3s/server/node-token
   ```
5. Install the k3s agent, keeping the existing hostname `raspberrypi`. Run on the Pi (substitute
   the token from step 4):
   ```sh
   curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.42:6443 K3S_TOKEN=<token> sh -s - agent \
     --node-taint dedicated=raspberrypi-ci:NoSchedule
   ```
6. Verify: `kubectl --context oliver get nodes -o wide` shows `raspberrypi` `Ready`, and
   `kubectl --context oliver describe node raspberrypi` shows the taint.
7. Force Flux to reconcile: `flux --context oliver reconcile kustomization forgejo-runner -n flux-system`.
   Confirm the runner pod schedules onto `raspberrypi`:
   `kubectl --context oliver get pods -n forgejo-runner -o wide`.
8. Confirm CI actually works end-to-end: push a trivial commit and watch a `.forgejo/workflows/*`
   run (`runs-on: default`) complete successfully against the relocated runner.
9. Only once that's green: delete the old registration path — remove
   `apps/raspberrypi/forgejo-runner/` from git (it's about to be deleted wholesale in Phase 3 anyway,
   but it's already inert since the raspberrypi cluster no longer exists to run it).

### Phase 3 — Retire everything else `raspberrypi`-specific

Delete outright (all already confirmed unused beyond what moved in Phase 1-2):
- `apps/raspberrypi/` in its entirety (forgejo-runner already relocated; `network/` — Traefik,
  `Gateway/private`, `*.pi.neffi.fr` `Certificate`, OVH DNS-01 `ExternalSecret`; `security/` — its
  own `bitwarden-secretsmanager` `ClusterSecretStore`; `storage/` — `local-path-hdd`/`local-path-sd`
  per the decision above; `terraform/` — passthrough namespace only).
- `flux/raspberrypi/` (bootstrap output — identical Flux components to oliver's, only `path` differed).
- `k3s/raspberrypi/config.yaml` (superseded by `k3s/oliver/agents/raspberrypi.yaml` from Phase 2).

### Phase 4 — CI and DNS cleanup

1. **`.forgejo/workflows/dns.yml`: delete the entire `apply - raspberrypi` step.** This is the
   job step that runs `tofu -chdir=iac/dns apply` a second time against
   `secrets.KUBECONFIG_RASPBERRYPI` specifically so `iac/dns` can resolve that cluster's own
   `private` Gateway IP for Pi-hole. Once `raspberrypi` stops being its own cluster (Phase 2), that
   context no longer exists and this step would just fail — remove it outright so only
   `apply - oliver` remains in the `apply` job.
2. Remove the now-dead `KUBECONFIG_RASPBERRYPI` secret from the Forgejo repo's secrets (manual, via
   the Forgejo UI — not tracked in git).
3. Locally: remove the `raspberrypi` context from `~/.kube/config` (`kubectl config delete-context raspberrypi`,
   `kubectl config delete-cluster raspberrypi`, `kubectl config delete-user raspberrypi` as applicable).
4. Confirm no OVH zone record or Pi-hole entry still points at `*.pi.neffi.fr` — `iac/dns` never
   managed that hostname (no HTTPRoute ever existed for it), so this is just a manual sanity check,
   not a Terraform change.

### Phase 5 — Update `AGENTS.md` / `.claude/CLAUDE.md`

Rewrite the two-cluster framing to a single-cluster, two-node model:
- **What this is**: "two Flux-managed k3s clusters" → "one Flux-managed k3s cluster (`oliver`),
  spanning an amd64 control-plane node and an arm64 agent node (`raspberrypi`, tainted CI-only)".
- **Repository layout**: drop the `apps/<cluster>/` framing implying two peer clusters — now just
  `apps/oliver/<category>/<app>/` (mention `apps/base/` still exists for chart/CRD reuse, just no
  longer for cross-*cluster* reuse). Remove `flux/raspberrypi/` and `k3s/raspberrypi/` from the
  layout diagram; note `k3s/oliver/agents/raspberrypi.yaml` as the new per-node agent config location.
- **Gateway section**: drop "`raspberrypi` mirrors the `private` half only" — there's only one
  `private`/`public` Gateway pair now, both still on Envoy Gateway, unchanged (this migration never
  touches `oliver`'s ingress controller).
- **New bullet**: document the `dedicated=raspberrypi-ci:NoSchedule` taint convention — node
  `raspberrypi` only runs workloads that explicitly tolerate it and need no PVC (currently just the
  Forgejo runner); nothing else should ever be scheduled there given its SD card and the HDD's
  documented reliability history.
- `iac/dns` section: note it now runs against a single cluster/KUBECONFIG context.

## Verify

1. `kubectl --context oliver get nodes -o wide` — both nodes `Ready`, `raspberrypi` tainted.
2. `kubectl --context oliver get pods -n forgejo-runner -o wide` — scheduled on `raspberrypi`.
3. Trigger a real `.forgejo/workflows/*` run (including one that would use the `docker:` label, to
   exercise the DinD job-pod template) and confirm it completes on the relocated runner.
4. `flux --context oliver get kustomizations -A` — everything `Ready`, nothing referencing
   `raspberrypi` context/cluster remains.
5. `kubectl kustomize apps/oliver/forgejo-runner` and every other touched `apps/oliver/**` dir builds
   cleanly; `apps/raspberrypi` no longer exists.
6. `tofu -chdir=iac/dns plan` — clean, single-cluster.
7. Confirm no pod ever lands on `raspberrypi` without the CI toleration: try scheduling a throwaway
   unpinned test pod cluster-wide and confirm it never lands there (or just rely on the taint's
   guarantee and skip an active test).
8. `git grep -i raspberrypi` repo-wide — only expected hits remain (historical `docs/incidents/*.md`,
   the new `k3s/oliver/agents/raspberrypi.yaml`, and the taint/nodeSelector literals).
9. `kubectl --context oliver get gatewayclass,gateway -A` — Envoy Gateway is still the only
   Gateway API controller in the cluster; no Traefik resources exist anywhere.

## Rollback

This is a one-way physical migration once Phase 2 destroys the Pi's standalone k3s server. Rolling
back means re-provisioning `raspberrypi` as a fresh standalone k3s server and re-bootstrapping Flux
against `./flux/raspberrypi` (recoverable from git history if the tree is restored via `git revert`),
then reverting the git commits from Phases 1-5. Given how little state raspberrypi actually holds,
this is low-risk either direction — the only genuinely destructive, hard-to-reverse step is
Phase 2.2 (`k3s-uninstall.sh` on the Pi); everything else is git-revertible.
