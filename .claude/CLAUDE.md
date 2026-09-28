# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## What this is

GitOps homelab config for one Flux-managed k3s cluster (`oliver`), spanning an amd64
control-plane node and an arm64 agent node (`raspberrypi`, tainted CI-only — see below), plus the
OpenTofu/Terraform that provisions things Flux can't (DNS records, Kanidm OAuth2 clients/groups).
There is no build/compile/test step — "correctness" means valid YAML/HCL that reconciles cleanly.

Git remote of record is this repo's own Forgejo instance (`code.neffi.fr`), which is itself one of
the workloads defined here (`apps/oliver/forgejo`). Standard git, no other VCS layered on top.

## Toolchain

Tool versions are pinned via `mise.toml` (mise-en-place) — run `mise install` once per checkout.
Key tools: `flux2`, `opentofu`, `kubectl`, `tofu-ls`, `yaml-language-server`, `kanidm_tools`, `flate`.
`KUBECONFIG` is set by mise's `[env]` block.

There is no linter/test runner in this repo. Validate changes by:
- `kubectl kustomize <dir>` — locally builds a `kustomization.yaml` to catch structural errors before pushing.
  Does **not** see a Flux `Kustomization`'s `spec.components`/`spec.patches`/`spec.postBuild` — those are
  applied by kustomize-controller on top of the plain `kustomize build`, so an app using `spec.components`
  (see `apps/components/` below) looks incomplete/wrong through this command alone.
- `flux build kustomization <name> --path <dir> --kustomization-file <ks.yaml> --dry-run` — the one that
  actually reflects `spec.components`/`postBuild.substitute`/`dependsOn`-aware output; required for anything
  wired through `apps/components/`, optional (but still useful) otherwise.
- `tofu -chdir=iac/<stack> validate` / `tofu -chdir=iac/<stack> plan` — for the two Terraform stacks.

YAML files carry `# yaml-language-server: $schema=...` comment headers pointing at
`schemas.neffi.fr` (custom, for CRDs like HelmRelease/OCIRepository/ExternalSecret/Gateway) or
`json.schemastore.org`/raw GitHub schemas (for kustomize/Flux Kustomization). Keep these headers
on new files of the same kind — they're what gives editors real completion/validation here.

## Repository layout

```
apps/
  oliver/<category>/<app>/     # the cluster's tree — covers both nodes; per-node scheduling
                                # (nodeSelector/tolerations) lives inside individual app manifests
  components/<name>/           # shared Kustomize Components (kind: Component), see below
flux/oliver/                   # flux-instance.yaml (the FluxInstance driving flux-operator)
                                # + apps.yaml, the root Kustomization pointing at ./apps/oliver
iac/<stack>/                   # OpenTofu stacks run manually, state in-cluster (see below)
k3s/oliver/config.yaml         # k3s server config (tls-san, disabled components) for the
                                # control-plane node, for reference
k3s/raspberrypi/config.yaml    # k3s agent config for the raspberrypi node, for reference
```

`flux/oliver/apps.yaml` is the single root `Kustomization` (path `./apps/oliver`) that Flux
reconciles from; it patches sane defaults (`interval: 1h`, `prune: true`, `wait: false`) onto every
child `Kustomization` found under that path, so per-app `ks.yaml` files don't need to repeat them.

### Flux itself (flux-operator, not `flux bootstrap`)

