# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## What this is

GitOps homelab config for one Flux-managed k3s cluster (`oliver`), spanning an amd64
control-plane node and an arm64 agent node (`raspberrypi`, tainted CI-only — see below), plus the
OpenTofu that provisions things Flux can't (Kanidm OAuth2 clients/groups), applied in-cluster by
tofu-controller.
There is no build/compile/test step — "correctness" means valid YAML/HCL that reconciles cleanly.

Git remote of record is this repo's own Forgejo instance (`code.neffi.fr`), which is itself one of
the workloads defined here (`apps/oliver/forgejo`). Standard git, no other VCS layered on top.

## Toolchain

Tools come from the Nix flake dev shell (`flake.nix`, versions pinned by `flake.lock`): `nix develop`,
or automatically via direnv (`.envrc` is `use flake`; run `direnv allow` once per checkout). Bump with
`nix flake update`; `flate` is fetched from its GitHub release (not in nixpkgs), so bump its `version`
and hashes in `flake.nix` by hand. `KUBECONFIG`, `KUBE_CONFIG_PATH` and `KANIDM_URL` are set by the shell.

There is no linter/test runner in this repo. Validate changes by:
- `kubectl kustomize <dir>` — locally builds a `kustomization.yaml` to catch structural errors before pushing.
  Does **not** see a Flux `Kustomization`'s `spec.components`/`spec.patches`/`spec.postBuild` — those are
  applied by kustomize-controller on top of the plain `kustomize build`, so an app using `spec.components`
  (see `apps/components/` below) looks incomplete/wrong through this command alone.
- `flux build kustomization <name> --path <dir> --kustomization-file <ks.yaml> --dry-run` — the one that
  actually reflects `spec.components`/`postBuild.substitute`/`dependsOn`-aware output; required for anything
  wired through `apps/components/`, optional (but still useful) otherwise.
- `tofu -chdir=apps/oliver/tofu/tofu-controller/stacks/<stack> init -backend=false && tofu -chdir=… validate`
  — for the OpenTofu stacks. Never `apply` locally; see below. In the sandbox, provider plugins need an
  unsandboxed run (go-plugin listens on a unix socket in `$TMPDIR`).

YAML files carry `# yaml-language-server: $schema=...` comment headers pointing at
`schemas.neffi.fr` (custom, for CRDs like HelmRelease/OCIRepository/ExternalSecret/Gateway) or
`json.schemastore.org`/raw GitHub schemas (for kustomize/Flux Kustomization). Keep these headers
on new files of the same kind — they're what gives editors real completion/validation here.

## Repository layout

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

`sync.url` points at Forgejo's in-cluster Service (`forgejo-http.forgejo.svc:3000`), not
`code.neffi.fr`, so Flux can still pull a fix when the Gateways, Pi-hole DNS or the router's hairpin
NAT are broken.

Gateway API CRDs (experimental channel, needed for TCPRoute) are owned by
`apps/oliver/network/gateway-api/` (a `GitRepository` on `kubernetes-sigs/gateway-api`, Renovate-tracked
tag), not by the gateway controller's chart. They carry `kustomize.toolkit.fluxcd.io/prune: disabled`:
deleting a CRD deletes every Gateway and route of that kind. Don't bump the tag past the Gateway API
version the gateway controller supports.

The operator itself is under GitOps at `apps/oliver/flux-system/flux-operator/` (OCIRepository +
HelmRelease, adopting the Helm release created at bootstrap time). Its status web UI is on the
`private` Gateway at `flux.neffi.fr`, behind its built-in OIDC login (Kanidm client `flux`, `app_admins`
impersonated and bound to `flux-web-admin`). That category deliberately has **no `namespace.yaml`** —
`flux-system` is part of the distribution manifests the operator owns.

Rebuilding the cluster from scratch is three manual steps, then git takes over:

1. `helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator -n flux-system --create-namespace`
2. create the `flux-system` Secret (Forgejo token) — **the one piece of state with no source of
   truth in this repo**, no `ExternalSecret` produces it:
   `flux-operator create secret basic-auth flux-system -n flux-system --username=git --password-stdin`
3. `kubectl apply -f flux/oliver/flux-instance.yaml`

### App directory pattern

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
  `private` (LAN IP port 443, reached from the tailnet through oliver's `192.168.1.42/32` subnet
  route; also does port-53 DNS). New `HTTPRoute`/`TCPRoute` resources
  pick one of these via `parentRefs`, matching whether the service should be internet-reachable.
  Both run on one Traefik (`apps/oliver/network/traefik`, Gateways in its `config/`) — a
  cross-namespace `parentRefs` entry **must** set `namespace: network` explicitly, it does not default to the Gateway's namespace.
