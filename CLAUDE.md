# CLAUDE.md

Runbook for this repo. Read this before changing a watch or adding a new one.

## What this is

A GitHub Actions cron job that polls a product page and pushes an ntfy
notification when it comes back in stock. No server, no LLM in the hot path.

Currently watching one product: Nintendo Switch 2 "The Legend of Zelda:
Ocarina of Time Edition" on wog.ch.

## Layout

| File | Role |
|---|---|
| `scripts/check-stock.sh` | Fetch, extract status, compare to state, notify |
| `.github/workflows/stock-watch.yml` | Every 30 min, daily heartbeat, deadline self-disable |
| `.github/workflows/keepalive.yml` | Weekly commit so GitHub does not disable the schedule |
| `state.txt` | Last seen availability value; its git log is the status history |

## How detection works, and the trap

wog.ch exposes schema.org microdata in the product's Offer block:

```html
<link itemprop="availability" href="https://schema.org/Discontinued" />
```

There is exactly one `itemprop="availability"` on the page, which is why it is
reliable. The script treats any other count as a structure change and alerts
that the watcher went blind rather than failing silently.

**Do not match on visible text.** The page renders a legend of all eight
possible statuses ("currently sold out", "available from our stock", "not yet
released", ...) plus roughly 35 related products with their own status badges.
Grepping for "sold out" or "available" hits permanently and tells you nothing.
This mistake is easy to make and produces a watcher that looks fine and never
fires.

Availability values treated as buyable: `InStock`, `PreOrder`, `BackOrder`,
`LimitedAvailability`, `OnlineOnly`, `InStoreOnly`.

## Adding a new site to watch

The UI is not the work. The per-site extraction rule is the work. Do this in
order and do not skip step 1.

**1. Investigate the page before writing anything.**

```sh
curl -sSL --max-time 30 -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 \
  (KHTML, like Gecko) Chrome/124.0 Safari/537.36" -o /tmp/page.html \
  -w "HTTP %{http_code} size=%{size_download}\n" "<URL>"
```

Non-200, a tiny response, or a Cloudflare interstitial means plain curl will not
work and the site needs a headless browser. Say so rather than shipping a
watcher that is permanently blind.

**2. Find a clean signal**, in order of preference:

1. A JSON endpoint the page itself calls. Most reliable, check the network tab.
2. schema.org microdata (`itemprop="availability"`).
3. A stable CSS class or id on the status element.
4. Regex on the HTML. Last resort, brittle.

```sh
grep -o 'availability[^,}]*' /tmp/page.html | sort -u
grep -c 'itemprop="availability"' /tmp/page.html   # must be exactly 1
```

**3. Confirm the signal is unique.** Count occurrences. If a status string also
appears in a legend, a footer, a related-products grid or a tooltip, it is not
usable. This is the single most common failure.

**4. Confirm the status is not JS-injected.** If the value only appears in the
rendered DOM and not in the curl output, curl cannot see it.

**5. Only then wire it in.** For a second product on wog.ch, the existing
strategy works and only the constants change. For a different shop, add a new
extraction strategy.

## Going from one watch to several

`scripts/check-stock.sh` hardcodes `URL`, `PRODUCT_ID` and `PRODUCT_NAME` at the
top and keeps state in a single `state.txt`. For more than one watch, turn those
into a `watches.json` list with a per-entry strategy and give each entry its own
state key:

```json
{
  "name": "Zelda OoT Edition",
  "url": "https://www.wog.ch/...",
  "id": "256987",
  "method": "microdata",
  "unavailable_when": "Discontinued"
}
```

Keep the blind-detection behaviour per entry. One site breaking must not silence
the others.

Do not build a GitHub Pages UI for adding watches without re-reading the
constraints: Pages is static and cannot write to the repo, Pages on a private
repo needs GitHub Pro, and even then the published site is world-readable.
GitHub Issue Forms give a real mobile form with no credentials and work on a
private repo on the free plan.

## Changing the current watch

Edit the constants at the top of `scripts/check-stock.sh`. Reset `state.txt` to
the new page's current value in the same commit, otherwise the first run fires a
spurious transition alert.

## Operational constraints

**Actions quota.** The repo is private, so every run bills a full minute against
2000 min/month regardless of the job taking ~15 seconds. `*/30` is about 1440
min/month and fits. `*/15` is about 2880 and does not. Public repos are
unmetered. Do not raise the frequency without redoing this arithmetic.

**Cron is best effort.** GitHub delays scheduled runs under load, commonly 5 to
20 minutes, and can drop them. Treat the interval as a floor. `:00` and `:30`
are the most contended minutes; an offset like `7,37 * * * *` fares better.

**Deadline.** `DEADLINE` in `stock-watch.yml` is `2026-11-05T23:00:00Z`, which is
midnight on 6 November in Europe/Zurich. The first run past it notifies, then
disables both workflows. A guard alone would not do, because a skipped step still
starts the job and bills a minute. To resume, bump `DEADLINE` first, then
`gh workflow enable stock-watch keepalive`, otherwise the next run disables them
again.

**Keepalive.** GitHub disables scheduled workflows after 60 days without repo
activity. `state.txt` only gets committed on a status change, so a product that
stays unavailable would silently kill its own watcher. That is what the weekly
commit is for.

**Cron ignores DST.** The 06:05 UTC heartbeat is 08:05 local in summer and 07:05
in winter.

## Notifications

ntfy topic lives in the `NTFY_TOPIC` repo secret, never in the code. Every
notification carries a `Click` header, an `Actions` view button and the URL in
the body, so the page is reachable three ways.

| Condition | Priority |
|---|---|
| Became buyable | urgent |
| Fetch or parse broke | high |
| Status changed but still not orderable | default |
| Daily heartbeat | low, silent |

A failed ntfy POST does not fail the job. A green run is not proof a
notification arrived; check `gh run view --log` for the curl output.

## Testing

Run the real thing locally without touching repo state:

```sh
NTFY_TOPIC=<topic> STATE_FILE=/tmp/s.txt bash scripts/check-stock.sh
NTFY_TOPIC=<topic> STATE_FILE=/tmp/s.txt HEARTBEAT=1 bash scripts/check-stock.sh
```

Seed `/tmp/s.txt` with a wrong value to exercise the transition path. Trace with
`bash -x` to confirm the curl fires. Note that ntfy publish returns HTTP 200 with
the message echoed back, but anonymous topics cannot be polled back, so read the
publish response rather than trying to fetch the message.

Force a run:

```sh
gh workflow run stock-watch                     # normal check
gh workflow run stock-watch -f heartbeat=true   # forces a ping
```

## Environment

Repo lives on the Windows drive under WSL (`/mnt/c/NOT_WORK/watcher`). DrvFs
cannot store exec bits and git sets `core.fileMode=false`, so `chmod +x` is
discarded and scripts land as mode `100644`, which fails on the runner with exit
126. Workflows therefore invoke scripts as `bash ./scripts/foo.sh`. To set the
bit properly use `git update-index --chmod=+x <file>`. Never set
`core.fileMode true` here; it flags the whole tree executable.
