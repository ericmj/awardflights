# Server-side Credential Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist scanner credentials server-side in `credentials.csv` so the UI can no longer silently drop them, replacing the brittle browser-localStorage persistence.

**Architecture:** A new `Awardflights.CredentialStore` GenServer (modeled on `RateLimitTracker`) owns `credentials.csv`, keyed by `(source, name)` with a `value` column. The scanner LiveView loads credentials from it at mount and autosaves on every change/add/remove. The `PersistForm` JS hook stops touching credentials and keeps persisting only non-secret fields.

**Tech Stack:** Elixir/OTP GenServer, Phoenix LiveView, ExUnit.

---

### Task 1: CredentialStore GenServer

**Files:**
- Create: `lib/awardflights/credential_store.ex`
- Test: `test/awardflights/credential_store_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/awardflights/credential_store_test.exs`:

```elixir
defmodule Awardflights.CredentialStoreTest do
  use ExUnit.Case, async: false

  alias Awardflights.CredentialStore

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "credentials_test_#{System.unique_integer([:positive])}.csv")

    Application.put_env(:awardflights, :credentials_file, tmp)
    CredentialStore.clear_all()

    on_exit(fn ->
      File.rm(tmp)
      Application.delete_env(:awardflights, :credentials_file)
    end)

    {:ok, tmp: tmp}
  end

  test "put_all then list round-trips per source" do
    CredentialStore.put_all(:award, [%{name: "A1", value: "tok1"}, %{name: "A2", value: "tok2"}])
    CredentialStore.put_all(:offers, [%{name: "O1", value: "cookie1"}])

    assert CredentialStore.list(:award) ==
             [%{name: "A1", value: "tok1"}, %{name: "A2", value: "tok2"}]

    assert CredentialStore.list(:offers) == [%{name: "O1", value: "cookie1"}]
  end

  test "put_all replaces all rows for a source, leaving the other source intact" do
    CredentialStore.put_all(:award, [%{name: "A1", value: "tok1"}])
    CredentialStore.put_all(:offers, [%{name: "O1", value: "c1"}])
    CredentialStore.put_all(:award, [%{name: "A2", value: "tok2"}])

    assert CredentialStore.list(:award) == [%{name: "A2", value: "tok2"}]
    assert CredentialStore.list(:offers) == [%{name: "O1", value: "c1"}]
  end

  test "preserves commas inside the value (last column) across a disk reload" do
    CredentialStore.put_all(:offers, [%{name: "O1", value: "a=1; b=2,3; c=4"}])
    CredentialStore.reload()
    assert CredentialStore.list(:offers) == [%{name: "O1", value: "a=1; b=2,3; c=4"}]
  end

  test "survives reload from disk", %{tmp: tmp} do
    CredentialStore.put_all(:award, [%{name: "A1", value: "tok1"}])
    assert File.exists?(tmp)
    CredentialStore.reload()
    assert CredentialStore.list(:award) == [%{name: "A1", value: "tok1"}]
  end

  test "strips newlines and commas from name, newlines from value" do
    CredentialStore.put_all(:award, [%{name: "Acc,1\n", value: "tok\nen"}])
    assert CredentialStore.list(:award) == [%{name: "Acc1", value: "token"}]
  end

  test "writes file with 0600 permissions", %{tmp: tmp} do
    CredentialStore.put_all(:award, [%{name: "A1", value: "t"}])
    assert rem(File.stat!(tmp).mode, 0o1000) == 0o600
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/awardflights/credential_store_test.exs`
Expected: FAIL — `Awardflights.CredentialStore` is undefined.

- [ ] **Step 3: Write minimal implementation**

Create `lib/awardflights/credential_store.ex`:

