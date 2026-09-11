#!/usr/bin/env bash
set -euo pipefail

URL="https://www.wog.ch/en/index.cfm/details/product/256987-Nintendo-Switch-2-The-Legend-of-Zelda-Ocarina-of-Time-Edition"
PRODUCT_ID="256987"
PRODUCT_NAME="Switch 2 - Zelda: Ocarina of Time Edition"
STATE_FILE="${STATE_FILE:-state.txt}"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

: "${NTFY_TOPIC:?NTFY_TOPIC is not set}"

notify() {
  local title="$1" priority="$2" tags="$3" body="$4"
  curl -sS --max-time 20 --retry 2 \
    -H "Title: ${title}" \
    -H "Priority: ${priority}" \
    -H "Tags: ${tags}" \
    -H "Click: ${URL}" \
    -H "Actions: view, Open on wog.ch, ${URL}" \
    -d "${body}"$'\n\n'"${URL}" \
    "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null
}

emit() {
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  return 0
}

status="UNKNOWN"
detail=""

if ! html=$(curl -sSL --max-time 30 --retry 3 --retry-delay 5 -A "$UA" "$URL" 2>&1); then
  detail="fetch failed: ${html}"
elif ! grep -q "$PRODUCT_ID" <<<"$html"; then
  detail="fetch returned a page without product ${PRODUCT_ID} (redirect or error page)"
else
  occurrences=$(grep -c 'itemprop="availability"' <<<"$html" || true)
  if [ "$occurrences" != "1" ]; then
    detail="expected exactly 1 availability marker, found ${occurrences} (page structure changed)"
  else
    raw=$(grep -o 'itemprop="availability"[^>]*' <<<"$html" | head -1)
    parsed=$(sed -n 's#.*schema\.org/\([A-Za-z]*\).*#\1#p' <<<"$raw")
    if [ -z "$parsed" ]; then
      detail="could not parse availability from: ${raw}"
    else
      status="$parsed"
    fi
  fi
fi

prev=""
[ -f "$STATE_FILE" ] && prev=$(tr -d '[:space:]' <"$STATE_FILE")

echo "previous=${prev:-<none>} current=${status} ${detail}"
emit status "$status"
emit prev "$prev"

if [ "$status" = "$prev" ]; then
  emit changed false
  if [ -n "${HEARTBEAT:-}" ]; then
    notify "Still watching: ${PRODUCT_NAME}" low "hourglass_flowing_sand" \
      "No change. wog.ch still reports ${status}. Checked $(date -u '+%Y-%m-%d %H:%M')Z."
  fi
  exit 0
fi

printf '%s\n' "$status" >"$STATE_FILE"
emit changed true

case "$status" in
  InStock|PreOrder|BackOrder|LimitedAvailability|OnlineOnly|InStoreOnly)
    notify "IN STOCK: ${PRODUCT_NAME}" urgent "rotating_light,video_game" \
      "wog.ch now reports ${status} (was ${prev:-none}). CHF 499.00. Go buy it."
    ;;
  UNKNOWN)
    notify "Stock watcher is blind" high "warning" \
      "Could not read availability for ${PRODUCT_NAME}. ${detail}"
    ;;
  *)
    notify "Status changed: ${PRODUCT_NAME}" default "eyes" \
      "wog.ch went from ${prev:-none} to ${status}. Still not orderable."
    ;;
esac
