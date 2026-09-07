defmodule Awardflights.CsvWriter do
  @moduledoc """
  Serialized writer for scan results and failed requests.

  results.csv holds one row per itinerary, cabin and booking class. Storing
  the results of a scan replaces every row previously stored for that source,
  route and date, so the file always reflects the latest scan of each query.
  """
  use GenServer

  alias Awardflights.{Csv, Itinerary}

  @results_headers ~w(source departure arrival date booking_class cabin available_tickets points carriers operating_carriers departure_time arrival_time duration segments stops timestamp)
  @failed_headers ~w(source origin destination date error timestamp)

  defp results_file, do: Application.get_env(:awardflights, :results_file, "results.csv")
  defp failed_file, do: Application.get_env(:awardflights, :failed_file, "failed_requests.csv")

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store the flights found for one scan query, replacing the rows previously
  stored for the same source, origin, destination and date.

  Results with the same itinerary, cabin, booking class and points are
  combined by summing their available seats.
  """
  def write_results(source, origin, destination, date, results) when is_list(results) do
    query = {to_string(source), origin, destination, to_string(date)}
    GenServer.cast(__MODULE__, {:write_results, query, aggregate(results)})
  end

  @doc """
  Log a failed request to the failed requests CSV. Source defaults to :award.
  """
  def write_failed(source \\ :award, origin, destination, date, error) do
    GenServer.cast(__MODULE__, {:write_failed, source, origin, destination, date, error})
  end

  @doc """
  Remove both CSV files (for starting a new scan).
  """
  def clear_files do
    GenServer.call(__MODULE__, :clear_files)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %{failed_initialized: false}}
  end

  @impl true
  def handle_cast({:write_results, query, results}, state) do
    replace_query_rows(query, results)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:write_failed, source, origin, destination, date, error}, state) do
    state = ensure_failed_header(state)
    append_failed_row(source, origin, destination, date, error)
    {:noreply, state}
  end

  @impl true
  def handle_call(:clear_files, _from, _state) do
    File.rm(results_file())
    File.rm(failed_file())
    {:reply, :ok, %{failed_initialized: false}}
  end

  # Private functions

  defp aggregate(results) do
    seats =
      results
      |> Enum.group_by(&aggregate_key/1, & &1.available_tickets)
      |> Map.new(fn {key, counts} -> {key, Enum.sum(counts)} end)

    results
    |> Enum.uniq_by(&aggregate_key/1)
    |> Enum.map(&%{&1 | available_tickets: seats[aggregate_key(&1)]})
  end

  defp aggregate_key(result) do
    {result.departure, result.arrival, result.date, result.booking_class, result.cabin,
     result.points, Map.get(result, :segments)}
  end

  defp replace_query_rows({source, origin, destination, date}, results) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    kept =
      results_file()
      |> read_rows()
      |> Enum.reject(&match?([^source, ^origin, ^destination, ^date | _], &1))

    rows = Enum.map(results, &result_row(source, &1, timestamp))
    File.write!(results_file(), Csv.dump_to_iodata([@results_headers | kept ++ rows]))
  end

  defp read_rows(file) do
    case File.read(file) do
      {:ok, content} -> Csv.parse_string(content)
      {:error, _} -> []
    end
  end

  defp result_row(source, result, timestamp) do
    [
      source,
      result.departure,
      result.arrival,
      result.date,
      result.booking_class,
      result.cabin,
      result.available_tickets,
      result.points,
      Map.get(result, :carriers),
      Map.get(result, :operating_carriers),
      Map.get(result, :departure_time),
      Map.get(result, :arrival_time),
      Map.get(result, :duration),
      Itinerary.encode_segments(Map.get(result, :segments)),
      Itinerary.encode_stops(Map.get(result, :stops)),
      timestamp
    ]
  end

  defp ensure_failed_header(%{failed_initialized: true} = state), do: state

  defp ensure_failed_header(state) do
    unless File.exists?(failed_file()) do
      File.write!(failed_file(), Csv.dump_to_iodata([@failed_headers]))
    end

    %{state | failed_initialized: true}
  end

  defp append_failed_row(source, origin, destination, date, error) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    row = [source, origin, destination, date, format_error(error), timestamp]
    File.write!(failed_file(), Csv.dump_to_iodata([row]), [:append])
  end

  defp format_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_error({:http_error, status, _}), do: "http_#{status}"
  defp format_error({:request_failed, _}), do: "request_failed"
  defp format_error(error), do: inspect(error)
end