Flux is **not** bootstrapped — there is no `gotk-components.yaml`. `flux/oliver/flux-instance.yaml`
is a `FluxInstance` (`fluxcd.controlplane.io/v1`) reconciled by
[flux-operator](https://fluxoperator.dev), which renders the Flux components and generates the
`GitRepository/flux-system` + `Kustomization/flux-system` that `gotk-sync.yaml` used to define —
same names, so every app `ks.yaml`'s `sourceRef` keeps working. `spec.distribution.version` is the
single source of truth for the Flux version (Renovate tracks it via a custom regex manager against
`controlplaneio-fluxcd/distribution`); don't hand-bump controller images anywhere.

The operator itself is under GitOps at `apps/oliver/flux-system/flux-operator/` (OCIRepository +
HelmRelease, adopting the Helm release created at bootstrap time). Its status web UI is on the
`private` Gateway at `flux.neffi.fr`. That category deliberately has **no `namespace.yaml`** —
`flux-system` is part of the distribution manifests the operator owns.

Rebuilding the cluster from scratch is three manual steps, then git takes over:

1. `helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator -n flux-system --create-namespace`
2. create the `flux-system` Secret (Forgejo token) — **the one piece of state with no source of
   truth in this repo**, no `ExternalSecret` produces it:
   `flux-operator create secret basic-auth flux-system -n flux-system --username=git --password-stdin`
3. `kubectl apply -f flux/oliver/flux-instance.yaml`

### App directory pattern

Apps generally nest three levels under `apps/oliver/<category>/`:

```
<category>/<app>/
  namespace.yaml           # only when the app owns its own namespace
  kustomization.yaml       # kustomize resources: [./namespace.yaml, ./<app>/ks.yaml]
  <app>/
    ks.yaml                 # the Flux Kustomization: path -> ./<app>/app, dependsOn, healthChecks
    app/
      kustomization.yaml    # resources: helmRelease.yaml, ociRepository.yaml, externalSecret.yaml
      helmRelease.yaml       # chartRef -> OCIRepository (not HelmRepository, for OCI charts)
      ociRepository.yaml     # pinned chart tag; Renovate bumps this
      externalSecret.yaml    # pulls from Bitwarden Secrets Manager (see below), may be multi-doc
```

Some apps split `app/` (workload) from `config/` (CRs applied after, e.g. cert-manager's
ClusterIssuer, external-secrets' ClusterSecretStore) as two separate Flux Kustomizations with a
`dependsOn` between them — follow the existing app's split rather than inventing a new shape.

### Conventions to match

- `Kustomization` (kustomize) metadata has no `namespace:` at the kustomize level; namespacing is
  handled by the Flux `Kustomization`'s `spec.targetNamespace` and/or the manifest's own `metadata.namespace`.
- Flux `Kustomization.spec.dependsOn` encodes real startup ordering (e.g. `forgejo` depends on
  `local-path`, `cnpg-cluster`, `dragonfly`, `kanidm`) — check what an app actually needs at
  runtime and add dependencies rather than relying on retry/backoff.
- `Kustomization.spec.healthChecks` should point at the workload's own `HelmRelease` so Flux
  reports real readiness, not just "applied".
- Secrets are never inline. `ExternalSecret` resources pull from the `bitwarden-secretsmanager`
  `ClusterSecretStore` by opaque UUID `remoteRef.key`; there's no local mapping of UUID -> human
  label other than the secret's name in Bitwarden itself.
- HelmRelease uses `chartRef: {kind: OCIRepository, name: ...}` against a per-app `OCIRepository`
  pinned to a specific chart tag/digest — this is what Renovate's `flux`/`docker` managers bump
  (see `renovate.json`'s custom regex manager for the Forgejo image+digest pair specifically).
- Two Gateways exist cluster-wide: `public` (WAN-facing, ports 4443/2222 on the LAN IP) and
  `private` (Tailscale IP, port 443, also does port-53 DNS). New `HTTPRoute`/`TCPRoute` resources
  pick one of these via `parentRefs`, matching whether the service should be internet-reachable.
  Both run on Envoy Gateway — a cross-namespace `parentRefs` entry **must** set
  `namespace: network` explicitly, it does not default to the Gateway's namespace.
- **Node scheduling**: `raspberrypi` (the arm64 agent node) carries the taint
  `dedicated=slow-node:NoSchedule` — its SD card has almost no free space and its old HDD has a
  history of read-only-remount failures, so nothing PVC-backed should ever land there. PVC-less
  workloads opt in with a matching `toleration` plus a *preferred* nodeAffinity on
  `kubernetes.io/hostname In [raspberrypi]`, never a hard `nodeSelector`, so they fall back to
  oliver when the Pi is down. Deployments stay on oliver after a failover until they're restarted.
  Currently opted in: the Forgejo Actions runner and its job podspecs (`apps/oliver/forgejo-runner/`),
  Renovate, the external-secrets controller/cert-controller/bitwarden-sdk-server, the cert-manager
  controller/cainjector, reloader, sableclient, and plugin-barman-cloud. **Never** move admission
  webhooks (cert-manager, external-secrets, kopiur, cnpg-operator, whose webhook runs in-process)
  or anything on the ingress/recovery path (Envoy, Flux, CoreDNS) there: with `failurePolicy: Fail`,
  a flaky Pi would block API writes cluster-wide. Runner jobs land on arm64 normally and on amd64
  during a failover, so image builds need an explicit `--platform`. Everything without the
  toleration stays on oliver.
- Auth: Kanidm (`apps/oliver/auth/kanidm`) is the OIDC provider; app OAuth2 clients/groups are
  provisioned in `iac/oauth`, not in the app's own Kustomization — adding a new OIDC-integrated
  app means adding a `kanidm_oauth2_basic` + `kanidm_group` there too.
- Backups: kopiur (`apps/oliver/storage/kopiur`) backs up PVCs to the `hetzner-1` `ClusterRepository`
  (a Hetzner Storage Box over SFTP) — the sole backup target now; the earlier garage-on-raspberrypi
  repository was decommissioned after repeated HDD read-only-remount incidents. `oliver` has no CSI
  snapshot-controller/`VolumeSnapshotClass` (`local-path` only) — every `SnapshotPolicy` needs
  `copyMethod: Direct`. The mover's default UID (`65532`) frequently can't read an app's real data
  (rootless images running as `1000`, `0700`-permission dirs like SSH keys) — check the live pod's
  actual `securityContext` (container **and** pod level) before assuming
  `inheritSecurityContextFrom.pvcConsumer` alone works; it only inherits a UID the pod spec
  actually pins, not one baked into the image. Consuming a `ClusterRepository`'s credentials from
  another namespace needs `credentialProjection.enabled: true` on the consumer (`SnapshotPolicy`
  *and* `Restore` separately — it's per-object, not inherited).

### Reusable Kustomize Components (`apps/components/`)

Cross-cutting config that several apps need the same shape of (backups, auth sidecars, etc.) lives
as a `kind: Component` under `apps/components/<name>/`, parameterized with `${VAR:=default}`
placeholders. An app pulls one in via the **Flux `Kustomization`'s own `spec.components`** field
(not a `components:` line in the app's local `kustomization.yaml`) — paths there are relative to
`spec.path`, not to the `ks.yaml` file itself:

```yaml
spec:
  components:
    - ../../../../components/kopiur   # relative to spec.path, count ../ from there to apps/
  path: ./apps/oliver/<category>/<app>/app
  postBuild:
    substitute:
      APP: <app-name>              # placeholders resolve via postBuild.substitute, not kustomize vars
      KOPIUR_KEEPDAILY: "14"        # only the vars that differ from the component's own defaults
```

`spec.components` is an alpha/experimental Flux feature (may change without warning) but is what's
actually used here — prefer it over wiring a Component into the app's own `kustomization.yaml`.

`apps/components/kopiur` is the current example: `Restore` (passive `target.populator: {}`) +
`SnapshotPolicy` + `SnapshotSchedule` for backing up one PVC via kopiur (`apps/oliver/storage/kopiur`)
to the `hetzner-1` `ClusterRepository`. The app's own chart keeps owning its PVC normally
(`type: persistentVolumeClaim`, no `existingClaim`/`dataSourceRef`) — the `SnapshotPolicy` just
points `sources[].pvc.name` at it via `${KOPIUR_PVC:=${APP}}`.

**Deliberately does *not* include a PVC.** `rancher.io/local-path` — the only StorageClass on either
cluster — is not a populator-aware provisioner: it binds a PVC to an empty volume immediately,
racing straight past any `dataSourceRef`, before kopiur's `Restore` can finish writing its staging
volume and hand off. Kopiur detects this and fails the `Restore` (`PopulateHijacked`), but the app's
PVC is already bound empty by then — confirmed live on ferdium. The `dataSourceRef`/`existingClaim`
"deploy-or-restore" pattern (mortebrume's version, and this component's own earlier draft) **needs
a real CSI driver with `AnyVolumeDataSource` populator support** (e.g. their `zfs-pv`) — nothing on
oliver or raspberrypi provides that today. The `Restore` this component ships is inert on purpose:
nothing ever claims it, so it just sits `AwaitingClaim` forever (a documented-safe kopiur state) —
kept so a real populator-capable StorageClass, if one ever arrives, only needs a PVC with a matching
`dataSourceRef` added, not a new `Restore`. Don't reintroduce a `pvc.yaml` here without first
confirming the target StorageClass's provisioner actually implements populators.

## OpenTofu stacks (`iac/`)

Two independent stacks, each with its own state, run manually (not via an in-cluster controller —
the `terraform` namespace under `apps/oliver/terraform` just hosts the Kubernetes-secret state
backend):

- `iac/dns` — derives DNS records from live cluster state: reads `HTTPRoute` objects via the
  `kubernetes_resources` data source, buckets hostnames into public (OVH zone, `A` record to the
  WAN IP) vs private (Pi-hole) by which Gateway (`public`/`private`) they reference, plus a
  `manual_dns_entries` var for anything not backed by an HTTPRoute. The private target IP is
  **not** a var — it's read back from the live `Gateway` named `private` (`spec.addresses`) in the
  current `KUBECONFIG` context, oliver's own Tailscale IP; runs against a single cluster/context
  now (no per-cluster fan-out).
- `iac/oauth` — Kanidm persons/groups/OAuth2 clients (see above).

Run with `tofu -chdir=iac/<stack> plan|apply`; backend is `kubernetes` (`secret_suffix` = stack
name, `namespace = "terraform"`), so a working `KUBECONFIG` against the right cluster is required
before planning.

## Renovate

`renovate.json` scans `*.yaml`/`*.yaml.j2` for the `flux`, `helm-values`, and `kubernetes`
managers (so HelmRelease chart versions and OCIRepository tags are kept current automatically),
plus a custom regex manager for Forgejo's `tag`+`digest` pair specifically. Minor/patch/pin/digest
updates auto-merge; majors open a PR. Don't hand-bump versions that Renovate already tracks —
let it open the PR, or edit both `tag`/`digest` fields it expects if doing so manually.
