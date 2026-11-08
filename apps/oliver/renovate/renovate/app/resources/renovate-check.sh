#!/bin/sh
# Posts to Matrix when Renovate hasn't merged a PR for MAX_AGE_DAYS: its CronJob exits 0
# even when every push fails, so the job status alone never alerts.
set -eu

last=$(curl -fsS "$FORGEJO_URL/api/v1/repos/$REPO/pulls?state=closed&poster=$BOT&sort=recentupdate&limit=20" \
  | grep -o '"merged_at":"[^"]*"' | cut -d'"' -f4 | sort -r | head -n1) || last=""

if [ -z "$last" ]; then
  msg="could not find a merged $BOT PR on $REPO"
else
  age=$(( ($(date -u +%s) - $(date -u -D '%Y-%m-%dT%H:%M:%SZ' -d "$last" +%s)) / 86400 ))
  if [ "$age" -lt "$MAX_AGE_DAYS" ]; then
    echo "last merge $last (${age}d ago), ok"
    exit 0
  fi
  msg="no PR merged for ${age} days (last: $last), check the renovate job logs for 'Error updating branch'"
fi
echo "$msg"

room=$(printf '%s' "$MATRIX_ROOM" | sed 's/!/%21/; s/:/%3A/')
curl -fsS -X PUT \
  -H "Authorization: Bearer $MATRIX_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"msgtype\":\"m.text\",\"body\":\"[renovate] $msg\"}" \
  "$MATRIX_ADDRESS/_matrix/client/v3/rooms/$room/send/m.room.message/renovate-check-$(date +%s)"
