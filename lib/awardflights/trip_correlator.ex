defmodule Awardflights.TripCorrelator do
  @moduledoc """
  Correlates flight results from results.csv into round trip combinations.
  Matches outbound flights with valid return flights based on configurable criteria.
  """

  alias Awardflights.{Csv, Itinerary}

  defp results_file, do: Application.get_env(:awardflights, :results_file, "results.csv")
  defp trips_file, do: Application.get_env(:awardflights, :trips_file, "trips.csv")

  defmodule Flight do
    @moduledoc "Represents a single flight from results.csv"
    defstruct [
      :source,
      :departure,
      :arrival,
      :date,
      :booking_class,
      :cabin,
      :available_tickets,
      :points,
      :carriers,
      :operating_carriers,
      :departure_time,
      :arrival_time,
      :duration,
      segments: [],
      stops: []
    ]
  end

  defmodule Trip do
    @moduledoc "Represents a round trip (outbound + return flights)"
    defstruct [:outbound, :return, :total_points, :trip_days]
  end

  @required_columns ~w(source departure arrival date booking_class cabin available_tickets points)

  @leg_columns ~w(source date route cabin class carriers seats operating_carriers departure_time arrival_time duration stops segments)
  @trips_headers Enum.map(@leg_columns, &"outbound_#{&1}") ++
                   Enum.map(@leg_columns, &"return_#{&1}") ++ ["trip_days"]

  @doc """
  Find round trips matching the given filter criteria.

  Options:
    - start_date: Start of date range for outbound flights (Date)
    - end_date: End of date range for outbound flights (Date)
    - min_trip_days: Minimum days between outbound and return
    - max_trip_days: Maximum days between outbound and return
    - outbound_departure: List of departure airports for outbound flights
    - outbound_arrival: List of arrival airports for outbound flights
    - return_departure: List of departure airports for return flights
    - return_arrival: List of arrival airports for return flights
    - cabin_classes: List of cabin classes to include (empty = all)
    - min_seats: Minimum available seats required (default 1)

  Returns a list of %Trip{} structs sorted by total points ascending.
  """
  def find_trips(opts) do
    flights = read_flights()

    outbound_flights = filter_outbound(flights, opts)
    return_flights = filter_return(flights, opts)

    correlate(outbound_flights, return_flights, opts)
    |> Enum.sort_by(& &1.outbound.date, Date)
  end

  @doc """
  Write trips to CSV file, overwriting any existing content.
  """
  def write_trips_csv(trips) do
    rows =
      Enum.map(trips, fn trip ->
        leg_columns(trip.outbound) ++ leg_columns(trip.return) ++ [trip.trip_days]
      end)

    File.write(trips_file(), Csv.dump_to_iodata([@trips_headers | rows]))
  end

  defp leg_columns(flight) do
    [
      format_source(flight.source),
      Date.to_string(flight.date),
      "#{flight.departure}-#{flight.arrival}",
      flight.cabin,
      flight.booking_class,
      flight.carriers,
      flight.available_tickets,
      flight.operating_carriers,
      Itinerary.format_time(flight.departure_time, flight.departure_time),
      Itinerary.format_time(flight.arrival_time, flight.departure_time),
      Itinerary.format_duration(flight.duration),
      Itinerary.describe_stops(flight),
      Itinerary.describe_segments(flight)
    ]
  end

  @doc """
  Read and parse all flights from results.csv.
  Returns a list of %Flight{} structs.
  """
  def read_flights do
    case File.read(results_file()) do
      {:ok, content} -> parse_csv(content)
      {:error, _} -> []
    end
  end

  defp parse_csv(content) do
    case Csv.parse_string(content, skip_headers: false) do
      [headers | rows] -> rows |> Enum.map(&parse_row(headers, &1)) |> Enum.reject(&is_nil/1)
      [] -> []
    end
  end

  defp parse_row(headers, row) do
    fields = headers |> Enum.zip(row) |> Map.new()

    if Enum.all?(@required_columns, &Map.has_key?(fields, &1)) do
      %Flight{
        source: fields["source"],
        departure: fields["departure"],
        arrival: fields["arrival"],
        date: parse_date(fields["date"]),
        booking_class: fields["booking_class"],
        cabin: resolve_cabin(fields["cabin"], fields["booking_class"]),
        available_tickets: parse_int(fields["available_tickets"]),
        points: parse_int(fields["points"]),
        carriers: fields["carriers"] || "",
        operating_carriers: fields["operating_carriers"] || "",
        departure_time: blank_to_nil(fields["departure_time"]),
        arrival_time: blank_to_nil(fields["arrival_time"]),
        duration: parse_optional_int(fields["duration"]),
        segments: Itinerary.decode_segments(fields["segments"]),
        stops: Itinerary.decode_stops(fields["stops"])
      }
    end
  end

  defp parse_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp parse_int(str), do: parse_optional_int(str) || 0

  defp parse_optional_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_optional_int(_), do: nil

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  @class_to_cabin %{
    "X" => "Economy",
    "N" => "Economy",
    "A" => "Economy",
    "I" => "Business",
    "O" => "Business",
    "G" => "Business"
  }

  @doc """
  Resolves cabin name from booking class when the API returned "unknown".
  Guessed cabins are suffixed with "?" to indicate uncertainty.
  """
  def format_source("offers"), do: "SAS"
  def format_source(_), do: "Partner"

  def resolve_cabin("unknown", booking_class) do
    case @class_to_cabin[booking_class] do
      nil -> "unknown"
      cabin -> cabin <> "?"
    end
  end

  def resolve_cabin(cabin, _booking_class), do: cabin

  defp filter_outbound(flights, opts) do
    flights
    |> filter_by_source(opts[:source])
    |> filter_by_airports(opts[:outbound_departure], opts[:outbound_arrival])
    |> filter_by_date_range(opts[:start_date], opts[:end_date])
    |> filter_by_cabin(opts[:cabin_classes])
    |> filter_by_min_seats(opts[:min_seats])
  end

  defp filter_return(flights, opts) do
    flights
    |> filter_by_source(opts[:source])
    |> filter_by_airports(opts[:return_departure], opts[:return_arrival])
    |> filter_by_cabin(opts[:cabin_classes])
    |> filter_by_min_seats(opts[:min_seats])
  end

  defp filter_by_airports(flights, departure_airports, arrival_airports) do
    flights
    |> filter_departure(departure_airports)
    |> filter_arrival(arrival_airports)
  end

  defp filter_departure(flights, nil), do: flights
  defp filter_departure(flights, []), do: flights

  defp filter_departure(flights, airports) do
    airports_set = MapSet.new(airports)
    Enum.filter(flights, &MapSet.member?(airports_set, &1.departure))
  end

  defp filter_arrival(flights, nil), do: flights
  defp filter_arrival(flights, []), do: flights

  defp filter_arrival(flights, airports) do
    airports_set = MapSet.new(airports)
    Enum.filter(flights, &MapSet.member?(airports_set, &1.arrival))
  end

  defp filter_by_date_range(flights, nil, nil), do: flights

  defp filter_by_date_range(flights, start_date, end_date) do
    Enum.filter(flights, fn flight ->
      flight.date != nil and
        (start_date == nil or Date.compare(flight.date, start_date) != :lt) and
        (end_date == nil or Date.compare(flight.date, end_date) != :gt)
    end)
  end

  defp filter_by_source(flights, nil), do: flights
  defp filter_by_source(flights, ""), do: flights
  defp filter_by_source(flights, source), do: Enum.filter(flights, &(&1.source == source))

  defp filter_by_cabin(flights, nil), do: flights
  defp filter_by_cabin(flights, []), do: flights

  defp filter_by_cabin(flights, cabins) do
    cabins_set = cabins |> Enum.map(&String.downcase/1) |> MapSet.new()

    Enum.filter(flights, fn flight ->
      flight.cabin
      |> String.trim_trailing("?")
      |> String.downcase()
      |> then(&MapSet.member?(cabins_set, &1))
    end)
  end

  defp filter_by_min_seats(flights, nil), do: flights
  defp filter_by_min_seats(flights, min) when min <= 1, do: flights

  defp filter_by_min_seats(flights, min_seats) do
    Enum.filter(flights, &(&1.available_tickets >= min_seats))
  end

  @doc """
  Correlate outbound flights with valid return flights.
  Returns a list of %Trip{} structs.
  """
  def correlate(outbound_flights, return_flights, opts) do
    min_days = opts[:min_trip_days] || 1
    max_days = opts[:max_trip_days] || 365

    for outbound <- outbound_flights,
        return <- return_flights,
        valid_return?(outbound, return, min_days, max_days) do
      trip_days = Date.diff(return.date, outbound.date)

      %Trip{
        outbound: outbound,
        return: return,
        total_points: outbound.points + return.points,
        trip_days: trip_days
      }
    end
  end

  defp valid_return?(outbound, return, min_days, max_days) do
    return.date != nil and
      outbound.date != nil and
      return.departure == outbound.arrival and
      return.arrival == outbound.departure and
      Date.diff(return.date, outbound.date) >= min_days and
      Date.diff(return.date, outbound.date) <= max_days
  end
end