```elixir
defmodule Awardflights.CredentialStore do
  @moduledoc """
  GenServer holding scanner credentials, persisted to credentials.csv so they
  survive restarts and cannot be dropped by the browser.

  SECURITY: credentials.csv stores raw credential values (bearer tokens / cookie
  strings) in plaintext on disk. Acceptable for a local single-user tool. The
  file matches the `/*.csv` .gitignore entry and is written with 0600 perms.
  """
  use GenServer
  require Logger

  @headers ["source", "name", "value"]

  defp credentials_file,
    do: Application.get_env(:awardflights, :credentials_file, "credentials.csv")

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List credentials for a source (:award or :offers) as [%{name, value}]."
  def list(source), do: GenServer.call(__MODULE__, {:list, source})

  @doc "Replace all credentials for a source. creds is [%{name, value}]."
  def put_all(source, creds), do: GenServer.call(__MODULE__, {:put_all, source, creds})

  @doc "Re-read the CSV from disk into memory (for tests / external edits)."
  def reload, do: GenServer.call(__MODULE__, :reload)

  @doc "Clear all credentials (in memory and on disk)."
  def clear_all, do: GenServer.call(__MODULE__, :clear_all)

  @impl true
  def init(_opts), do: {:ok, %{credentials: load_from_csv()}}

  @impl true
  def handle_call({:list, source}, _from, state) do
    src = to_string(source)

    creds =
      state.credentials
      |> Enum.filter(&(&1.source == src))
      |> Enum.map(&%{name: &1.name, value: &1.value})

    {:reply, creds, state}
  end

  def handle_call({:put_all, source, creds}, _from, state) do
    src = to_string(source)
    others = Enum.reject(state.credentials, &(&1.source == src))

    new_rows =
      Enum.map(creds, fn c ->
        %{source: src, name: sanitize_name(c.name), value: sanitize_value(c.value)}
      end)

    credentials = others ++ new_rows
    save_to_csv(credentials)
    {:reply, :ok, %{state | credentials: credentials}}
  end

  def handle_call(:reload, _from, _state), do: {:reply, :ok, %{credentials: load_from_csv()}}

  def handle_call(:clear_all, _from, _state) do
    save_to_csv([])
    {:reply, :ok, %{credentials: []}}
  end

  # name is not the last CSV column, so it must not contain commas or newlines.
  defp sanitize_name(nil), do: ""
  defp sanitize_name(str), do: str |> String.replace(~r/[\r\n,]+/, "") |> String.trim()

  # value is the last column; commas are fine, but newlines would break the row.
  defp sanitize_value(nil), do: ""
  defp sanitize_value(str), do: String.replace(str, ~r/[\r\n]+/, "")

  defp load_from_csv do
    case File.read(credentials_file()) do
      {:ok, content} ->
        parse_csv(content)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("Failed to read credentials.csv: #{inspect(reason)}, starting empty")
        []
    end
  end

  defp parse_csv(content) do
    case String.split(content, "\n", trim: true) do
      [] -> []
      [_header | rows] -> Enum.flat_map(rows, &parse_row/1)
    end
  end

  defp parse_row(line) do
    case String.split(line, ",", parts: 3) do
      [source, name, value] when source in ["award", "offers"] ->
        [%{source: source, name: name, value: value}]

      _ ->
        []
    end
  end

  defp save_to_csv(credentials) do
    header = Enum.join(@headers, ",")
    lines = Enum.map(credentials, fn c -> Enum.join([c.source, c.name, c.value], ",") end)
    content = Enum.join([header | lines], "\n") <> "\n"

    case File.write(credentials_file(), content) do
      :ok ->
        _ = File.chmod(credentials_file(), 0o600)
        :ok

      {:error, reason} ->
        Logger.error("Failed to write credentials.csv: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
```

- [ ] **Step 4: Add CredentialStore to the supervision tree so the named process exists for the test**

Modify `lib/awardflights/application.ex`, in the `children` list, add `Awardflights.CredentialStore` after `Awardflights.RateLimitTracker`:

```elixir
      Awardflights.CsvWriter,
      Awardflights.RequestTracker,
      Awardflights.RateLimitTracker,
      Awardflights.CredentialStore,
      {Task.Supervisor, name: Awardflights.TaskSupervisor},
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/awardflights/credential_store_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/awardflights/credential_store.ex test/awardflights/credential_store_test.exs lib/awardflights/application.ex
git commit -m "Add CredentialStore GenServer with CSV persistence"
```

---

### Task 2: Load and autosave credentials in ScannerLive

**Files:**
- Modify: `lib/awardflights_web/live/scanner_live.ex` (alias line 4; mount 17-50; `restore_form` 54-110; `update_form` 113-143; add/remove handlers 235-267)
- Test: `test/awardflights_web/live/scanner_live_test.exs`

- [ ] **Step 1: Write the failing test**

In `test/awardflights_web/live/scanner_live_test.exs`, add to the existing `setup` block (so each test gets an isolated store) these lines, and add the new test inside the top-level `describe` for rendering (or a new `describe "credential persistence"`):

Setup additions (place alongside the other file-isolation setup):

```elixir
    tmp_creds =
      Path.join(System.tmp_dir!(), "credentials_test_#{System.unique_integer([:positive])}.csv")

    Application.put_env(:awardflights, :credentials_file, tmp_creds)
    Awardflights.CredentialStore.clear_all()

    on_exit(fn ->
      File.rm(tmp_creds)
      Application.delete_env(:awardflights, :credentials_file)
    end)
```

New test:

```elixir
  describe "credential persistence" do
    test "loads saved credentials from the store on mount", %{conn: conn} do
      Awardflights.CredentialStore.put_all(:award, [%{name: "Saved Award", value: "saved_tok"}])
      Awardflights.CredentialStore.put_all(:offers, [%{name: "Saved Offers", value: "saved_cookie"}])

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Saved Award"
      assert html =~ "saved_tok"
      assert html =~ "Saved Offers"
      assert html =~ "saved_cookie"
    end

    test "adding a credential persists it to the store", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("button[phx-click=add_award_credential]")
      |> render_click()

      assert length(Awardflights.CredentialStore.list(:award)) == 2
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/awardflights_web/live/scanner_live_test.exs`
Expected: FAIL — mount still uses hardcoded defaults, so "Saved Award" is absent and the store is not written on add.

- [ ] **Step 3: Add the alias**

Modify `lib/awardflights_web/live/scanner_live.ex` line 4:

```elixir
  alias Awardflights.{CredentialStore, FlightScanner, RateLimitTracker}
```

- [ ] **Step 4: Load credentials from the store at mount**

In `mount/3`, replace the two hardcoded credential assigns (lines 24 and 26) with store-loaded values. Replace:

```elixir
       # Credential lists: [{name: "", value: ""}, ...]
       award_credentials: [%{name: "Default", value: ""}],
       # Offers credentials: [{name: "", cookies: "", auth_token: ""}, ...]
       offers_credentials: [],
```

with:

```elixir
       # Credential lists loaded from the server-side store
       award_credentials: load_award_credentials(),
       offers_credentials: load_offers_credentials(),
```

Add these private helpers near the other `defp`s (e.g. just above `update_credentials_from_params/4` at line 505):

```elixir
  defp load_award_credentials do
    case CredentialStore.list(:award) do
      [] -> [%{name: "Default", value: ""}]
      creds -> Enum.map(creds, &%{name: &1.name, value: &1.value})
    end
  end

  defp load_offers_credentials do
    CredentialStore.list(:offers)
    |> Enum.map(&%{name: &1.name, cookies: &1.value, auth_token: ""})
  end

  defp award_to_store(creds), do: Enum.map(creds, &%{name: &1.name, value: &1.value})
  defp offers_to_store(creds), do: Enum.map(creds, &%{name: &1.name, value: &1.cookies})
```

- [ ] **Step 5: Stop restoring credentials from localStorage**

Replace the entire `handle_event("restore_form", ...)` function (lines 54-110) with this version that no longer touches credentials:

```elixir
  def handle_event("restore_form", params, socket) do
    {:noreply,
     assign(socket,
       origins: params["origins"] || socket.assigns.origins,
       destinations: params["destinations"] || socket.assigns.destinations,
       start_date: params["start_date"] || socket.assigns.start_date,
       end_date: params["end_date"] || socket.assigns.end_date,
       max_concurrency: parse_int(params["max_concurrency"], socket.assigns.max_concurrency),
       skip_days: parse_int(params["skip_days"], socket.assigns.skip_days)
     )}
  end
```

- [ ] **Step 6: Autosave on form change and on add/remove**

In `handle_event("update_form", ...)` (lines 113-143), after the two credential lists are computed and before the final `{:noreply, assign(...)}`, add:

```elixir
    CredentialStore.put_all(:award, award_to_store(award_credentials))
    CredentialStore.put_all(:offers, offers_to_store(offers_credentials))
```

In `handle_event("add_award_credential", ...)` (lines 235-240), change the body to persist:

```elixir
  def handle_event("add_award_credential", _params, socket) do
    new_credential = %{name: "Account #{length(socket.assigns.award_credentials) + 1}", value: ""}
    credentials = socket.assigns.award_credentials ++ [new_credential]
    CredentialStore.put_all(:award, award_to_store(credentials))
    {:noreply, assign(socket, award_credentials: credentials)}
  end
```

In `handle_event("remove_award_credential", ...)` (lines 243-248), persist after deletion:

```elixir
  def handle_event("remove_award_credential", %{"index" => index}, socket) do
    index = String.to_integer(index)
    credentials = List.delete_at(socket.assigns.award_credentials, index)
    CredentialStore.put_all(:award, award_to_store(credentials))
    {:noreply, assign(socket, award_credentials: credentials)}
  end
```

In `handle_event("add_offers_credential", ...)` (lines 252-260), persist:

```elixir
  def handle_event("add_offers_credential", _params, socket) do
    new_credential = %{
      name: "Account #{length(socket.assigns.offers_credentials) + 1}",
      cookies: "",
      auth_token: ""
    }

    credentials = socket.assigns.offers_credentials ++ [new_credential]
    CredentialStore.put_all(:offers, offers_to_store(credentials))
    {:noreply, assign(socket, offers_credentials: credentials)}
  end
```

In `handle_event("remove_offers_credential", ...)` (lines 264-267), persist:

```elixir
  def handle_event("remove_offers_credential", %{"index" => index}, socket) do
    index = String.to_integer(index)
    credentials = List.delete_at(socket.assigns.offers_credentials, index)
    CredentialStore.put_all(:offers, offers_to_store(credentials))
    {:noreply, assign(socket, offers_credentials: credentials)}
  end
```

> Note: keep the existing `index = String.to_integer(index)` line if the current code already converts it; match the existing conversion exactly. The snippets above assume the params arrive as strings, which matches the current handlers.

- [ ] **Step 7: Run test to verify it passes**

Run: `mix test test/awardflights_web/live/scanner_live_test.exs`
Expected: PASS, including the two new credential-persistence tests.

- [ ] **Step 8: Commit**

```bash
git add lib/awardflights_web/live/scanner_live.ex test/awardflights_web/live/scanner_live_test.exs
git commit -m "Load and autosave scanner credentials via CredentialStore"
```

---

### Task 3: Stop persisting credentials in localStorage (JS hook)

**Files:**
- Modify: `assets/js/app.js` (`saveForm`, lines 57-110)

- [ ] **Step 1: Remove credential collection from saveForm**

Replace the `saveForm()` method (lines 57-110) with this version, which drops the `award_credentials` / `offers_credentials` collection blocks but still skips credential fields so they are never written to localStorage:

```javascript
    saveForm() {
      const formData = new FormData(this.el)
      const values = {}

      // Persist only non-credential fields. Credentials live server-side
      // (CredentialStore); storing them here is what used to drop them.
      for (const [key, value] of formData.entries()) {
        if (!key.startsWith("award_cred_") && !key.startsWith("offers_cred_")) {
          values[key] = value
        }
      }

      // Get checkbox states explicitly (unchecked checkboxes aren't in FormData)
      this.el.querySelectorAll('input[type="checkbox"]').forEach(cb => {
        values[cb.name] = cb.checked ? "true" : "false"
      })

      localStorage.setItem(this.storageKey, JSON.stringify(values))
    }
```

- [ ] **Step 2: Verify the asset compiles**

Run: `mix assets.build`
Expected: completes with no errors.

- [ ] **Step 3: Commit**

```bash
git add assets/js/app.js
git commit -m "Stop persisting credentials in localStorage"
```

---

### Task 4: Full verification

- [ ] **Step 1: Run the formatter**

Run: `mix format`

- [ ] **Step 2: Run the full suite**

Run: `mix test`
Expected: all tests pass (existing suite + new CredentialStore and persistence tests).

- [ ] **Step 3: Compile with warnings as errors**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 4: Commit any formatter changes**

```bash
git add -u
git commit -m "Format" --allow-empty
```

---

## Self-Review Notes

- **Spec coverage:** CredentialStore + credentials.csv (Task 1); 0600 perms and gitignore — perms tested in Task 1, gitignore already covered by `/*.csv`; scanner_live mount load + autosave + remove restore (Task 2); JS hook credential removal (Task 3); supervision tree (Task 1 Step 4); tests (Tasks 1–2); no migration (intentionally absent). All spec sections map to a task.
- **Type consistency:** store API is `%{name, value}` everywhere; `award_to_store/1` and `offers_to_store/1` convert the LiveView's `%{name, value}` (award) and `%{name, cookies, auth_token}` (offers) to the store shape; `load_offers_credentials/0` converts back. `put_all/2`, `list/1`, `reload/0`, `clear_all/0` names are consistent across tasks.
- **No placeholders:** every code step contains complete code.
