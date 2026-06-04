# Troubleshooting the scanner

Context for recurring failure modes, what causes them, and how to fix them.
Written after a debugging session that fixed premium-economy results, the
SAS-direct (offers) Cloudflare block, and credential persistence.

---

## 1. SAS-direct ("offers") scan returns zero results

The offers path (`lib/awardflights/sas_offers_api.ex`, source `offers`, the
"SAS direct" credentials) hits `https://www.sas.se/api/offers/flights` through
**Docker + curl-impersonate** to get past Cloudflare's TLS fingerprinting. The
award path (`sas_award_api.ex`, source `award`, "partner" credentials) uses
plain HTTP and is unaffected by all of this.

### Diagnose

Look at `failed_requests.csv` (in the project root) for `offers` rows:

- `{:curl_failed, 1, "...Cannot connect to the Docker daemon..."}` → **Docker
  isn't running.** Start Docker Desktop.
- `:cloudflare_blocked` → the request reached Cloudflare and got the
  "Just a moment..." challenge page instead of JSON. See "Cloudflare" below.
- No `offers` rows at all, and no `offers` rows in `results.csv` either → the
  requests may have been **skipped** (see section 4) or recorded as empty.

Note: before the fix, a Cloudflare challenge was silently turned into
`{:ok, []}` and looked identical to "no availability." `parse_response/4` now
returns `{:error, :cloudflare_blocked}` (and `{:error, {:unexpected_response,
_}}` for other non-JSON), so these show up in `failed_requests.csv` instead of
vanishing. Keep that behavior.

### Fix: Cloudflare is challenging the requests

The image and impersonation profile are set near the top of
`sas_offers_api.ex`:

```elixir
@docker_image "lexiforest/curl-impersonate:latest"
@impersonate_target "curl_chrome131"
```

**The thing that gets past Cloudflare is the TLS/JA3 handshake of the
impersonation profile — NOT the User-Agent and NOT your browser version.** This
was verified experimentally:

- `cf_clearance` was minted by a Vivaldi / Chrome 148 browser, yet the
  `curl_chrome131` profile (which sends a Chrome 131 handshake + UA) works.
- Holding the chrome131 handshake fixed and varying only the claimed
  User-Agent (131 vs 146 vs 148) made no difference — all passed.
- The newer `--impersonate chrome142` / `chrome146` profiles get challenged;
  `chrome131`'s explicit cipher/curve/extension recipe is currently accepted.

So if it breaks:

1. **Refresh the cookie first.** `cf_clearance` is time-limited and IP-bound.
   Re-copy the full cookie string from a logged-in **Chromium-based** browser
   (Vivaldi/Chrome/Edge) on the **same network** and paste it into the offers
   credential. Most "it suddenly stopped" cases are just an expired cookie.
2. **If a fresh cookie still gets `:cloudflare_blocked`,** Cloudflare has likely
   started flagging the chrome131 fingerprint. Bump `@impersonate_target` to
   another profile the image ships and retest:
   `curl_chrome133a`, `curl_chrome136`, `curl_chrome142`, `curl_chrome145`,
   `curl_chrome146`. List them with:
   ```
   docker run --rm --platform linux/amd64 --entrypoint sh \
     lexiforest/curl-impersonate:latest -c 'ls /usr/local/bin | grep curl_'
   ```
3. **If no shipped profile passes,** pull a newer image
   (`docker pull --platform linux/amd64 lexiforest/curl-impersonate:latest`)
   and try its newest Chrome profile.

To test a profile by hand without the app (replace COOKIE/URL):

```bash
docker run --rm --platform linux/amd64 --entrypoint curl_chrome131 \
  lexiforest/curl-impersonate:latest -s --max-time 30 \
  -H 'accept: application/json, text/plain, */*' \
  -H 'origin: https://www.sas.se' -H 'referer: https://www.sas.se/book/flights' \
  -H 'sec-fetch-dest: empty' -H 'sec-fetch-mode: cors' -H 'sec-fetch-site: same-origin' \
  -H "cookie: $COOKIE" \
  'https://www.sas.se/api/offers/flights?from=GOT&to=NYC&outDate=20260904&adt=1&chd=0&inf=0&yth=0&bookingFlow=points&pos=se&channel=web&displayType=upsell'
```

A `<title>Just a moment...</title>` body = challenged. JSON starting with `{` =
working.

> Caveat: stick to copying the cookie from a **Chromium** browser. A
> `cf_clearance` minted by Safari/Firefox pairs with a different fingerprint
> family and is untested against the chrome profiles.

