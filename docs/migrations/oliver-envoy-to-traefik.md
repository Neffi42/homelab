# Migration: Envoy Gateway → Traefik on `oliver`

Goal: replace Envoy Gateway with Traefik as `oliver`'s Gateway API controller, matching
`raspberrypi`'s existing Traefik setup, while keeping the `public`/`private` Gateway split,
`iac/dns` automation, and every existing route working unchanged.

## Decisions already made (don't re-litigate)

- **Keep two `Gateway` objects** (`public`, `private`) — not one Gateway with two listeners.
  `iac/dns/locals.tf` buckets HTTPRoutes and reads the Tailscale IP by matching
  `Gateway.metadata.name`, not `sectionName`; merging would require rewriting that Terraform
  and adding explicit `sectionName` to every app's route, for zero actual resource savings
  (Traefik runs one shared instance regardless of how many `Gateway` objects reference it —
  unlike Envoy Gateway, which spins up a dedicated proxy Deployment *per* Gateway object).
- **pi-hole's DNS-over-UDP bypasses Gateway API entirely** — give it its own
  `type: LoadBalancer` Service instead of a `UDPRoute`. Traefik's Gateway API provider does
  not implement `UDPRoute`
  ([open issue, unresolved](https://github.com/traefik/traefik/issues/12322)). `LoadBalancer`
  on k3s is handled by the built-in ServiceLB/klipper mechanism — the same one already backing
  every Gateway-fronted Service today — so this is zero new moving parts, not a new component.

## What carries over unchanged

- **cert-manager**: same `Certificate` → `neffi-fr-tls` Secret → `certificateRefs` pattern.
  Not annotation/ACME-based, so fully controller-agnostic.
- **`iac/dns`**: reads `Gateway`/`HTTPRoute` by name and `spec.addresses` generically — no
  Terraform changes needed as long as the two Gateway objects keep the names `public`/`private`
  and the same `spec.addresses`.
- **Kanidm auth**: purely app-level OIDC, no gateway-layer auth policy exists today — nothing
  to port.
- **`BackendTLSPolicy`** (kanidm's backend mTLS): standard Gateway API resource, supported by
  Traefik since **3.6** (graduated from extended to standard support —
  [blog](https://traefik.io/blog/traefik-proxy-3-6-ramequin)). Verify the pinned chart's app
  version is ≥ 3.6 before relying on it.
- **Selector-based `allowedRoutes`** (forgejo's `ssh` listener, restricted to the `forgejo`
  namespace via `matchLabels`): this is core Gateway API, not an Envoy extension — any
  spec-conformant controller implements it identically
  ([Gateway API reference](https://gateway-api.sigs.k8s.io/reference/spec/#listener)).
- **`TCPRoute`** (forgejo ssh, pi-hole dns-tcp): supported by Traefik, gated behind a provider
  flag (see step 2).

## What's genuinely different — read before starting

- **Static entrypoints only.** Traefik does not auto-provision a listener for whatever port a
  `Gateway` object declares (Envoy Gateway does). Every port a `Gateway` listener uses must
  already exist as a named `entryPoint` in the Helm values, or that listener just errors.
  ([EntryPoints docs](https://doc.traefik.io/traefik/reference/install-configuration/entrypoints/))
- **One shared Traefik instance handles both `public` and `private`.** Envoy Gateway runs a
  separate proxy Deployment per `Gateway` object (process-level isolation between WAN-facing
  and Tailscale-only traffic); Traefik runs one process for everything, differentiated
  internally by entrypoint/port. Routing safety (a private-only route not reachable via the
  public port) is unaffected — that's enforced by the Gateway API attachment model
  (`parentRefs`), not by process separation. What you lose is blast-radius containment if the
  proxy *binary itself* is ever compromised. Acceptable trade for a single-box homelab; flagged
  here so it's a known choice, not a surprise.
- **No `UDPRoute` support** — see decision above.
- **CRDs**: `oliver` currently has no explicit `gateway-api-crds` Kustomization — Envoy
  Gateway's chart bundles the full CRD set implicitly. Gateway API **v1.6.0** (already pinned
  by the shared `apps/base/network/gateway-api-crds` component raspberrypi uses) graduated
  `TCPRoute`, `UDPRoute`, and `BackendTLSPolicy` to the **Standard** channel
  ([release notes](https://kubernetes.io/blog/2026/08/03/gateway-api-v1-6-release/)), so the
  existing `standard`-channel component is sufficient — no need for the experimental channel.

## Steps

### 1. Add the Gateway API CRDs dependency

Edit `apps/oliver/network/kustomization.yaml`: add `../../base/network/gateway-api-crds` as a
resource (mirrors `apps/raspberrypi/network/kustomization.yaml`).

### 2. New Traefik app tree: `apps/oliver/network/traefik/`

Oliver's values diverge enough from raspberrypi's (extra entrypoints, TCPRoute flag) that it
gets its **own** `HelmRelease` rather than patching the shared
`apps/base/network/traefik/helmRelease.yaml` — only the `HelmRepository` is reused.

```
apps/oliver/network/traefik/
  ks.yaml
  app/
    kustomization.yaml   # resources: ../../../../base/network/traefik/helmRepository.yaml, ./helmRelease.yaml
    helmRelease.yaml
  config/
    kustomization.yaml   # resources: ./certificate.yaml, ./gateways.yaml
    certificate.yaml      # unchanged copy of apps/oliver/network/envoy-gateway/config/certificate.yaml
    gateways.yaml
```

**`app/helmRelease.yaml`**:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: traefik
spec:
  interval: 10m
  chart:
    spec:
      chart: traefik
      version: "41.4.0" # match raspberrypi's current pin; Renovate tracks each HelmRelease independently
      sourceRef:
        kind: HelmRepository
        name: traefik
        namespace: network
  values:
    deployment:
      pod:
        nodeSelector:
          kubernetes.io/arch: amd64
    providers:
      kubernetesGateway:
        enabled: true
        experimentalChannel: true # required for TCPRoute; verify exact flag name against the pinned
        # chart's docs (https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-gateway/)
        # — naming/behavior has moved around between chart versions.
    gateway:
      enabled: false # don't let the chart auto-create its own Gateway/GatewayClass; we hand-author ours
    ports:
      # websecure (443) is a chart default already — covers the `private` Gateway's https listeners.
      websecure-public:
        port: 4443
        exposedPort: 4443
        expose:
          default: true
        protocol: TCP
      ssh:
        port: 2222
        exposedPort: 2222
        expose:
          default: true
        protocol: TCP
      dns-tcp:
        port: 53
        exposedPort: 53
        expose:
          default: true
        protocol: TCP
```

Port schema reference:
[traefik-helm-chart EXAMPLES.md](https://github.com/traefik/traefik-helm-chart/blob/master/EXAMPLES.md).

**`config/gateways.yaml`** — identical to today's
`apps/oliver/network/envoy-gateway/config/gateways.yaml`, minus the `dns-udp` listener (bypassed,
see decision above), with `gatewayClassName: eg` → `traefik`:

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: private
spec:
  gatewayClassName: traefik
  addresses:
    - type: IPAddress
      value: "100.110.121.73"
    - type: IPAddress
      value: "fd7a:115c:a1e0::6601:794f"
  listeners:
    - name: https
      hostname: "*.neffi.fr"
      protocol: HTTPS
      port: 443
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
          - name: "neffi-fr-tls"
    - name: https-base
      hostname: "neffi.fr"
      protocol: HTTPS
      port: 443
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
          - name: "neffi-fr-tls"
    - name: dns-tcp
      protocol: TCP
      port: 53
      allowedRoutes:
        namespaces:
          from: All
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: public
spec:
  gatewayClassName: traefik
  addresses:
    - type: IPAddress
      value: "192.168.1.42"
  listeners:
    - name: https
      hostname: "*.neffi.fr"
      protocol: HTTPS
      port: 4443
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
          - name: "neffi-fr-tls"
    - name: https-base
      hostname: "neffi.fr"
      protocol: HTTPS
      port: 4443
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
          - name: "neffi-fr-tls"
    - name: ssh
      protocol: TCP
      port: 2222
      allowedRoutes:
        kinds:
          - kind: TCPRoute
        namespaces:
          from: Selector
          selector:
            matchLabels:
              kubernetes.io/metadata.name: forgejo
```

**`ks.yaml`** — two Flux Kustomizations, same shape as the old `envoy-gateway/ks.yaml`, renamed,
with `gateway-api-crds` added as a dependency:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: traefik
spec:
  path: ./apps/oliver/network/traefik/app
  dependsOn:
    - name: cert-manager-config
    - name: gateway-api-crds
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: traefik
      namespace: network
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: traefik-config
spec:
  path: ./apps/oliver/network/traefik/config
  dependsOn:
    - name: cert-manager-config
    - name: traefik
  healthChecks:
    - apiVersion: gateway.networking.k8s.io/v1
      kind: Gateway
      name: public
      namespace: network
    - apiVersion: gateway.networking.k8s.io/v1
      kind: Gateway
      name: private
      namespace: network
```

### 3. pi-hole: bypass Gateway API for DNS-over-UDP

Edit `apps/oliver/network/pi-hole/app/helmRelease.yaml`:

- Remove the `UDPRoute`/`gatewayApi` block currently attaching the `dns-udp` Service to the
  `private` Gateway.
- Set that same Service's `type: LoadBalancer` directly.
- Leave the `dns-tcp` Service's `TCPRoute` → `private` Gateway (`dns-tcp` listener) as-is —
  Traefik supports `TCPRoute`.
- Leave the web UI `HTTPRoute` as-is.

### 4. Cutover (two commits, to avoid a Gateway-object ownership conflict)

`public`/`private` are singleton-named objects — Flux won't let two different Kustomizations
("envoy-gateway-config" and "traefik-config") both own `Gateway/public` at once. Do it in two
steps:

**Commit A** — land steps 1–3 above, but do **not** delete `envoy-gateway/` yet. This brings up
the Traefik `HelmRelease` (its own Kustomization, no Gateway objects involved) side-by-side with
the still-running Envoy Gateway. The `traefik-config` Kustomization will exist but fail to apply
(objects already owned elsewhere) — expected, harmless.

Verify before continuing:
```
kubectl -n network get pods -l app.kubernetes.io/name=traefik        # Running
kubectl get gatewayclass traefik                                     # Accepted
```

**Commit B** — delete `apps/oliver/network/envoy-gateway/` entirely (`app/`, `config/`,
`ks.yaml`) and drop its reference from `apps/oliver/network/kustomization.yaml`. This frees the
`Gateway` names; `traefik-config` then succeeds on its next reconcile. Force it rather than
waiting out the 1h default interval:
```
flux reconcile kustomization envoy-gateway-config -n flux-system   # prunes old Gateway objects
flux reconcile kustomization traefik-config -n flux-system         # creates new ones
```

This is a real, brief outage (Gateway objects don't exist for a few seconds to ~1 minute) — do
it in a low-traffic window.

### 5. Verify

- `kubectl -n network get gateway public private -o wide` — both `Programmed`, addresses match.
- `kubectl -n network get pods -l app.kubernetes.io/name=traefik` — `Running`.
- Every hostname still serves over its existing port (443 via Tailscale for `private` routes,
  4443 via LAN/WAN for `public` routes).
- **Isolation check** — a private-only route must 404 on the public port:
  ```
  curl -k --resolve jellyfin.neffi.fr:4443:192.168.1.42 https://jellyfin.neffi.fr:4443/
  ```
- pi-hole DNS, both protocols: `dig +tcp @<tailscale-ip> <name>` and `dig @<tailscale-ip> <name>`.
- forgejo ssh: `ssh -p 2222 git@code.neffi.fr` (or equivalent) — confirms `TCPRoute` +
  Selector-restricted `allowedRoutes` both work.
- kanidm login via `auth.neffi.fr` — confirms `BackendTLSPolicy` is honored (a broken
  backend-TLS handshake would surface as a gateway error here).
- `tofu -chdir=iac/dns plan` — expect **no diff**.

### 6. Cleanup

- `GatewayClass eg` and Envoy Gateway's CRDs (`EnvoyProxy`, `ClientTrafficPolicy`, etc.) were
  created out-of-band (not tracked in git) — Flux pruning the HelmRelease won't necessarily
  remove them. Check and remove manually:
  ```
  kubectl get gatewayclass eg
  kubectl get crd | grep envoyproxy.io
  ```

### Rollback

Revert both commits. Flux prunes the Traefik-owned `Gateway` objects and Envoy
Gateway's Kustomizations recreate `public`/`private` with `gatewayClassName: eg` again — same
brief outage, in reverse.

## Reference links

- [Traefik Kubernetes Gateway provider docs](https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-gateway/)
- [Traefik & Kubernetes Gateway API routing config](https://doc.traefik.io/traefik/reference/routing-configuration/kubernetes/gateway-api/)
- [Traefik EntryPoints docs](https://doc.traefik.io/traefik/reference/install-configuration/entrypoints/)
- [traefik-helm-chart EXAMPLES.md](https://github.com/traefik/traefik-helm-chart/blob/master/EXAMPLES.md)
- [Traefik Proxy 3.6 release notes (BackendTLSPolicy → standard)](https://traefik.io/blog/traefik-proxy-3-6-ramequin)
- [Traefik UDPRoute — open upstream issue](https://github.com/traefik/traefik/issues/12322)
- [Gateway API v1.6 release notes (TCPRoute/UDPRoute → standard channel)](https://kubernetes.io/blog/2026/08/03/gateway-api-v1-6-release/)
- [Gateway API release channels concept](https://gateway-api.sigs.k8s.io/concepts/versioning/#release-channels)
- [Gateway API Listener/allowedRoutes reference](https://gateway-api.sigs.k8s.io/reference/spec/#listener)
- [k3s networking services (ServiceLB)](https://docs.k3s.io/networking/networking-services)
