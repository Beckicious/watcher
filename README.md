# wog-stock-watch

Polls wog.ch for the Nintendo Switch 2 "The Legend of Zelda: Ocarina of Time Edition"
and pushes a phone notification when it stops being `Discontinued`.

Product: https://www.wog.ch/en/index.cfm/details/product/256987-Nintendo-Switch-2-The-Legend-of-Zelda-Ocarina-of-Time-Edition

## How it detects stock

The page exposes schema.org microdata in the product's Offer block:

```html
<link itemprop="availability" href="https://schema.org/Discontinued" />
```

This is the only `itemprop="availability"` on the page, so it is unambiguous.
Do not match on visible text: the page renders a legend of all eight possible
statuses ("currently sold out", "available from our stock", ...) plus roughly
35 related products with their own badges, so any text match hits permanently.

The script treats a count other than exactly one as a structure change and
alerts you that the watcher went blind, rather than failing silently.

## Setup

1. Install the ntfy app (iOS / Android) and subscribe to topic: `wog-zelda-xhdvn6wsei`

   Topics are public to anyone who guesses the name, which is why this one is random.
   Verify it works:

   ```sh
   curl -d "test" https://ntfy.sh/wog-zelda-xhdvn6wsei
   ```

2. Push this directory to a GitHub repo.

3. Add the topic as a repository secret named `NTFY_TOPIC`:

   ```sh
   gh secret set NTFY_TOPIC --body "wog-zelda-xhdvn6wsei"
   ```

4. Trigger a run manually to confirm the pipeline:

   ```sh
   gh workflow run stock-watch
   ```

## Polling interval

`.github/workflows/stock-watch.yml` is set to `*/30`. On a **private** repo,
Actions bills every run as a full minute against the 2000 min/month free quota,
so `*/30` (about 1440/month) fits and `*/15` (about 2880/month) does not.
On a **public** repo Actions minutes are unmetered, so `*/15` is fine.

GitHub also delays scheduled runs under load, so treat the interval as a floor.

## Deadline

`DEADLINE` in `stock-watch.yml` is `2026-11-05T23:00:00Z`, midnight on 6 November
in Europe/Zurich, so the last check runs at 23:30 local on 5 November.

The first run past that point sends a "retired" notification, then disables both
`stock-watch` and `keepalive`, which stops the schedule and the Actions billing.
A guard alone would not be enough: a skipped step still starts the job and bills
a full minute.

To resume, bump `DEADLINE` first, otherwise the next run disables everything again:

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

Alerts fire on **transitions** only. `state.txt` holds the last seen value and is
committed back to the repo, so its git log doubles as a stock history.

The first run after setup will alert once (no previous state), which confirms
the whole chain works end to end.

## Local testing

```sh
NTFY_TOPIC=wog-zelda-xhdvn6wsei ./scripts/check-stock.sh
```
