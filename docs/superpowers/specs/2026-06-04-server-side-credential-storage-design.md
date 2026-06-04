# Server-side credential storage

## Problem

Scanner credentials (award bearer tokens / cookies, offers cookie strings) are
persisted only in the browser's `localStorage` under the `scanner_form` key via
the `PersistForm` JS hook. The hook re-saves the current DOM on every
input/change and omits the credential keys when zero fields are present; a save
that runs before `restore_form` repopulates the DOM clobbers the saved set down
to the server-side mount defaults (1 empty award credential, 0 offers). Result:
silently dropped credentials.

## Goal

Make the server the single source of truth for credentials, persisted to a CSV
that survives restarts, so the UI can no longer drop them. Non-secret form
fields (origins, destinations, dates, concurrency, skip_days) continue to live
in `localStorage`.

## Design

### `Awardflights.CredentialStore` (new GenServer)

Mirrors the shape of `RateLimitTracker`. Backed by `credentials.csv`.

CSV format, one row per credential:

```
source,name,value
award,Account 1,<bearer token or cookie>
offers,Account 1,<cookie string>
```

- `source` is `"award"` or `"offers"`.
- `value` is the raw credential. For award it is the bearer/cookie passed to
  `SasAwardApi`; for offers it is the cookie string passed to `SasOffersApi`
  (`auth_token` remains derived from the cookies server-side, so it is not
  stored separately).
- `value` is the **last** column and is parsed with
  `String.split(line, ",", parts: 3)`, so commas inside cookie values are
  preserved. `name` and any newlines are stripped on write (names are display
  labels). This avoids the naive split-on-comma problem the other CSVs have.

API:

- `list(source) -> [%{name: String.t(), value: String.t()}]` — ordered.
- `put_all(source, creds)` — replace all rows for that source with `creds`,
  persist, update in-memory state.
- Loads from CSV at startup; missing file starts empty.

Replace-all-from-assigns is deliberate: the LiveView always holds the correct
credential count, so a mid-typing empty value just blanks one field's value and
never loses a credential row.

File path is configurable via `Application.get_env(:awardflights,
:credentials_file, "credentials.csv")` so tests use a temp file, matching the
other trackers.

### Security

- `credentials.csv` holds plaintext secrets at rest. Acceptable for a local
  single-user tool; stated plainly in the moduledoc.
- It already matches the existing `/*.csv` `.gitignore` entry, so it is not
  committed.
- The file is written with `0600` permissions.

### `scanner_live` changes

- `mount`: load award/offers credentials from `CredentialStore.list/1` instead
  of hardcoded defaults. Fall back to a single empty award row
  (`[%{name: "Default", value: ""}]`) and zero offers rows when the store is
  empty, preserving today's empty-state UX.
- `update_form`, `add_award_credential`, `remove_award_credential`,
  `add_offers_credential`, `remove_offers_credential`: after updating assigns,
  call `CredentialStore.put_all(source, creds)` (autosave).
- Remove credential handling from the `PersistForm` JS hook (`saveForm`'s
  `award_cred_*` / `offers_cred_*` collection) and from the `restore_form`
  handler, so `localStorage` no longer touches credentials. `localStorage`
  keeps persisting the non-secret fields only.

### Supervision

Add `CredentialStore` to the supervision tree in `application.ex`, beside
`RateLimitTracker` and `RequestTracker`.

### Migration

None. Existing localStorage credentials are not imported; they are re-entered
once. Not worth a one-time importer for a personal tool.

## Testing

- `CredentialStore`: put/list round-trip; persistence reload after restart;
  comma-in-value preserved; empty source; replace-all semantics. Uses a
  configurable temp file path.
- Update `scanner_live` tests that exercised credential restore/persistence to
  reflect server-side loading and autosave.

## Out of scope (YAGNI)

Encryption at rest, multi-user support, an explicit Save button, importing old
localStorage values.
