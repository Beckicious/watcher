# wog-stock-watch

Polls wog.ch product pages and pushes a phone notification when one stops being
`Discontinued`.

Watches live in `watches.json`, one entry per product:

| Product | id | Watched until |
|---|---|---|
| Switch 2 Zelda: Ocarina of Time Edition | 256987 | 2026-11-05 |
| Pokemon 30th Celebration UPC Day EN | 254353 | 2026-12-31 |
| Pokemon 30th Celebration UPC Night EN | 254355 | 2026-12-31 |

Each entry keeps its own state in `state/<id>.txt` and its own deadline. A shop
that breaks notifies blind for that product only and the remaining watches carry
on.

## How it detects stock

The page exposes schema.org microdata in the product's Offer block:

```html
<link itemprop="availability" href="https://schema.org/Discontinued" />
```

This is the only `itemprop="availability"` on the page, so it is unambiguous.
`itemprop="price"` is unique the same way, which is where the price in an
in-stock alert comes from.
Do not match on visible text: the page renders a legend of all eight possible
statuses ("currently sold out", "available from our stock", ...) plus roughly
35 related products with their own badges, so any text match hits permanently.

The script treats a count other than exactly one as a structure change and
alerts you that the watcher went blind, rather than failing silently.

## Setup

1. Pick a random ntfy topic name and keep it out of the repo. Anyone who knows a
   topic name can both read the feed and post to it, and this repo is public, so
   the name is the only thing protecting it.

   ```sh
   TOPIC="wog-zelda-$(head -c 12 /dev/urandom | base32 | tr -d = | tr 'A-Z' 'a-z')"
   echo "$TOPIC"
   ```

2. Install the ntfy app (iOS / Android), subscribe to that topic, then confirm
   the phone actually receives it:

   ```sh
   curl -d "test" "https://ntfy.sh/$TOPIC"
   ```

3. Push this directory to a GitHub repo and store the topic as a secret:

   ```sh
   gh secret set NTFY_TOPIC --body "$TOPIC"
   ```

4. Trigger a run manually to confirm the pipeline:

   ```sh
   gh workflow run stock-watch
   ```

## Polling interval

`.github/workflows/stock-watch.yml` runs `2-59/5 * * * *`, every five minutes
offset off the contended quarter-hour marks. That is only affordable because the
repo is **public**, where Actions minutes are unmetered. On a **private** repo
every run bills a full minute against the 2000 min/month quota, which caps the
schedule at `*/30` (about 1440/month) and rules out anything shorter.

GitHub's scheduler is best effort and **drops** occurrences rather than deferring
them, so the cron is a ceiling on how often you get checked, not a floor. Over
one measured weekend on `*/30`, 17% of occurrences fired, the median gap was 2h18
and the worst was 5h19. Raising the nominal rate buys more chances to land, not a
guarantee. The daily heartbeat reports the run count and longest gap over the
last 24h so the real delivery rate stays visible without opening the Actions tab.

## Deadlines

Each watch carries its own `deadline` in `watches.json`. An expired entry is
skipped and reported as retired in the heartbeat, so Zelda ending on 5 November
does not stop the Pokemon watches.

Once every entry has expired, the run sends one "retired" notification and
disables both `stock-watch` and `keepalive`, stopping the schedule.

To resume, bump the deadlines first, otherwise the next run disables everything again:

```sh
gh workflow enable stock-watch
gh workflow enable keepalive
```

## Notifications

| Availability value | Priority | Meaning |
|---|---|---|
| `InStock`, `PreOrder`, `BackOrder`, ... | urgent | Buy it |
| `UNKNOWN` | high | Fetch or parse broke, the watcher is blind |
| anything else | default | Status moved but still not orderable |

Alerts fire on **transitions** only. `state/<id>.txt` holds the last seen value
and is committed back to the repo, so its git log doubles as a stock history for
that product.

A new entry must be added with its state file seeded to the page's current
value, otherwise its first run alerts on a none -> Discontinued transition that
means nothing. Force a heartbeat to confirm a new watch instead.

## Local testing

```sh
NTFY_TOPIC="$TOPIC" STATE_DIR=/tmp/st bash scripts/check-stock.sh
NTFY_TOPIC="$TOPIC" STATE_DIR=/tmp/st HEARTBEAT=1 bash scripts/check-stock.sh
```

`WATCHES=/tmp/watches-test.json` swaps in a different list. Needs `jq`, which is
already on the runner.
