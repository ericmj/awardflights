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