- Traefik specifics:
  - A Gateway listener's `port` is the Traefik entrypoint's **container** port, not the client-facing
    one. They're equal for every TCP entrypoint (443, 4443, 2222, 53, 8555); Traefik binds 443/53 as
    non-root via the pod sysctl `net.ipv4.ip_unprivileged_port_start=0`. Only the UDP entrypoints
    differ: the Service maps 53/udp→54 (`dns-udp`) and 8555/udp→8556 (`webrtc-udp`).
  - Exposure is the Traefik Service (`LoadBalancer` via k3s ServiceLB, so host ports on oliver, plus
    `externalIPs` for the Tailscale IP). `spec.addresses` on the Gateways is ignored by Traefik, and
    their `status.addresses` follow the Traefik Service (`statusaddress.service`), so DNS targets are
    pinned by the `external-dns.kubernetes.io/target` annotation on each Gateway instead (see DNS below).
  - Public/private separation is per entrypoint (`https-public` vs `https-private`) plus the router
    only forwarding 4443/2222. Traefik CRD routes without `entryPoints` land on `https-private` only
    (`asDefault`).
  - No Gateway API `UDPRoute` in Traefik: UDP (Pi-hole DNS, go2rtc WebRTC) uses `IngressRouteUDP`
    naming the `dns-udp`/`webrtc-udp` entrypoint. UDP entrypoints must not share a container port
    with any TCP listener (54/8556 vs 53/8555): the Gateway provider matches listeners to
    entrypoints by port only and can pick the UDP one.
  - Traefik features beyond Gateway API (ForwardAuth, …) are `traefik.io` `Middleware`s attached with
    an `ExtensionRef` filter on the HTTPRoute rule (same namespace as the route).
  - Dashboard: `traefik.neffi.fr` on `private` (HTTPRoute to `api@internal`, allowed by
    `crossProviderNamespaces: [network]`), behind the oauth2-proxy component on `traefik-config`.
- Auth on routes (lessons from the Envoy → Traefik switch, where files/firefox/cam were briefly
  served without auth):
  - When the auth mechanism changes, ship the route changes first (they fail closed on the old
    controller) and move the Gateways in a later step, never in the same reconcile.
  - Never rename a protected route in the change that adds or moves its auth: Helm creates the new
    route before deleting the old one, and for identical matches the oldest route wins, so the old
    unprotected one keeps serving until it's deleted.
  - Put the auth filter (`ExtensionRef` to the oauth2-proxy `Middleware`) on the catch-all rule and
    leave only `/oauth2/` unfiltered: a missing Middleware disables only its own rule in Traefik,
    and requests fall through to any broader rule.
- **Node scheduling**: `raspberrypi` (the arm64 agent node) carries the taint
  `dedicated=slow-node:NoSchedule` — its SD card has almost no free space and its old HDD has a
  history of read-only-remount failures, so nothing PVC-backed should ever land there. PVC-less
  workloads opt in with a matching `toleration` plus a *preferred* nodeAffinity on
  `kubernetes.io/hostname In [raspberrypi]`, never a hard `nodeSelector`, so they fall back to
  oliver when the Pi is down. Deployments stay on oliver after a failover until they're restarted.
  Currently opted in: the Forgejo Actions runner and its default job podspec (`apps/oliver/forgejo-runner/`;
  the `docker` dind podspec deliberately is not — image builds took 25+ min on the Pi),
  the external-secrets controller/cert-controller/bitwarden-sdk-server, the cert-manager
  controller/cainjector, reloader, element-web, plugin-barman-cloud, rclone-s3, mautrix-whatsapp,
  and the kopiur controller (not its webhook). The per-app oauth2-proxy pods (`apps/components/oauth2-proxy`)
  and Miniflux only carry the toleration, no preferred affinity: the scheduler picks either node. **Never** move admission
  webhooks (cert-manager, external-secrets, kopiur, cnpg-operator, whose webhook runs in-process)
  or anything on the ingress/recovery path (Traefik, Flux, CoreDNS) there: with `failurePolicy: Fail`,
  a flaky Pi would block API writes cluster-wide. Default runner jobs land on arm64 normally and on amd64
  during a failover; `docker` (dind) jobs always run on amd64 oliver, so image builds still need an
  explicit `--platform` for arm64 output. Everything without the
  toleration stays on oliver. CPU-heavy jobs don't belong on the Pi either: Renovate
  pinned a full core there and ran 4x+ longer than on oliver, so it was moved back.
- Auth: Kanidm (`apps/oliver/auth/kanidm`) is the OIDC provider; app OAuth2 clients/groups are
  provisioned in the `oauth` tofu stack, not in the app's own Kustomization — adding a new OIDC-integrated
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

