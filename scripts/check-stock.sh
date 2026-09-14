#!/usr/bin/env bash
set -euo pipefail

WATCHES="${WATCHES:-watches.json}"
STATE_DIR="${STATE_DIR:-state}"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

: "${NTFY_TOPIC:?NTFY_TOPIC is not set}"

notify() {
  local title="$1" priority="$2" tags="$3" url="$4" body="$5"
  local -a headers=(-H "Title: ${title}" -H "Priority: ${priority}" -H "Tags: ${tags}")

  if [ -n "$url" ]; then
    headers+=(-H "Click: ${url}" -H "Actions: view, Open on wog.ch, ${url}")
    body="${body}"$'\n\n'"${url}"
  fi

  curl -sS --max-time 20 --retry 2 "${headers[@]}" -d "$body" \
    "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null
}

# Scheduled runs are best effort: GitHub silently drops occurrences rather than
# deferring them, so a green heartbeat alone does not prove the interval held.
schedule_health() {
  command -v gh >/dev/null 2>&1 || return 0
  [ -n "${GITHUB_REPOSITORY:-}" ] || return 0

  local stamps s count prev cur delta max=0
  mapfile -t stamps < <(
    gh run list --repo "$GITHUB_REPOSITORY" --workflow stock-watch \
      --created ">=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
      --limit 500 --json createdAt --jq '.[].createdAt' 2>/dev/null | sort
  )

  count=${#stamps[@]}
  [ "$count" -ge 2 ] || return 0

  prev=""
  for s in "${stamps[@]}"; do
    cur=$(date -u -d "$s" +%s)
    if [ -n "$prev" ]; then
      delta=$((cur - prev))
      [ "$delta" -gt "$max" ] && max=$delta
    fi
    prev=$cur
  done

  printf ' %s runs in the last 24h, longest gap %dh%02dm.' \
    "$count" "$((max / 3600))" "$(((max % 3600) / 60))"
}

emit() {
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  return 0
}

# Sets status/detail/price. Always returns 0: one unreachable shop must not
# abort the watches that follow it.
extract_microdata() {
  local url="$1" id="$2"
  local html markers raw parsed

  if ! html=$(curl -sSL --max-time 30 --retry 3 --retry-delay 5 -A "$UA" "$url" 2>&1); then
    detail="fetch failed: ${html}"
    return 0
  fi

  if ! grep -q "$id" <<<"$html"; then
    detail="fetch returned a page without product ${id} (redirect or error page)"
    return 0
  fi

  markers=$(grep -c 'itemprop="availability"' <<<"$html" || true)
  if [ "$markers" != "1" ]; then
    detail="expected exactly 1 availability marker, found ${markers} (page structure changed)"
    return 0
  fi

  raw=$(grep -o 'itemprop="availability"[^>]*' <<<"$html" | head -1)
  parsed=$(sed -n 's#.*schema\.org/\([A-Za-z]*\).*#\1#p' <<<"$raw")
  if [ -z "$parsed" ]; then
    detail="could not parse availability from: ${raw}"
    return 0
  fi

  status="$parsed"
  price=$(grep -o 'itemprop="price"[^>]*' <<<"$html" | head -1 |
          sed -n 's/.*content="\([^"]*\)".*/\1/p')
}

mkdir -p "$STATE_DIR"
now=$(date -u +%s)
live=0
changed_any=false
summary=()
changes=()

while IFS=$'\t' read -r id name url method deadline; do
  if [ "$now" -ge "$(date -u -d "$deadline" +%s)" ]; then
    summary+=("${name}: retired, deadline ${deadline} passed")
    continue
  fi
  live=$((live + 1))

  status="UNKNOWN"
  detail=""
  price=""
  case "$method" in
    microdata) extract_microdata "$url" "$id" ;;
    *) detail="no extraction strategy named '${method}'" ;;
  esac

  state_file="${STATE_DIR}/${id}.txt"
  prev=""
  if [ -f "$state_file" ]; then
    prev=$(tr -d '[:space:]' <"$state_file")
  fi

  echo "${id} ${name}: previous=${prev:-<none>} current=${status} ${detail}"
  summary+=("${name}: ${status}")

  if [ "$status" = "$prev" ]; then
    continue
  fi

  printf '%s\n' "$status" >"$state_file"
  changed_any=true
  changes+=("${id} ${prev:-none}->${status}")

  case "$status" in
    InStock|PreOrder|BackOrder|LimitedAvailability|OnlineOnly|InStoreOnly)
      notify "IN STOCK: ${name}" urgent "rotating_light,video_game" "$url" \
        "wog.ch now reports ${status} (was ${prev:-none}).${price:+ CHF ${price}.} Go buy it."
      ;;
    UNKNOWN)
      notify "Stock watcher is blind: ${name}" high "warning" "$url" \
        "Could not read availability. ${detail}"
      ;;
    *)
      notify "Status changed: ${name}" default "eyes" "$url" \
        "wog.ch went from ${prev:-none} to ${status}. Still not orderable."
      ;;
  esac
done < <(jq -r '.[] | [.id, .name, .url, .method, .deadline] | @tsv' "$WATCHES")

emit changed "$changed_any"
emit changes "$(IFS=', '; printf '%s' "${changes[*]-}")"
emit all_expired "$([ "$live" -eq 0 ] && echo true || echo false)"

if [ -n "${HEARTBEAT:-}" ] && [ "$live" -gt 0 ]; then
  notify "Still watching ${live} product(s)" low "hourglass_flowing_sand" "" \
    "$(printf '%s\n' "${summary[@]}")"$'\n'"Checked $(date -u '+%Y-%m-%d %H:%M')Z.$(schedule_health)"
fi
