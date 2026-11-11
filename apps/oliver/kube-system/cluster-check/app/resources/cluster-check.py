#!/usr/bin/env python3
# Posts to Matrix when cluster state the Flux Alert can't see is unhealthy: ExternalSecrets,
# Certificates, Helm sources/releases (outside flux-system), kopiur snapshots, CNPG backups,
# crashing pods and failed Jobs. Stays quiet when everything is fine.
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

SA = "/var/run/secrets/kubernetes.io/serviceaccount"
API = f"https://{os.environ['KUBERNETES_SERVICE_HOST']}:{os.environ['KUBERNETES_SERVICE_PORT']}"
NOW = datetime.now(timezone.utc)
# Not-ready conditions younger than this are ignored (upgrades, rollouts, retries in flight).
GRACE = timedelta(minutes=int(os.environ["GRACE_MINUTES"]))
# Restarts and Job failures older than this were already reported by a previous run.
LOOKBACK = timedelta(minutes=int(os.environ["LOOKBACK_MINUTES"]))
SNAPSHOT_MAX_AGE = timedelta(hours=int(os.environ["SNAPSHOT_MAX_HOURS"]))
MAX_LINES = 40

BAD_WAITING = {
    "CrashLoopBackOff",
    "ImagePullBackOff",
    "ErrImagePull",
    "CreateContainerConfigError",
    "CreateContainerError",
    "InvalidImageName",
}

with open(f"{SA}/token") as f:
    TOKEN = f.read().strip()
CTX = ssl.create_default_context(cafile=f"{SA}/ca.crt")

issues = []


def ts(value):
    return datetime.fromisoformat(value) if value else None


def ref(obj):
    meta = obj["metadata"]
    ns = meta.get("namespace")
    return f"{obj['kind']} {ns}/{meta['name']}" if ns else f"{obj['kind']} {meta['name']}"


def items(path, kind):
    req = urllib.request.Request(f"{API}{path}", headers={"Authorization": f"Bearer {TOKEN}"})
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=30) as resp:
            objs = json.load(resp)["items"]
    except (urllib.error.URLError, OSError, ValueError) as err:
        issues.append(f"could not list {kind}: {err}")
        return []
    for obj in objs:
        obj["kind"] = kind
    return objs


def condition(obj, ctype):
    for cond in obj.get("status", {}).get("conditions") or []:
        if cond.get("type") == ctype:
            return cond
    return None


def check_condition(obj, ctype="Ready", required=True):
    cond = condition(obj, ctype)
    if cond is None:
        created = ts(obj["metadata"]["creationTimestamp"])
        if required and NOW - created > GRACE:
            issues.append(f"{ref(obj)}: no {ctype} condition")
        return
    if cond.get("status") == "True":
        return
    since = ts(cond.get("lastTransitionTime")) or NOW
    if NOW - since > GRACE:
        msg = (cond.get("message") or cond.get("reason") or "").splitlines()[0][:200]
        issues.append(f"{ref(obj)}: {ctype}={cond.get('status')} for {age(since)}: {msg}")