`apps/components/oauth2-proxy` puts one oauth2-proxy (Deployment, Service, cookie secret from an
external-secrets `Password` generator) plus a Traefik ForwardAuth `Middleware` in front of an app,
using the app's own Kanidm client (`${APP}`, secret `${APP}-oauth-credentials`, callback
`https://<host>/oauth2/callback`). Authorization stays in Kanidm's `scope_map`. Needs
`OAUTH2_PROXY_HOST` and `OAUTH2_PROXY_NAMESPACE` substitutes and `dependsOn: traefik` (Middleware
CRD). The app's HTTPRoute must send `PathPrefix /oauth2/` to `${APP}-oauth2-proxy:4180` unfiltered and
put an `ExtensionRef` filter to the Middleware on its other rules.

## DNS (external-dns)

Records are derived from HTTPRoutes by two external-dns releases in `apps/oliver/network/external-dns`
(one per provider, both limited to `gateway-httproute` sources on one Gateway in `network`):

- `external-dns-ovh` — routes on `public` → OVH zone `neffi.fr`, target from the `public` Gateway's
  `external-dns.kubernetes.io/target` annotation (the WAN IP). TXT registry, owner `oliver`, prefix
  `_extdns-%{record_type}.` (keeps the apex's ownership record inside the zone: `_extdns-a.neffi.fr`).
  Records without an ownership TXT record (MX, SPF, …) are never touched. Credentials: cert-manager's
  `network/ovh-credentials` (OAuth2 client).
- `external-dns-pihole` — routes on `private` → Pi-hole local DNS, target `192.168.1.42` from the
  `private` Gateway's annotation. `registry: noop` (Pi-hole can't store TXT) with `policy: sync`: every
  `neffi.fr` A record in Pi-hole is owned by it, so a record added by hand in the Pi-hole UI gets deleted.
  It logs in once and reuses the session; don't put anything that logs in per request (the old
  `ryanwholey/pihole` tofu provider) back in front of Pi-hole: FTL rewrites its whole config on each
  write, so concurrent writes lose records, and parallel logins exhaust `webserver.api.max_sessions`
  (sessions survive a Pi-hole restart, `webserver.session.restore`).

A record not backed by an HTTPRoute would need a `DNSEndpoint`: the `crd` source and its CRD, neither set up today.

## OpenTofu stacks (tofu-controller)

[tofu-controller](https://github.com/flux-iac/tofu-controller) (`apps/oliver/tofu/tofu-controller`,
namespace `tofu`) applies each stack under `stacks/<name>` from a `Terraform` object in `config/`,
using the `flux-system` GitRepository as source:

- `oauth` — Kanidm persons/groups/OAuth2 clients (see above).
  Each client is also listed in `local.oauth2_basic_clients`, which writes its secret to Bitwarden
  Secrets Manager (`bitwarden_secret`, UUIDs in the `oauth2_client_secret_ids` output) for the
  app's `ExternalSecret`. The Kanidm provider only reads a client secret on create, so rotating means
  replacing the client; the `Terraform` CRD has no `-replace`, so that isn't wired up yet.

When it runs: a plan on every new `flux-system` revision (any commit, not just changes to the stack),
a drift-detection plan every `spec.interval` (1h), and on `reconcile.fluxcd.io/requestedAt`.
`approvePlan: auto` applies a plan with changes right away; without it the plan waits for
`approvePlan: <plan id>` (`status.plan.pending`). `spec.parallelism` only reaches `apply`: plans
always run at tofu's default parallelism, and the runner rejects `TF_CLI_ARGS_*`/`TF_VAR_*` env vars.

Inputs: `varsFrom` Secrets filled by ExternalSecrets in `config/` (values always arrive as strings:
use `jsondecode()` for anything structured). Only the `oauth` runner gets a Bitwarden token
(`tofu-bws`, write access to the project holding the client secrets); other stacks get plain
values from ESO. State: `kubernetes` backend, `tofu/tfstate-default-<secretSuffix>` (the backend
block in each stack is overridden by the controller's `backend_override.tf`). Runners only exist in
`tofu` (`namespacedRoleBindings: true`, so they can only read Secrets there).

Never run `tofu apply` locally — the controller is the only writer to state. To read a stored plan,
use the runner's OpenTofu version (`ghcr.io/flux-iac/tf-runner` bundles it; plan files don't load
across versions): `kubectl -n tofu get secret tfplan-default-<name> -o jsonpath='{.data.tfplan}' | base64 -d | gunzip > tfplan`.

## Renovate

Don't hand-bump versions that Renovate already tracks (`renovate.json`) — let it open the PR, or
edit both `tag`/`digest` fields it expects if doing so manually.
