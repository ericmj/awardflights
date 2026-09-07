defmodule Awardflights.Itinerary do
  @moduledoc """
  Leg-by-leg details of a flight offer as returned by the SAS award-api and
  offers-api: every segment with its airports, local times, duration and
  carriers, plus the layover at each stop.

  The two APIs describe the same journey differently: the offers-api gives ISO
  8601 times with a UTC offset and `HH:MM:SS` durations, the award-api gives
  local times without an offset and durations like `2h 20m`. Both shapes are
  accepted and normalized here.

  Defines the compact encoding used for the `segments` and `stops` columns of
  results.csv (segments separated by `;`, fields by `|`) and the human-readable
  formatting used by the UI and trips.csv.
  """

  alias Awardflights.Itinerary.{Segment, Stop}

  @segment_fields [
    :flight_number,
    :departure,
    :arrival,
    :departure_time,
    :arrival_time,
    :duration,
    :marketing_carrier,
    :operating_carrier
  ]
  @stop_fields [:airport, :duration]

  @doc """
  Extract itinerary fields from an API flight map.

  Returns a map with `carriers`, `operating_carriers`, `departure_time`,
  `arrival_time`, `duration` (minutes), `segments` and `stops`, to be merged
  into a flight result. Durations come from the API when it states them and are
  otherwise computed from the times.
  """
  def from_flight(flight) when is_map(flight) do
    segments = flight |> Map.get("segments") |> List.wrap() |> Enum.map(&parse_segment/1)
    first = List.first(segments)
    last = List.last(segments)

    departure_time =
      time(flight, ["startDateTimeInLocal", "startTimeInLocal"]) ||
        (first && first.departure_time)

    arrival_time =
      time(flight, ["endDateTimeInLocal", "endTimeInLocal"]) || (last && last.arrival_time)

    %{
      carriers: join_names(segments, & &1.marketing_carrier),
      operating_carriers: join_names(segments, & &1.operating_carrier),
      departure_time: departure_time,
      arrival_time: arrival_time,
      duration:
        duration(flight, ["totalDuration", "connectionDuration"]) ||
          elapsed(departure_time, arrival_time),
      segments: segments,
      stops: build_stops(segments, List.wrap(flight["via"]))
    }
  end

  defp parse_segment(segment) when is_map(segment) do
    marketing = get_in(segment, ["marketingCarrier", "name"])
    departure_time = time(segment, ["departureDateTimeInLocal", "startTimeInLocal"])
    arrival_time = time(segment, ["arrivalDateTimeInLocal", "endTimeInLocal"])

    %Segment{
      flight_number: flight_number(segment),
      departure: get_in(segment, ["departureAirport", "code"]),
      arrival: get_in(segment, ["arrivalAirport", "code"]),
      departure_time: departure_time,
      arrival_time: arrival_time,
      duration: duration(segment, ["duration"]) || elapsed(departure_time, arrival_time),
      marketing_carrier: marketing,
      operating_carrier: get_in(segment, ["operatingCarrier", "name"]) || marketing,
      layover: duration(segment, ["layoverDuration"])
    }
  end

  defp parse_segment(_), do: %Segment{}

  defp flight_number(%{"flightNumber" => number} = segment) when not is_nil(number) do
    (get_in(segment, ["marketingCarrier", "code"]) || "") <> to_string(number)
  end

  defp flight_number(_), do: nil

  defp build_stops(segments, via) do
    segments
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index()
    |> Enum.map(fn {[arriving, departing], index} ->
      halt =
        case Enum.at(via, index) do
          %{} = halt -> halt
          _ -> %{}
        end

      %Stop{
        airport: arriving.arrival || halt["code"],
        duration:
          arriving.layover || duration(halt, ["haltDuration"]) ||
            on_the_ground(arriving.arrival_time, departing.departure_time)
      }
    end)
  end

  defp time(map, keys), do: Enum.find_value(keys, &normalize_time(map[&1]))

  defp duration(map, keys), do: Enum.find_value(keys, &parse_duration(map[&1]))

  defp join_names(segments, fun) do
    segments
    |> Enum.map(fun)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  # "2026-09-04T10:05:00.000+02:00" -> "2026-09-04T10:05:00+02:00", and a time
  # without an offset ("2026-10-15T05:55:00") is kept as local wall time.
  defp normalize_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, utc, offset} ->
        local = utc |> DateTime.add(offset, :second) |> DateTime.to_naive()
        NaiveDateTime.to_iso8601(NaiveDateTime.truncate(local, :second)) <> format_offset(offset)

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, local} -> NaiveDateTime.to_iso8601(NaiveDateTime.truncate(local, :second))
          _ -> nil
        end
    end
  end

  defp normalize_time(_), do: nil

  defp format_offset(offset) do
    sign = if offset < 0, do: "-", else: "+"
    minutes = div(abs(offset), 60)
    hours = minutes |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    rest = minutes |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{sign}#{hours}:#{rest}"
  end

  # "10:54:00" and "16h 15m" (also "9h", "45m") -> minutes
  defp parse_duration(value) when is_binary(value) do
    if String.contains?(value, ":"), do: parse_clock(value), else: parse_units(value)
  end

  defp parse_duration(_), do: nil

  defp parse_clock(value) do
    with [hours, minutes | _] <- String.split(value, ":"),
         {hours, ""} <- Integer.parse(hours),
         {minutes, ""} <- Integer.parse(minutes) do
      hours * 60 + minutes
    else
      _ -> nil
    end
  end

  defp parse_units(value) do
    case Regex.scan(~r/(\d+)\s*([hm])/, value) do
      [] ->
        nil

      matches ->
        Enum.reduce(matches, 0, fn
          [_, amount, "h"], total -> total + String.to_integer(amount) * 60
          [_, amount, "m"], total -> total + String.to_integer(amount)
        end)
    end
  end

  # Elapsed time between two points on earth, which is only unambiguous when
  # both carry a UTC offset. Local wall times in different time zones say
  # nothing about the time in between, so they yield no duration.
  defp elapsed(from, to) when is_binary(from) and is_binary(to) do
    with {:ok, from_dt, _} <- DateTime.from_iso8601(from),
         {:ok, to_dt, _} <- DateTime.from_iso8601(to) do
      div(DateTime.diff(to_dt, from_dt, :second), 60)
    else
      _ -> nil
    end
  end

  defp elapsed(_, _), do: nil

  # Time between arriving and departing at one airport, where local wall times
  # are in the same zone and so can be subtracted.
  defp on_the_ground(from, to) do
    case {local(from), local(to)} do
      {%NaiveDateTime{} = from, %NaiveDateTime{} = to} -> div(NaiveDateTime.diff(to, from), 60)
      _ -> nil
    end
  end

  @doc "Encode segments for the results.csv `segments` column."
  def encode_segments(segments), do: encode_list(segments, @segment_fields)

  @doc "Encode stops for the results.csv `stops` column."
  def encode_stops(stops), do: encode_list(stops, @stop_fields)

  @doc "Decode the results.csv `segments` column into `Segment` structs."
  def decode_segments(value), do: decode_list(value, Segment, @segment_fields)

  @doc "Decode the results.csv `stops` column into `Stop` structs."
  def decode_stops(value), do: decode_list(value, Stop, @stop_fields)

  defp encode_list(items, fields) do
    Enum.map_join(items || [], ";", fn item ->
      Enum.map_join(fields, "|", &field_to_string(Map.get(item, &1)))
    end)
  end

  defp decode_list(value, module, fields) when is_binary(value) and value != "" do
    value
    |> String.split(";")
    |> Enum.map(fn part ->
      attrs =
        fields
        |> Enum.zip(String.split(part, "|"))
        |> Map.new(fn
          {:duration, text} -> {:duration, parse_int(text)}
          {field, text} -> {field, blank_to_nil(text)}
        end)

      struct(module, attrs)
    end)
  end

  defp decode_list(_, _, _), do: []

  defp field_to_string(nil), do: ""
  defp field_to_string(value), do: to_string(value)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp parse_int(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> nil
    end
  end

  @doc ~S"""
  Route including the stop airports, e.g. `GOT → CPH → EWR`.
  """
  def route(flight) do
    via = flight |> stops() |> Enum.map(& &1.airport) |> Enum.reject(&is_nil/1)
    Enum.join([Map.get(flight, :departure)] ++ via ++ [Map.get(flight, :arrival)], " → ")
  end

  @doc "Format minutes as `10h 54m`, `2h` or `45m`."
  def format_duration(nil), do: ""

  def format_duration(minutes) when is_integer(minutes) do
    case {div(minutes, 60), rem(minutes, 60)} do
      {0, m} -> "#{m}m"
      {h, 0} -> "#{h}h"
      {h, m} -> "#{h}h #{m}m"
    end
  end

  @doc """
  Format an ISO 8601 local time as `HH:MM`, with a `+N` suffix when the local
  date is later than that of `base` (normally the itinerary's departure time).
  """
  def format_time(time, base \\ nil)
  def format_time(nil, _base), do: ""

  def format_time(time, base) do
    case {local(time), local(base)} do
      {nil, _} -> time
      {local, nil} -> Calendar.strftime(local, "%H:%M")
      {local, base_local} -> Calendar.strftime(local, "%H:%M") <> day_suffix(local, base_local)
    end
  end

  defp day_suffix(local, base_local) do
    case Date.diff(NaiveDateTime.to_date(local), NaiveDateTime.to_date(base_local)) do
      days when days > 0 -> "+#{days}"
      _ -> ""
    end
  end

  defp local(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, utc, offset} ->
        utc |> DateTime.add(offset, :second) |> DateTime.to_naive()

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, local} -> local
          _ -> nil
        end
    end
  end

  defp local(_), do: nil

  @doc ~S"""
  One-line description of a segment, e.g.
  `SK443 GOT 10:05 → CPH 10:50 (45m, SAS Connect)`.
  """
  def describe_segment(%Segment{} = segment, base \\ nil) do
    details =
      [format_duration(segment.duration), segment.operating_carrier]
      |> Enum.reject(&blank?/1)
      |> Enum.join(", ")

    route =
      [
        segment.flight_number,
        segment.departure,
        format_time(segment.departure_time, base),
        "→",
        segment.arrival,
        format_time(segment.arrival_time, base)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")

    if details == "", do: route, else: "#{route} (#{details})"
  end

  @doc "All segments of a flight on one line, separated by `; `."
  def describe_segments(flight) do
    base = Map.get(flight, :departure_time)
    flight |> segments() |> Enum.map_join("; ", &describe_segment(&1, base))
  end

  @doc "All stops of a flight on one line, e.g. `CPH 1h 40m; OSL 45m`. Empty for direct flights."
  def describe_stops(flight) do
    Enum.map_join(stops(flight), "; ", fn stop ->
      [stop.airport, format_duration(stop.duration)]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
    end)
  end

  defp segments(flight), do: Map.get(flight, :segments) || []
  defp stops(flight), do: Map.get(flight, :stops) || []

  defp blank?(value), do: value in [nil, ""]
end
