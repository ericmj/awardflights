defmodule Awardflights.RequestTracker do
  @moduledoc """
  Tracks successful API requests in a CSV file to avoid duplicate scans.
  Persists across application restarts.
  """
  use GenServer

  @headers ~w(source origin destination date scanned_at)

  defp history_file, do: Application.get_env(:awardflights, :history_file, "request_history.csv")

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a successful request.
  Source defaults to :award for backward compatibility.
  """
  def record_success(source \\ :award, origin, destination, date) do
    GenServer.call(__MODULE__, {:record_success, source, origin, destination, date})
  end

  @doc """
  Check if a request was already done within the last N days.
  Returns true if it should be skipped.
  Source defaults to :award for backward compatibility.
  """
  def should_skip?(source \\ :award, origin, destination, date, skip_days)

  def should_skip?(source, origin, destination, date, skip_days) when skip_days > 0 do
    GenServer.call(__MODULE__, {:should_skip?, source, origin, destination, date, skip_days})
  end

  def should_skip?(_source, _origin, _destination, _date, _skip_days), do: false

  @doc """
  Get count of requests that would be skipped for given parameters.
  Source defaults to :award for backward compatibility.
  """
  def count_skippable(source \\ :award, origins, destinations, dates, skip_days) do
    GenServer.call(
      __MODULE__,
      {:count_skippable, source, origins, destinations, dates, skip_days}
    )
  end

  @doc """
  Clear all history.
  """
  def clear_history do
    GenServer.call(__MODULE__, :clear_history)
  end

  @doc """
  Get all history entries.
  """
  def get_history do
    GenServer.call(__MODULE__, :get_history)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    history = load_history()
    {:ok, %{history: history}}
  end

  @impl true
  def handle_call({:record_success, source, origin, destination, date}, _from, state) do
    scanned_at = DateTime.utc_now() |> DateTime.to_iso8601()

    entry = %{
      source: source,
      origin: origin,
      destination: destination,
      date: date,
      scanned_at: scanned_at
    }

    # Update in-memory state with source as part of key
    key = {source, origin, destination, date}
    new_history = Map.put(state.history, key, scanned_at)

    # Append to CSV
    append_to_csv(entry)

    {:reply, :ok, %{state | history: new_history}}
  end

  @impl true
  def handle_call({:should_skip?, source, origin, destination, date, skip_days}, _from, state) do
    key = {source, origin, destination, date}

    result =
      case Map.get(state.history, key) do
        nil ->
          false

        scanned_at_str ->
          case DateTime.from_iso8601(scanned_at_str) do
            {:ok, scanned_at, _} ->
              days_ago = DateTime.diff(DateTime.utc_now(), scanned_at, :day)
              days_ago < skip_days

            _ ->
              false
          end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(
        {:count_skippable, source, origins, destinations, dates, skip_days},
        _from,
        state
      ) do
    count =
      for origin <- origins,
          destination <- destinations,
          date <- dates,
          origin != destination,
          reduce: 0 do
        acc ->
          key = {source, origin, destination, date}

          case Map.get(state.history, key) do
            nil ->
              acc

            scanned_at_str ->
              case DateTime.from_iso8601(scanned_at_str) do
                {:ok, scanned_at, _} ->
                  days_ago = DateTime.diff(DateTime.utc_now(), scanned_at, :day)
                  if days_ago < skip_days, do: acc + 1, else: acc

                _ ->
                  acc
              end
          end
      end

    {:reply, count, state}
  end

  @impl true
  def handle_call(:clear_history, _from, _state) do
    File.rm(history_file())
    {:reply, :ok, %{history: %{}}}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, state.history, state}
  end

  # Private functions

  defp load_history do
    if File.exists?(history_file()) do
      history_file()
      |> File.read!()
      |> String.split("\n", trim: true)
      # Skip header
      |> Enum.drop(1)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ",") do
          # New format: source, origin, destination, date, scanned_at
          [source, origin, destination, date, scanned_at | _] when source in ["award", "offers"] ->
            key = {String.to_existing_atom(source), origin, destination, date}
            update_history_entry(acc, key, scanned_at)

          # Old format: origin, destination, date, scanned_at (default to :award)
          [origin, destination, date, scanned_at | _] ->
            key = {:award, origin, destination, date}
            update_history_entry(acc, key, scanned_at)

          _ ->
            acc
        end
      end)
    else
      %{}
    end
  end

  defp update_history_entry(acc, key, scanned_at) do
    # Keep the most recent scan time for each key
    case Map.get(acc, key) do
      nil ->
        Map.put(acc, key, scanned_at)

      existing ->
        if scanned_at > existing do
          Map.put(acc, key, scanned_at)
        else
          acc
        end
    end
  end

  defp append_to_csv(entry) do
    unless File.exists?(history_file()) do
      write_header()
    end

    row =
      [entry.source, entry.origin, entry.destination, entry.date, entry.scanned_at]
      |> Enum.map(&to_string/1)
      |> Enum.join(",")

    File.write!(history_file(), row <> "\n", [:append])
  end

  defp write_header do
    line = Enum.join(@headers, ",") <> "\n"
    File.write!(history_file(), line)
  end
end
