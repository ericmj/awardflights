defmodule Awardflights.CsvWriter do
  @moduledoc """
  Thread-safe CSV writer for scan results and failed requests.
  Uses a GenServer to serialize file writes.
  """
  use GenServer

  @results_headers ~w(source departure arrival date booking_class cabin available_tickets points carriers timestamp)
  @failed_headers ~w(source origin destination date error timestamp)

  defp results_file, do: Application.get_env(:awardflights, :results_file, "results.csv")
  defp failed_file, do: Application.get_env(:awardflights, :failed_file, "failed_requests.csv")

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Write a flight result to the results CSV.
  """
  def write_result(result) do
    GenServer.cast(__MODULE__, {:write_result, result})
  end

  @doc """
  Write multiple flight results to the results CSV.
  Aggregates results with same source/route/date/cabin/class/points by summing available seats.
  """
  def write_results(results) when is_list(results) do
    results
    |> Enum.group_by(fn r ->
      {Map.get(r, :source, :award), r.departure, r.arrival, r.date, r.booking_class, r.cabin,
       r.points}
    end)
    |> Enum.map(fn {_key, group} ->
      first = hd(group)
      total_seats = Enum.sum(Enum.map(group, & &1.available_tickets))
      %{first | available_tickets: total_seats}
    end)
    |> Enum.each(&write_result/1)
  end

  @doc """
  Log a failed request to the failed requests CSV.
  Source defaults to :award for backward compatibility.
  """
  def write_failed(source \\ :award, origin, destination, date, error) do
    GenServer.cast(__MODULE__, {:write_failed, source, origin, destination, date, error})
  end

  @doc """
  Clear both CSV files (for starting a new scan).
  """
  def clear_files do
    GenServer.call(__MODULE__, :clear_files)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %{results_initialized: false, failed_initialized: false}}
  end

  @impl true
  def handle_cast({:write_result, result}, state) do
    state = ensure_results_header(state)
    upsert_result_row(result)
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
    {:reply, :ok, %{results_initialized: false, failed_initialized: false}}
  end

  # Private functions

  defp ensure_results_header(%{results_initialized: true} = state), do: state

  defp ensure_results_header(state) do
    unless File.exists?(results_file()) do
      write_header(results_file(), @results_headers)
    end

    %{state | results_initialized: true}
  end

  defp ensure_failed_header(%{failed_initialized: true} = state), do: state

  defp ensure_failed_header(state) do
    unless File.exists?(failed_file()) do
      write_header(failed_file(), @failed_headers)
    end

    %{state | failed_initialized: true}
  end

  defp write_header(file, headers) do
    line = Enum.join(headers, ",") <> "\n"
    File.write!(file, line)
  end

  # Upsert a result row - replaces existing row with same key (source, departure, arrival, date, booking_class, cabin)
  defp upsert_result_row(result) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    source = to_string(Map.get(result, :source) || :award)
    departure = to_string(result[:departure] || result.departure)
    arrival = to_string(result[:arrival] || result.arrival)
    date = to_string(result[:date] || result.date)
    booking_class = to_string(result[:booking_class] || result.booking_class)
    cabin = to_string(result[:cabin] || result.cabin)

    carriers = to_string(Map.get(result, :carriers, ""))

    new_row = [
      source,
      departure,
      arrival,
      date,
      booking_class,
      cabin,
      to_string(result[:available_tickets] || result.available_tickets),
      to_string(result[:points] || result.points),
      carriers,
      timestamp
    ]

    file = results_file()

    # Read existing rows, filter out duplicates, add new row
    existing_rows = read_csv_rows(file)

    # Filter out any row with matching key (source, departure, arrival, date, booking_class, cabin)
    filtered_rows =
      Enum.reject(existing_rows, fn row ->
        length(row) >= 6 and
          Enum.at(row, 0) == source and
          Enum.at(row, 1) == departure and
          Enum.at(row, 2) == arrival and
          Enum.at(row, 3) == date and
          Enum.at(row, 4) == booking_class and
          Enum.at(row, 5) == cabin
      end)

    # Write header + filtered rows + new row
    all_rows = filtered_rows ++ [new_row]
    write_csv_file(file, @results_headers, all_rows)
  end

  defp read_csv_rows(file) do
    if File.exists?(file) do
      file
      |> File.read!()
      |> String.split("\n", trim: true)
      # Skip header
      |> Enum.drop(1)
      |> Enum.map(&parse_csv_row/1)
    else
      []
    end
  end

  defp parse_csv_row(line) do
    # Simple CSV parsing (handles quoted fields)
    line
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn field ->
      # Remove surrounding quotes if present
      if String.starts_with?(field, "\"") and String.ends_with?(field, "\"") do
        field
        |> String.slice(1..-2//1)
        |> String.replace("\"\"", "\"")
      else
        field
      end
    end)
  end

  defp write_csv_file(file, headers, rows) do
    content =
      [Enum.join(headers, ",")] ++
        Enum.map(rows, fn row ->
          row
          |> Enum.map(&escape_csv_field/1)
          |> Enum.join(",")
        end)

    File.write!(file, Enum.join(content, "\n") <> "\n")
  end

  defp append_failed_row(source, origin, destination, date, error) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    row =
      [source, origin, destination, date, format_error(error), timestamp]
      |> Enum.map(&to_string/1)
      |> Enum.map(&escape_csv_field/1)
      |> Enum.join(",")

    File.write!(failed_file(), row <> "\n", [:append])
  end

  defp escape_csv_field(field) do
    if String.contains?(field, [",", "\"", "\n"]) do
      "\"" <> String.replace(field, "\"", "\"\"") <> "\""
    else
      field
    end
  end

  defp format_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_error({:http_error, status, _}), do: "http_#{status}"
  defp format_error({:request_failed, _}), do: "request_failed"
  defp format_error(error), do: inspect(error)
end
