# SAS cookie capture

Reads SAS session cookies (including the HttpOnly `LOGIN_AUTH` / `__session`)
from a browser profile and writes them into the scanner's `credentials.csv`.

Page JavaScript cannot read HttpOnly cookies, so browser-side scraping can't get
them. This launches a real browser and reads cookies from the browser *context*,
which can.

Three entry points, pick by situation:

- `capture-cookies.mjs` (`npm start`) — one account, in a throwaway profile. You
  log in once in the window it opens.
- `save-accounts.mjs` — several accounts in one run, each verified against the
  award-api before it's written. See "Multiple accounts".
- `extract-vivaldi-cookies.mjs` — no browser automation; decrypts cookies
  straight from an already-logged-in Vivaldi/Chromium on-disk store.

All of them write only to `credentials.csv` and never print cookie values.

## Setup

```
cd scripts/sas-cookies
npm install
```

`npm install` pulls Playwright. The script uses your installed Chrome by default
(no extra browser download). If Chrome isn't found it falls back to Playwright's
bundled Chromium, which needs `npx playwright install chromium` once.

## Use

```
npm start
```

A browser window opens on sas.se against a dedicated profile in
`./.chrome-profile` (separate from your normal Chrome, so nothing touches your
main profile and your normal Chrome can stay open). Log in to SAS in that window
the first time. The script waits for a session cookie, writes the full cookie
string into `credentials.csv`, and closes the browser.

Cookie values are written to disk only. They are never printed to the terminal.

## Refreshing rotated cookies

SAS rotates these session cookies, which is what the scanner's
`:credential_expired` handler reacts to. Re-run `npm start` to refresh. The
profile persists, so if the session is still valid it captures immediately with
no login; if it expired, log in again in the window.

To automate refresh, run it on a schedule (cron / launchd). It only pauses for a
manual login when the persisted session has actually expired, so a scheduled run
against a still-valid session is non-interactive.

## Options

```
node capture-cookies.mjs --help
```

| Option | Default | Purpose |
| --- | --- | --- |
| `--name` | `SAS EuroBonus` | Value of the CSV `name` column. |
| `--file` | `<repo>/credentials.csv` | Target CSV. |
| `--sources` | `award,offers` | Which scanner sources to write rows for. |
| `--profile` | `./.chrome-profile` | Browser profile directory. |
| `--auth-cookie` | `LOGIN_AUTH,__session` | Cookie names that signal a logged-in session. |
| `--login-timeout` | `300` | Seconds to wait for login before capturing anyway. |

The script upserts by `(source, name)`: it replaces only the rows it writes and
leaves any other credentials in the file untouched.

## Multiple accounts

`save-accounts.mjs` captures several accounts in one run and verifies each before
it writes.

```
node save-accounts.mjs ericmj2@hex.pm ericmj3@hex.pm ...
```

Each name gets its own persisted profile under `.sas-profiles/<name>`. For each
account the script opens sas.se and waits for you to finish logging in (it never
touches passwords). Once you're in, it runs a "pay with points" search itself to
mint the `LOGIN_AUTH` cookie, then verifies the credential by calling the
award-api from inside the logged-in window; it writes the row (under the account
name, for both sources) only on HTTP 200, and retries while the window is open
otherwise, so a dud capture never reaches `credentials.csv`. Profiles persist, so
an account logged in on a prior run usually restores with no new login.
`LOGIN_WAIT` (seconds, default 600) bounds the per-account wait for login.

`.sas-profiles/` holds live login sessions and is gitignored — never commit it.

## Vivaldi (or any Chromium browser): read cookies directly, no login

`extract-vivaldi-cookies.mjs` reads SAS cookies straight from Vivaldi's on-disk
store and writes `credentials.csv`. It works while Vivaldi is running and needs no
browser automation and no copy-paste. Use this instead of `capture-cookies.mjs`
when you want to reuse a session you are already logged into in Vivaldi.

```
node extract-vivaldi-cookies.mjs
```

On macOS, Chromium browsers encrypt cookie values with AES-128-CBC under a key in
the login keychain (for Vivaldi, the item "Vivaldi Safe Storage"). The script reads
that key (macOS prompts you to Allow the first time), copies the cookie SQLite so it
does not contend with the running browser, pulls the sas.se rows via the system
`sqlite3`, and decrypts them. Cookie values go to `credentials.csv` only, never to
the terminal.

Verify the decryption logic with `node decrypt.test.mjs` (synthetic, no keychain).

Options: `--profile` (Vivaldi user-data dir), `--cookie-db`, `--host` (default
`sas.se`), `--keychain-service` / `--keychain-account`, plus the shared `--name`,
`--file`, `--sources`. See `--help`.

For Chrome/Brave/Edge, the same scheme applies with a different keychain item
(e.g. "Chrome Safe Storage"); pass `--keychain-service` and `--profile` accordingly.

## Reusing an existing browser profile with automation

`--browser vivaldi|brave|edge` points at your real, already-logged-in profile and
reads the session there (no login). That browser must be fully quit first, because
Chromium holds an exclusive lock on its profile while running, and Playwright then
drives your real profile.

Vivaldi does not work this way: its release build does not expose the automation
interface Playwright needs, so the launch hangs and never becomes driveable. For
Vivaldi, use `extract-vivaldi-cookies.mjs` (above), which reads the cookie store
directly and does not need automation.

brave and edge track stock Chromium more closely and may work in reuse mode, but
that is not verified here.
