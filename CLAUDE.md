# CLAUDE.md

Runbook for this repo. Read this before changing a watch or adding a new one.

## What this is

A GitHub Actions cron job that polls a product page and pushes an ntfy
notification when it comes back in stock. No server, no LLM in the hot path.

Watches are listed in `watches.json`. Currently three, all on wog.ch: the
Nintendo Switch 2 "The Legend of Zelda: Ocarina of Time Edition" and the Pokemon
30th Celebration Ultra-Premium Collections, Day and Night.

## Layout

| File | Role |
|---|---|
| `watches.json` | The watch list: id, name, url, method, deadline per entry |
| `scripts/check-stock.sh` | Loop the list: fetch, extract, compare to state, notify |
| `.github/workflows/stock-watch.yml` | Every 5 min, daily heartbeat, self-disable when all watches expire |
| `.github/workflows/keepalive.yml` | Weekly commit so GitHub does not disable the schedule |
| `state/<id>.txt` | Last seen value for one watch; its git log is that product's history |

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

Each entry in `watches.json` carries its own extraction strategy and deadline:

```json
{
  "id": "256987",
  "name": "Zelda OoT Edition",
  "url": "https://www.wog.ch/...",
  "method": "microdata",
  "deadline": "2026-11-05T23:00:00Z"
}
```

`method` selects the extraction function, so a different shop means adding a
strategy rather than special-casing the loop. The buyable-status allowlist stays
global because it is schema.org vocabulary, not per-site.

**Entries are isolated by construction.** `extract_microdata` always returns 0
and reports failure through `detail`, so an unreachable shop notifies blind for
that product and the loop continues. Any new strategy must behave the same way.
Test it: point one entry at a dead URL and confirm the entries after it still
run.

Parsing the list needs `jq`, which is preinstalled on `ubuntu-latest`.

Do not build a GitHub Pages UI for adding watches without re-reading the
constraints: Pages is static and cannot write to the repo, Pages on a private
repo needs GitHub Pro, and even then the published site is world-readable.
GitHub Issue Forms give a real mobile form with no credentials and work on a
private repo on the free plan.

## Adding or changing a watch

Add an entry to `watches.json` and create `state/<id>.txt` holding the page's
**current** value in the same commit. Skip the seeding and the first run reports
a none -> Discontinued transition and alerts for nothing. To confirm a new watch
works, force a heartbeat rather than leaving the state file empty.

For another product on the same shop the existing strategy works and only the
entry changes. For a different shop, do the investigation above first.

## Operational constraints

**Actions quota.** The repo is public, so minutes are unmetered and the schedule
is not cost bound. That is the only reason `2-59/5` is affordable. Private repos
bill every run as a full minute against 2000 min/month regardless of the job
taking ~15 seconds, where `2-59/5` is about 8640 min/month and would exhaust the
quota in a week, hard-stopping the watcher. `*/30` (about 1440) is the only
interval that fits privately. Redo this arithmetic before changing visibility,
not after.

**The ntfy topic must never be committed.** A topic name is the only access
control ntfy has: anyone who knows it can read the feed and post to it. On a
public repo a committed topic is a published one. It lives in the `NTFY_TOPIC`
secret and nowhere else, placeholders only in docs.

**Cron is best effort, and drops rather than defers.** A missed occurrence is
discarded, not queued, so the cron is a ceiling on how often the page gets
checked rather than a floor. Measured over 12-14 September 2026 on `*/30`: 12 of
70 occurrences fired (17%), median gap 2h18, worst gap 5h19, and not one run
landed on :00 or :30. The weekly keepalive was 5h38 late. Once-daily crons get
through, high-frequency ones get starved. `:00`, `:15`, `:30` and `:45` are the
most contended minutes, which is what the `2-59/5` offset avoids.

Contiguous run numbers across a gap are how you tell a dropped occurrence from a
run killed by the concurrency group: a cancelled run still consumes a number and
still appears in the list. If numbers are missing, look at concurrency instead.

**Deadlines are per watch**, in `watches.json`. Zelda ends `2026-11-05T23:00:00Z`
(midnight on 6 November in Europe/Zurich), the two Pokemon sets end
`2026-12-31T23:00:00Z`. An expired entry is skipped and shows as retired in the
heartbeat; the workflows only disable themselves once **every** entry has
expired, so one product ending cannot silence the rest. To resume, bump the
deadlines first, then `gh workflow enable stock-watch keepalive`, otherwise the
next run disables them again.

The check lives in the script rather than a workflow guard now. The old reason
for the guard, that a skipped step still starts the job and bills a minute, went
away when the repo became public and unmetered.

**Keepalive.** GitHub disables scheduled workflows after 60 days without repo
activity. A `state/<id>.txt` only gets committed on a status change, so a set of
products that all stay unavailable would silently kill their own watcher. That is
what the weekly commit is for.

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

The heartbeat body carries the run count and longest gap over the preceding 24h,
read back from the Actions API, so scheduler throttling surfaces on the phone
instead of only in the Actions tab. It needs `GH_TOKEN` in the check step, and
degrades to silence when `gh` is unavailable, which is why local runs omit it.

A failed ntfy POST does not fail the job. A green run is not proof a
notification arrived; check `gh run view --log` for the curl output.

## Testing

Run the real thing locally without touching repo state:

```sh
NTFY_TOPIC=<topic> STATE_DIR=/tmp/st bash scripts/check-stock.sh
NTFY_TOPIC=<topic> STATE_DIR=/tmp/st HEARTBEAT=1 bash scripts/check-stock.sh
```

`WATCHES=/tmp/watches-test.json` swaps the list, which is how you exercise the
paths the live pages will not produce on demand. A `file://` url reaches a local
fixture, so an InStock fixture tests the urgent path end to end. Seed a state
file with a wrong value to exercise a transition.

To see what would be published without publishing it, put a `curl` shim earlier
on `PATH` that logs any argument starting `https://ntfy.sh/` and execs the real
curl otherwise. Page fetches still go out, ntfy posts do not. Note that ntfy publish returns HTTP 200 with
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
