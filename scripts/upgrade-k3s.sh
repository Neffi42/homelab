#!/usr/bin/env bash
# Upgrade k3s on both nodes to the current stable channel release.
# Server (oliver) first, then agent (raspberrypi). Needs ssh access + sudo on both,
# and a working KUBECONFIG (mise sets it).
set -euo pipefail

SERVER=oliver
AGENT=raspberrypi

# Resolve once so both nodes get the same version even if the channel moves mid-run.
VERSION=$(curl -fsS -o /dev/null -w '%{redirect_url}' https://update.k3s.io/v1-release/channels/stable)
VERSION=${VERSION##*/}
VERSION=${VERSION//%2B/+}
[[ $VERSION =~ ^v1\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || { echo "unexpected version: $VERSION" >&2; exit 1; }
echo "stable: $VERSION"

minor() { sed -E 's/^v1\.([0-9]+)\..*/\1/' <<<"$1"; }
node_version() { kubectl get node "$1" -o jsonpath='{.status.nodeInfo.kubeletVersion}'; }

upgrade() {
  local node=$1 role=$2 unit=$3 current
  current=$(node_version "$node")
  if [[ $current == "$VERSION" ]]; then
    echo "$node: already $VERSION"
    return
  fi
  # Kubernetes only supports upgrading one minor version at a time.
  if (( $(minor "$VERSION") - $(minor "$current") > 1 )); then
    echo "$node: $current -> $VERSION skips a minor version, upgrade through each minor manually" >&2
    exit 1
  fi
  echo "$node: $current -> $VERSION"
  # The installer rewrites the unit's .env file from K3S_* vars in its environment,
  # so source the existing one first or the agent loses its token.
  ssh -t "$node" "curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh && \
    sudo sh -c 'set -a; . /etc/systemd/system/$unit.service.env; set +a; \
    INSTALL_K3S_VERSION=$VERSION sh /tmp/k3s-install.sh $role' && \
    rm -f /tmp/k3s-install.sh"

  echo "$node: waiting for Ready on $VERSION"
  for _ in $(seq 60); do
    if [[ $(node_version "$node" 2>/dev/null) == "$VERSION" ]] &&
      kubectl wait --for=condition=Ready "node/$node" --timeout=5s >/dev/null 2>&1; then
      echo "$node: done"
      return
    fi
    sleep 5
  done
  echo "$node: not Ready on $VERSION after 5 min" >&2
  exit 1
}

upgrade "$SERVER" server k3s
upgrade "$AGENT" agent k3s-agent
kubectl get nodes -o wide