---

## 2. Premium economy or partner cabins missing (award path)

The SAS award-api response shape drifted once already and the parser was fixed
in `sas_award_api.ex`. Today's live shape:

- Cabin name is under the `cabin` key (e.g. `"premium economy"`), **not**
  `cabinName`.
- Points are nested per award type: `price.SKY.points` (SkyTeam) or
  `price.BILATERAL.points` (SAS), **not** `price.points` or `fares[].points`.
- Seats are at `availableSeats` (cabin level).
- Observed booking classes: premium economy = `F`/`P`, business = `I`/`O`/`G`,
  economy = `X`/`N`.

`parse_cabin/5` routes to `parse_cabin_level/5` when `availableSeats` or a
cabin-level price is present, and reads name/points/seats from the locations
above. If premium economy (or any cabin) starts coming back as `"Unknown"` /
`0` points again, the shape has drifted: capture a live response and check where
`cabin`, `price.*.points`, and `availableSeats` actually live, then update
`parse_cabin_level/5` and `cabin_points/1` accordingly.

The `@class_to_cabin` map in `trip_correlator.ex` is only a fallback for when
the cabin name is literally `"unknown"`; the parser reading the real `cabin`
field is the primary path.

To inspect what the parser produces from a saved response, stub the executor:

```elixir
body = File.read!("response.json")
Application.put_env(:awardflights, :sas_award_api_plug,
  {Req.Test, Awardflights.SasAwardApi})
Req.Test.stub(Awardflights.SasAwardApi, fn conn -> Req.Test.json(conn, Jason.decode!(body)) end)
Awardflights.SasAwardApi.search_flights("CDG", "JFK", "2027-04-03", "dummy")
```

Award space is sparse — to confirm a cabin exists at all, sweep many dates on a
strong route (e.g. CDG/AMS → JFK/EWR). A handful of dates is not enough.

---

## 3. Credentials disappear from the UI

Credentials are stored server-side in `credentials.csv` (root) by
`Awardflights.CredentialStore`, keyed by `(source, name)`, loaded at LiveView
mount and autosaved on edit/add/remove. They survive restarts and reloads.

`credentials.csv` holds plaintext secrets; it matches the `/*.csv` gitignore so
it is never committed, and is written `0600`.

**For a future agent:** once the user has entered credentials in the UI, you can
read the cookies/tokens straight from `credentials.csv` to make requests —
you do **not** need to ask the user to paste cookies. The columns are
`source,name,value` (value is the last column and may contain commas). Use the
`offers` rows' `value` as the cookie string for `SasOffersApi`, and the `award`
rows' `value` as the credential for `SasAwardApi`.

Caveat: the stored cookies expire. The `cf_clearance` and session cookies in an
`offers` value, and the bearer/session in an `award` value, are time-limited and
IP-bound. So `credentials.csv` gives you the **last-known** cookies, not
guaranteed-live ones. If requests come back `:cloudflare_blocked` (offers) or
`:auth_expired` (award), the stored cookie is stale — then, and only then, ask
the user for a fresh one. Never echo these values into the transcript or commit
them.

(Previously credentials lived in browser `localStorage` via the `PersistForm`
JS hook and got clobbered down to defaults when a save ran before restore. The
hook no longer touches credentials — it only persists non-secret fields like
origins/dates.)

---

## 4. Routes/dates skipped on re-scan

`RequestTracker` dedups by `(source, origin, destination, date)` in
`request_history.csv`. `should_skip?` returns true when an entry exists and was
scanned within `skip_days` days.

- `skip_days` is a UI field; it defaults to `0`, and at `0` there is **no**
  dedup — everything re-scans.
- If you set `skip_days > 0` and want to force a re-scan, delete the relevant
  rows from `request_history.csv` (or the whole file), **then restart the app**
  — `RequestTracker` loads the file into memory at boot, so editing it while the
  app runs has no effect.

---

## Key facts to remember

- Two independent paths: `offers` (Docker/curl-impersonate, SAS metal) and
  `award` (plain HTTP, SAS + SkyTeam partners). They fail for different reasons.
- Cloudflare bypass depends on the **TLS fingerprint** of the curl-impersonate
  profile, not the User-Agent or browser version. Browser updates should not
  break it; an expired/again `cf_clearance` cookie or Cloudflare re-tuning will.
- Data files live in the project root and are gitignored (`/*.csv`):
  `results.csv`, `trips.csv`, `request_history.csv`, `failed_requests.csv`,
  `rate_limits.csv`, `credentials.csv`.
