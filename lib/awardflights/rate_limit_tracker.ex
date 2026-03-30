defmodule Awardflights.RateLimitTracker do
  @moduledoc """
  GenServer for tracking rate limits with CSV persistence.
  Ensures rate limit state survives application restarts.
  """
  use GenServer
  require Logger

  @headers ["source", "credential_name", "rate_limited_until", "expired", "value_hash"]

  defp rate_limits_file,
    do: Application.get_env(:awardflights, :rate_limits_file, "rate_limits.csv")

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get all active rate limits for a source (:award or :offers)"
  def get_rate_limits(source) do
    GenServer.call(__MODULE__, {:get_rate_limits, source})
  end

  @doc """
  Check if a specific credential is rate limited or expired.
  Returns: :ok | {:rate_limited, seconds_remaining} | :expired
  """
  def check_credential(source, credential_name) do
    GenServer.call(__MODULE__, {:check_credential, source, credential_name})
  end

  @doc "Mark a credential as rate limited for the given number of seconds"
  def set_rate_limit(source, credential_name, seconds) do
    GenServer.call(__MODULE__, {:set_rate_limit, source, credential_name, seconds})
  end

  @doc "Mark a credential as expired (auth failure). Stores hash of credential value to detect updates."
  def set_expired(source, credential_name, credential_value) do
    value_hash = hash_value(credential_value)
    GenServer.call(__MODULE__, {:set_expired, source, credential_name, value_hash})
  end

  @doc """
  Check if a credential is expired but with a different value (meaning user updated it).
  Returns true if the credential was expired with a different value hash.
  """
  def credential_value_changed?(source, credential_name, credential_value) do
    value_hash = hash_value(credential_value)
    GenServer.call(__MODULE__, {:credential_value_changed?, source, credential_name, value_hash})
  end

  defp hash_value(nil), do: nil
  defp hash_value(""), do: nil

  defp hash_value(value) do
    :crypto.hash(:sha256, value) |> Base.encode64()
  end

  @doc "Clear rate limit for a credential (for manual override or rate limit expiry)"
  def clear_rate_limit(source, credential_name) do
    GenServer.call(__MODULE__, {:clear_rate_limit, source, credential_name})
  end

  @doc """
  Get all rate limits for UI display.
  Returns: %{award: [%{name: "", rate_limited_until: nil | DateTime, expired: false}], offers: [...]}
  """
  def get_all_statuses do
    GenServer.call(__MODULE__, :get_all_statuses)
  end

  # Server Implementation

  @impl true
  def init(_opts) do
    # Load existing rate limits from CSV on startup
    rate_limits = load_from_csv()
    # Clean up expired rate limits (but keep expired auth entries)
    rate_limits = cleanup_expired_rate_limits(rate_limits)
    # Persist cleaned state
    save_to_csv(rate_limits)
    {:ok, %{rate_limits: rate_limits}}
  end

  @impl true
  def handle_call({:get_rate_limits, source}, _from, state) do
    source_str = Atom.to_string(source)

    limits =
      state.rate_limits
      |> Enum.filter(fn entry -> entry.source == source_str end)
      |> Enum.map(&entry_to_status/1)

    {:reply, limits, state}
  end

  @impl true
  def handle_call({:check_credential, source, credential_name}, _from, state) do
    source_str = Atom.to_string(source)

    result =
      case find_entry(state.rate_limits, source_str, credential_name) do
        nil ->
          :ok

        entry ->
          cond do
            entry.expired ->
              :expired

            entry.rate_limited_until == nil ->
              :ok

            true ->
              now = DateTime.utc_now()

              case DateTime.compare(now, entry.rate_limited_until) do
                :lt ->
                  seconds_remaining = DateTime.diff(entry.rate_limited_until, now)
                  {:rate_limited, seconds_remaining}

                _ ->
                  :ok
              end
          end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:set_rate_limit, source, credential_name, seconds}, _from, state) do
    source_str = Atom.to_string(source)
    rate_limited_until = DateTime.add(DateTime.utc_now(), seconds, :second)

    new_limits =
      upsert_entry(state.rate_limits, source_str, credential_name, %{
        rate_limited_until: rate_limited_until,
        expired: false
      })

    save_to_csv(new_limits)

    Logger.info(
      "Persisted rate limit for #{source}/#{credential_name} until #{rate_limited_until}"
    )

    {:reply, :ok, %{state | rate_limits: new_limits}}
  end

  @impl true
  def handle_call({:set_expired, source, credential_name, value_hash}, _from, state) do
    source_str = Atom.to_string(source)

    new_limits =
      upsert_entry(state.rate_limits, source_str, credential_name, %{
        rate_limited_until: nil,
        expired: true,
        value_hash: value_hash
      })

    save_to_csv(new_limits)
    Logger.info("Persisted credential expiration for #{source}/#{credential_name}")
    {:reply, :ok, %{state | rate_limits: new_limits}}
  end

  @impl true
  def handle_call(
        {:credential_value_changed?, source, credential_name, current_hash},
        _from,
        state
      ) do
    source_str = Atom.to_string(source)

    result =
      case find_entry(state.rate_limits, source_str, credential_name) do
        nil ->
          false

        entry ->
          # Only consider it "changed" if the credential is expired and has a different hash
          entry.expired && entry.value_hash != nil && entry.value_hash != current_hash
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:clear_rate_limit, source, credential_name}, _from, state) do
    source_str = Atom.to_string(source)

    new_limits =
      state.rate_limits
      |> Enum.reject(fn entry ->
        entry.source == source_str && entry.credential_name == credential_name
      end)

    save_to_csv(new_limits)
    Logger.info("Cleared rate limit for #{source}/#{credential_name}")
    {:reply, :ok, %{state | rate_limits: new_limits}}
  end

  @impl true
  def handle_call(:get_all_statuses, _from, state) do
    statuses = %{
      award:
        state.rate_limits
        |> Enum.filter(fn entry -> entry.source == "award" end)
        |> Enum.map(&entry_to_status/1),
      offers:
        state.rate_limits
        |> Enum.filter(fn entry -> entry.source == "offers" end)
        |> Enum.map(&entry_to_status/1)
    }

    {:reply, statuses, state}
  end

  # Private functions

  defp load_from_csv do
    case File.read(rate_limits_file()) do
      {:ok, content} ->
        parse_csv(content)

      {:error, :enoent} ->
        Logger.info("No rate_limits.csv found, starting fresh")
        []

      {:error, reason} ->
        Logger.warning("Failed to read rate_limits.csv: #{inspect(reason)}, starting fresh")
        []
    end
  end

  defp parse_csv(content) do
    lines = String.split(content, "\n", trim: true)

    case lines do
      [] ->
        []

      [_header | data_lines] ->
        data_lines
        |> Enum.map(&parse_csv_line/1)
        |> Enum.reject(&is_nil/1)
    end
  rescue
    e ->
      Logger.warning("Failed to parse rate_limits.csv: #{inspect(e)}, starting fresh")
      []
  end

  defp parse_csv_line(line) do
    # Simple CSV parsing - handles quoted fields with commas
    parts = parse_csv_fields(line)

    case parts do
      # New format with value_hash
      [source, credential_name, rate_limited_until_str, expired_str, value_hash] ->
        %{
          source: source,
          credential_name: credential_name,
          rate_limited_until: parse_datetime(rate_limited_until_str),
          expired: parse_boolean(expired_str),
          value_hash: if(value_hash == "", do: nil, else: value_hash)
        }

      # Old format without value_hash (backward compatibility)
      [source, credential_name, rate_limited_until_str, expired_str] ->
        %{
          source: source,
          credential_name: credential_name,
          rate_limited_until: parse_datetime(rate_limited_until_str),
          expired: parse_boolean(expired_str),
          value_hash: nil
        }

      _ ->
        Logger.warning("Invalid CSV line: #{line}")
        nil
    end
  end

  defp parse_csv_fields(line) do
    # Handle CSV with potential quoted fields
    line
    |> String.split(",")
    |> Enum.map(&String.trim/1)
  end

  defp parse_datetime(""), do: nil
  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} ->
        dt

      {:error, _} ->
        Logger.warning("Failed to parse datetime: #{str}")
        nil
    end
  end

  defp parse_boolean("true"), do: true
  defp parse_boolean("false"), do: false
  defp parse_boolean(_), do: false

  defp save_to_csv(rate_limits) do
    header = Enum.join(@headers, ",")
    lines = Enum.map(rate_limits, &entry_to_csv_line/1)
    content = Enum.join([header | lines], "\n") <> "\n"

    case File.write(rate_limits_file(), content) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to write rate_limits.csv: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp entry_to_csv_line(entry) do
    rate_limited_str =
      case entry.rate_limited_until do
        nil -> ""
        dt -> DateTime.to_iso8601(dt)
      end

    Enum.join(
      [
        entry.source,
        entry.credential_name,
        rate_limited_str,
        to_string(entry.expired),
        entry.value_hash || ""
      ],
      ","
    )
  end

  defp find_entry(rate_limits, source, credential_name) do
    Enum.find(rate_limits, fn entry ->
      entry.source == source && entry.credential_name == credential_name
    end)
  end

  defp upsert_entry(rate_limits, source, credential_name, updates) do
    case find_entry(rate_limits, source, credential_name) do
      nil ->
        # Add new entry
        new_entry =
          Map.merge(
            %{
              source: source,
              credential_name: credential_name,
              rate_limited_until: nil,
              expired: false,
              value_hash: nil
            },
            updates
          )

        [new_entry | rate_limits]

      _existing ->
        # Update existing entry
        Enum.map(rate_limits, fn entry ->
          if entry.source == source && entry.credential_name == credential_name do
            Map.merge(entry, updates)
          else
            entry
          end
        end)
    end
  end

  defp cleanup_expired_rate_limits(rate_limits) do
    now = DateTime.utc_now()

    Enum.filter(rate_limits, fn entry ->
      cond do
        # Keep expired auth entries
        entry.expired -> true
        # Remove entries with no rate limit
        entry.rate_limited_until == nil -> false
        # Keep active rate limits, remove expired ones
        DateTime.compare(now, entry.rate_limited_until) == :lt -> true
        true -> false
      end
    end)
  end

  defp entry_to_status(entry) do
    %{
      name: entry.credential_name,
      rate_limited_until: entry.rate_limited_until,
      expired: entry.expired
    }
  end
end