def age(since):
    mins = int((NOW - since).total_seconds() // 60)
    return f"{mins // 60}h{mins % 60:02d}m" if mins >= 60 else f"{mins}m"


for path, kind in [
    ("/apis/external-secrets.io/v1/externalsecrets", "ExternalSecret"),
    ("/apis/external-secrets.io/v1/clustersecretstores", "ClusterSecretStore"),
    ("/apis/helm.toolkit.fluxcd.io/v2/helmreleases", "HelmRelease"),
    ("/apis/source.toolkit.fluxcd.io/v1/ocirepositories", "OCIRepository"),
    ("/apis/source.toolkit.fluxcd.io/v1/helmrepositories", "HelmRepository"),
]:
    for obj in items(path, kind):
        spec = obj.get("spec", {})
        # type: oci HelmRepositories are static in Flux and never get a Ready condition.
        if spec.get("suspend") or (kind == "HelmRepository" and spec.get("type") == "oci"):
            continue
        check_condition(obj)

for cert in items("/apis/cert-manager.io/v1/certificates", "Certificate"):
    check_condition(cert)
    renewal = ts(cert.get("status", {}).get("renewalTime"))
    if renewal and NOW - renewal > GRACE:
        issues.append(f"{ref(cert)}: renewal overdue since {age(renewal)} (expires {cert['status'].get('notAfter')})")

for policy in items("/apis/kopiur.home-operations.com/v1alpha1/snapshotpolicies", "SnapshotPolicy"):
    if policy.get("spec", {}).get("suspend"):
        continue
    check_condition(policy)
    last = ts(policy.get("status", {}).get("lastSuccessfulSnapshot"))
    created = ts(policy["metadata"]["creationTimestamp"])
    if last is None and NOW - created > SNAPSHOT_MAX_AGE:
        issues.append(f"{ref(policy)}: no successful snapshot yet")
    elif last and NOW - last > SNAPSHOT_MAX_AGE:
        issues.append(f"{ref(policy)}: last successful snapshot {age(last)} ago")

for cluster in items("/apis/postgresql.cnpg.io/v1/clusters", "Cluster"):
    check_condition(cluster)
    # Only present once archiving/backups are configured, so absence isn't an issue.
    check_condition(cluster, "ContinuousArchiving", required=False)
    check_condition(cluster, "LastBackupSucceeded", required=False)

for pod in items("/api/v1/pods", "Pod"):
    owners = {o.get("kind") for o in pod["metadata"].get("ownerReferences") or []}
    status = pod.get("status", {})
    statuses = (status.get("initContainerStatuses") or []) + (status.get("containerStatuses") or [])
    for cs in statuses:
        waiting = (cs.get("state") or {}).get("waiting") or {}
        if waiting.get("reason") in BAD_WAITING:
            issues.append(f"{ref(pod)} [{cs['name']}]: {waiting['reason']} (restarts={cs.get('restartCount', 0)})")
            continue
        # Job pods are covered by the Job check below.
        if "Job" in owners:
            continue
        term = (cs.get("lastState") or {}).get("terminated") or {}
        finished = ts(term.get("finishedAt"))
        if finished and NOW - finished < LOOKBACK:
            issues.append(f"{ref(pod)} [{cs['name']}]: restarted {age(finished)} ago ({term.get('reason')}, exit {term.get('exitCode')})")
    created = ts(pod["metadata"]["creationTimestamp"])
    if status.get("phase") == "Pending" and NOW - created > GRACE:
        issues.append(f"{ref(pod)}: Pending for {age(created)}")

for job in items("/apis/batch/v1/jobs", "Job"):
    failed = condition(job, "Failed")
    if failed and failed.get("status") == "True":
        since = ts(failed.get("lastTransitionTime"))
        if since and NOW - since < LOOKBACK:
            issues.append(f"{ref(job)}: failed {age(since)} ago: {failed.get('reason')}: {(failed.get('message') or '')[:200]}")

if not issues:
    print("all checks ok")
    sys.exit(0)

lines = issues[:MAX_LINES]
if len(issues) > MAX_LINES:
    lines.append(f"... and {len(issues) - MAX_LINES} more, see the cluster-check job logs")
print("\n".join(issues))

body = f"[cluster-check] {len(issues)} issue(s):\n" + "\n".join(f"- {line}" for line in lines)
room = urllib.parse.quote(os.environ["MATRIX_ROOM"], safe="")
url = f"{os.environ['MATRIX_ADDRESS']}/_matrix/client/v3/rooms/{room}/send/m.room.message/cluster-check-{int(time.time())}"
req = urllib.request.Request(
    url,
    data=json.dumps({"msgtype": "m.text", "body": body}).encode(),
    headers={"Authorization": f"Bearer {os.environ['MATRIX_TOKEN']}", "Content-Type": "application/json"},
    method="PUT",
)
with urllib.request.urlopen(req, timeout=30) as resp:
    print(f"posted to matrix: HTTP {resp.status}")
