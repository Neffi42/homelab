# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## What this is

GitOps homelab config for two Flux-managed k3s clusters (`oliver`, `raspberrypi`), plus the
OpenTofu/Terraform that provisions things Flux can't (DNS records, Kanidm OAuth2 clients/groups).
There is no build/compile/test step — "correctness" means valid YAML/HCL that reconciles cleanly.

Git remote of record is this repo's own Forgejo instance (`code.neffi.fr`), which is itself one of
the workloads defined here (`apps/oliver/forgejo`). The working copy is a colocated `jj` (Jujutsu)
repo on top of git — either `git` or `jj` commands work; check `jj status`/`git status` before
assuming which was used last.

## Toolchain

Tool versions are pinned via `mise.toml` (mise-en-place) — run `mise install` once per checkout.
Key tools: `flux2`, `opentofu`, `kubectl`, `tofu-ls`, `yaml-language-server`, `kanidm_tools`, `flate`.
`KUBECONFIG` is set by mise's `[env]` block.

There is no linter/test runner in this repo. Validate changes by:
- `kubectl kustomize <dir>` — locally builds a `kustomization.yaml` to catch structural errors before pushing.
- `flux build kustomization <name> --path <dir> ...` — dry-run a Flux Kustomization against the cluster.
- `tofu -chdir=iac/<stack> validate` / `tofu -chdir=iac/<stack> plan` — for the two Terraform stacks.

YAML files carry `# yaml-language-server: $schema=...` comment headers pointing at
`schemas.neffi.fr` (custom, for CRDs like HelmRelease/OCIRepository/ExternalSecret/Gateway) or
`json.schemastore.org`/raw GitHub schemas (for kustomize/Flux Kustomization). Keep these headers
on new files of the same kind — they're what gives editors real completion/validation here.

## Repository layout

```
apps/
  base/<category>/<app>/       # cluster-agnostic manifests, referenced by overlays
  oliver/<category>/<app>/     # the "oliver" cluster's tree
  raspberrypi/<category>/<app>/ # the "raspberrypi" cluster's tree
flux/<cluster>/                # Flux bootstrap output (gotk-*.yaml, generated — don't hand-edit)
                                # + apps.yaml, the root Kustomization pointing at ./apps/<cluster>
iac/<stack>/                   # OpenTofu stacks run manually, state in-cluster (see below)
k3s/<cluster>/config.yaml      # k3s server config (tls-san, disabled components) for reference
```

Each cluster's `flux/<cluster>/apps.yaml` is the single root `Kustomization` (path `./apps/<cluster>`)
that Flux reconciles from; it patches sane defaults (`interval: 1h`, `prune: true`, `wait: false`)
onto every child `Kustomization` found under that path, so per-app `ks.yaml` files don't need to
repeat them.

### App directory pattern

Apps generally nest three levels under `apps/<cluster>/<category>/`:

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

Cluster overlays that just consume a `base/` app instead of defining their own reference it via
relative path, e.g. `apps/oliver/storage/local-path/kustomization.yaml` → `../../../base/storage/local-path`.
When adding a shared component, put the cluster-agnostic bits in `apps/base/...` and have each
cluster's `kustomization.yaml` pull it in; cluster-specific values (storage class, hostnames,
addresses) stay in that cluster's own overlay/HelmRelease.

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
- Two Gateways exist cluster-wide on `oliver`: `public` (WAN-facing, ports 4443/2222 on the LAN
  IP) and `private` (Tailscale IP, port 443, also does port-53 DNS). New `HTTPRoute`/`TCPRoute`
  resources pick one of these via `parentRefs`, matching whether the service should be internet-
  reachable.
- Auth: Kanidm (`apps/oliver/auth/kanidm`) is the OIDC provider; app OAuth2 clients/groups are
  provisioned in `iac/oauth`, not in the app's own Kustomization — adding a new OIDC-integrated
  app means adding a `kanidm_oauth2_basic` + `kanidm_group` there too.

## OpenTofu stacks (`iac/`)

Two independent stacks, each with its own state, run manually (not via an in-cluster controller —
the `terraform` namespace under `apps/base/terraform` just hosts the Kubernetes-secret state
backend):

- `iac/dns` — derives DNS records from live cluster state: reads `HTTPRoute` objects via the
  `kubernetes_resources` data source, buckets hostnames into public (OVH zone, `A` record to the
  WAN IP) vs private (Pi-hole, LAN IP) by which Gateway (`public`/`private`) they reference, plus
  a `manual_dns_entries` var for anything not backed by an HTTPRoute.
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
