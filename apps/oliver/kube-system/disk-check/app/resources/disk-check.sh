#!/bin/sh
# Posts to Matrix when a host filesystem of this node is above THRESHOLD% or mounted read-only.
set -eu

alerts=""

# Real block filesystems from the host mount table, one entry per device, skipping
# kubelet/runtime bind mounts.
mounts=$(awk '$3 ~ /^(ext[234]|xfs|btrfs|f2fs|vfat|exfat)$/ && $2 !~ /^\/(run|var\/lib\/kubelet|snap)(\/|$)/ && !seen[$1]++ { print $2, $4 }' /host/proc/1/mounts)

while read -r mp opts; do
  case ",$opts," in
    *,ro,*) alerts="$alerts\\n- $mp is mounted read-only" ;;
  esac
  usage=$(df -P "/host/root$mp" 2>/dev/null | awk 'NR == 2 { sub("%", "", $5); printf "%s %.1f", $5, $4 / 1048576 }')
  if [ -z "$usage" ]; then
    alerts="$alerts\\n- $mp could not be checked"
    continue
  fi
  pct=${usage% *}
  if [ "$pct" -ge "$THRESHOLD" ]; then
    alerts="$alerts\\n- $mp is $pct% full (${usage#* } GiB free)"
  fi
done <<MOUNTS
$mounts
MOUNTS

if [ -z "$alerts" ]; then
  echo "all filesystems ok"
  exit 0
fi
printf '%b\n' "$alerts"

room=$(printf '%s' "$MATRIX_ROOM" | sed 's/!/%21/; s/:/%3A/')
curl -fsS -X PUT \
  -H "Authorization: Bearer $MATRIX_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"msgtype\":\"m.text\",\"body\":\"[$NODE_NAME] disk check:$alerts\"}" \
  "$MATRIX_ADDRESS/_matrix/client/v3/rooms/$room/send/m.room.message/disk-check-$NODE_NAME-$(date +%s)"
