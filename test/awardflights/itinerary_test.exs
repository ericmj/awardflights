defmodule Awardflights.ItineraryTest do
  use ExUnit.Case, async: true

  alias Awardflights.Itinerary
  alias Awardflights.Itinerary.{Segment, Stop}

  @flight %{
    "origin" => %{"code" => "GOT"},
    "destination" => %{"code" => "EWR"},
    "connectionDuration" => "10:54:00",
    "startTimeInLocal" => "2026-09-04T10:05:00.000+02:00",
    "endTimeInLocal" => "2026-09-04T14:59:00.000-04:00",
    "stops" => 1,
    "via" => [%{"code" => "CPH", "name" => "Kastrup", "haltDuration" => "01:40:00"}],
    "segments" => [
      %{
        "flightNumber" => "443",
        "departureAirport" => %{"code" => "GOT", "name" => "Landvetter"},
        "arrivalAirport" => %{"code" => "CPH", "name" => "Kastrup"},
        "departureDateTimeInLocal" => "2026-09-04T10:05:00.000+02:00",
        "arrivalDateTimeInLocal" => "2026-09-04T10:50:00.000+02:00",
        "duration" => "00:45:00",
        "marketingCarrier" => %{"code" => "SK", "name" => "SAS"},
        "operatingCarrier" => %{"code" => "X1", "name" => "SAS Connect"}
      },
      %{
        "flightNumber" => "909",
        "departureAirport" => %{"code" => "CPH", "name" => "Kastrup"},
        "arrivalAirport" => %{"code" => "EWR", "name" => "Newark Liberty Intl "},
        "departureDateTimeInLocal" => "2026-09-04T12:30:00.000+02:00",
        "arrivalDateTimeInLocal" => "2026-09-04T14:59:00.000-04:00",
        "duration" => "08:29:00",
        "marketingCarrier" => %{"code" => "SK", "name" => "SAS"}
      }
    ]
  }

  @first_segment %Segment{
    flight_number: "SK443",
    departure: "GOT",
    arrival: "CPH",
    departure_time: "2026-09-04T10:05:00+02:00",
    arrival_time: "2026-09-04T10:50:00+02:00",
    duration: 45,
    marketing_carrier: "SAS",
    operating_carrier: "SAS Connect"
  }

  describe "from_flight/1" do
    test "extracts segments, stops, times, durations and carriers" do
      itinerary = Itinerary.from_flight(@flight)

      assert itinerary.departure_time == "2026-09-04T10:05:00+02:00"
      assert itinerary.arrival_time == "2026-09-04T14:59:00-04:00"
      assert itinerary.duration == 654
      assert itinerary.carriers == "SAS"
      assert itinerary.operating_carriers == "SAS Connect, SAS"

      assert [first, second] = itinerary.segments
      assert first == @first_segment
      assert second.flight_number == "SK909"
      assert second.departure == "CPH"
      assert second.arrival == "EWR"
      assert second.duration == 509
      assert second.marketing_carrier == "SAS"
      assert second.operating_carrier == "SAS"

      assert itinerary.stops == [%Stop{airport: "CPH", duration: 100}]
    end

    test "computes durations and layovers from segment times when the API omits them" do
      flight =
        @flight
        |> Map.drop(["connectionDuration", "via", "startTimeInLocal", "endTimeInLocal"])
        |> update_in(["segments"], fn segments ->
          Enum.map(segments, &Map.delete(&1, "duration"))
        end)

      itinerary = Itinerary.from_flight(flight)

      assert itinerary.duration == 654
      assert itinerary.departure_time == "2026-09-04T10:05:00+02:00"
      assert itinerary.arrival_time == "2026-09-04T14:59:00-04:00"
      assert Enum.map(itinerary.segments, & &1.duration) == [45, 509]
      assert itinerary.stops == [%Stop{airport: "CPH", duration: 100}]
    end

    test "falls back to via halt durations when segment times are missing" do
      flight =
        update_in(@flight, ["segments"], fn segments ->
          Enum.map(
            segments,
            &Map.drop(&1, ["departureDateTimeInLocal", "arrivalDateTimeInLocal", "duration"])
          )
        end)

      itinerary = Itinerary.from_flight(flight)

      assert itinerary.stops == [%Stop{airport: "CPH", duration: 100}]
      assert Enum.map(itinerary.segments, & &1.duration) == [nil, nil]
      assert itinerary.duration == 654
    end

    test "handles flights without segment data" do
      assert Itinerary.from_flight(%{}) == %{
               carriers: "",
               operating_carriers: "",
               departure_time: nil,
               arrival_time: nil,
               duration: nil,
               segments: [],
               stops: []
             }
    end

    test "uses the marketing carrier as operator when no operating carrier is given" do
      itinerary =
        Itinerary.from_flight(%{
          "segments" => [%{"marketingCarrier" => %{"name" => "Virgin Atlantic"}}]
        })

      assert itinerary.carriers == "Virgin Atlantic"
      assert itinerary.operating_carriers == "Virgin Atlantic"

      assert [%Segment{flight_number: nil, operating_carrier: "Virgin Atlantic"}] =
               itinerary.segments

      assert itinerary.stops == []
    end
  end

  # The award-api states local times without a UTC offset and durations as
  # "2h 20m", and puts the layover on the segment. Captured live, GOT-ORD.
  @award_flight %{
    "origin" => %{"code" => "GOT"},
    "destination" => %{"code" => "ORD"},
    "connectionDuration" => "16h 15m",
    "totalDuration" => "16h 15m",
    "startTimeInLocal" => "05:55",
    "endTimeInLocal" => "15:10",
    "startDateTimeInLocal" => "2026-10-15T05:55:00",
    "endDateTimeInLocal" => "2026-10-15T15:10:00",
    "stops" => 1,
    "via" => [%{"code" => "CDG", "name" => "Charles De Gaulle", "haltDuration" => "4h 55m"}],
    "segments" => [
      %{
        "flightNumber" => "1553",
        "departureAirport" => %{"code" => "GOT"},
        "arrivalAirport" => %{"code" => "CDG"},
        "departureDateTimeInLocal" => "2026-10-15T05:55:00",
        "arrivalDateTimeInLocal" => "2026-10-15T08:15:00",
        "duration" => "2h 20m",
        "layoverDuration" => "4h 55m",
        "marketingCarrier" => %{"code" => "AF", "name" => "Air France"},
        "operatingCarrier" => %{"code" => "A5", "name" => "Air France Hop"}
      },
      %{
        "flightNumber" => "136",
        "departureAirport" => %{"code" => "CDG"},
        "arrivalAirport" => %{"code" => "ORD"},
        "departureDateTimeInLocal" => "2026-10-15T13:10:00",
        "arrivalDateTimeInLocal" => "2026-10-15T15:10:00",
        "duration" => "9h",
        "layoverDuration" => "",
        "marketingCarrier" => %{"code" => "AF", "name" => "Air France"},
        "operatingCarrier" => %{"code" => "AF", "name" => "Air France"}
      }
    ]
  }

  describe "from_flight/1 with award-api times and durations" do
    test "parses local times without an offset and \"2h 20m\" durations" do
      itinerary = Itinerary.from_flight(@award_flight)

      assert itinerary.departure_time == "2026-10-15T05:55:00"
      assert itinerary.arrival_time == "2026-10-15T15:10:00"
      assert itinerary.duration == 975
      assert itinerary.carriers == "Air France"
      assert itinerary.operating_carriers == "Air France Hop, Air France"

      assert [first, second] = itinerary.segments
      assert first.flight_number == "AF1553"
      assert first.departure_time == "2026-10-15T05:55:00"
      assert first.duration == 140
      assert first.operating_carrier == "Air France Hop"
      assert second.duration == 540

      assert itinerary.stops == [%Stop{airport: "CDG", duration: 295}]
    end

    test "formats an award itinerary" do
      itinerary =
        @award_flight
        |> Itinerary.from_flight()
        |> Map.merge(%{departure: "GOT", arrival: "ORD"})

      assert Itinerary.route(itinerary) == "GOT → CDG → ORD"
      assert Itinerary.format_duration(itinerary.duration) == "16h 15m"
      assert Itinerary.describe_stops(itinerary) == "CDG 4h 55m"

      assert Itinerary.describe_segments(itinerary) ==
               "AF1553 GOT 05:55 → CDG 08:15 (2h 20m, Air France Hop); AF136 CDG 13:10 → ORD 15:10 (9h, Air France)"
    end

    test "takes the layover from the segment, then the via entry, then the ground time" do
      drop = fn flight, key ->
        update_in(flight, ["segments"], &Enum.map(&1, fn s -> Map.delete(s, key) end))
      end

      via_only = drop.(@award_flight, "layoverDuration")
      assert Itinerary.from_flight(via_only).stops == [%Stop{airport: "CDG", duration: 295}]

      computed = via_only |> Map.delete("via") |> Map.put("stops", 1)
      assert Itinerary.from_flight(computed).stops == [%Stop{airport: "CDG", duration: 295}]
    end

    test "states no duration it cannot derive, rather than subtracting local times in two zones" do
      flight =
        @award_flight
        |> Map.drop(["totalDuration", "connectionDuration"])
        |> update_in(["segments"], &Enum.map(&1, fn s -> Map.delete(s, "duration") end))

      itinerary = Itinerary.from_flight(flight)

      assert itinerary.duration == nil
      assert Enum.map(itinerary.segments, & &1.duration) == [nil, nil]
      assert itinerary.stops == [%Stop{airport: "CDG", duration: 295}]
    end
  end

  describe "parsing durations" do
    test "accepts both the clock and the unit form" do
      for {input, expected} <- [
            {"10:54:00", 654},
            {"00:45:00", 45},
            {"16h 15m", 975},
            {"9h", 540},
            {"45m", 45},
            {"", nil},
            {"soon", nil}
          ] do
        flight = %{"segments" => [%{"duration" => input}]}
        assert [%Segment{duration: ^expected}] = Itinerary.from_flight(flight).segments
      end
    end
  end

  describe "CSV encoding" do
    test "round-trips segments and stops" do
      itinerary = Itinerary.from_flight(@flight)
      encoded = Itinerary.encode_segments(itinerary.segments)

      assert encoded ==
               "SK443|GOT|CPH|2026-09-04T10:05:00+02:00|2026-09-04T10:50:00+02:00|45|SAS|SAS Connect;" <>
                 "SK909|CPH|EWR|2026-09-04T12:30:00+02:00|2026-09-04T14:59:00-04:00|509|SAS|SAS"

      assert Itinerary.decode_segments(encoded) == itinerary.segments

      assert Itinerary.encode_stops(itinerary.stops) == "CPH|100"
      assert Itinerary.decode_stops("CPH|100") == itinerary.stops
    end

    test "encodes missing values as empty fields" do
      segment = %Segment{flight_number: "SK1", departure: "GOT", arrival: "CDG"}

      assert Itinerary.encode_segments([segment]) == "SK1|GOT|CDG|||||"
      assert Itinerary.decode_segments("SK1|GOT|CDG|||||") == [segment]
    end

    test "treats blank and missing columns as no data" do
      assert Itinerary.encode_segments(nil) == ""
      assert Itinerary.encode_stops([]) == ""
      assert Itinerary.decode_segments("") == []
      assert Itinerary.decode_segments(nil) == []
      assert Itinerary.decode_stops(nil) == []
    end
  end

  describe "formatting" do
    test "format_duration/1" do
      assert Itinerary.format_duration(nil) == ""
      assert Itinerary.format_duration(45) == "45m"
      assert Itinerary.format_duration(120) == "2h"
      assert Itinerary.format_duration(654) == "10h 54m"
    end

    test "format_time/2 shows the local time and marks later days" do
      assert Itinerary.format_time("2026-09-04T10:05:00+02:00") == "10:05"

      assert Itinerary.format_time("2026-09-05T06:15:00+01:00", "2026-09-04T22:30:00+02:00") ==
               "06:15+1"

      assert Itinerary.format_time("2026-09-04T14:59:00-04:00", "2026-09-04T10:05:00+02:00") ==
               "14:59"

      assert Itinerary.format_time(nil) == ""
    end

    test "route/1 includes stop airports" do
      flight = Map.merge(Itinerary.from_flight(@flight), %{departure: "GOT", arrival: "EWR"})

      assert Itinerary.route(flight) == "GOT → CPH → EWR"
      assert Itinerary.route(%{departure: "GOT", arrival: "CDG", stops: []}) == "GOT → CDG"
    end

    test "describe_segments/1 and describe_stops/1" do
      flight = Itinerary.from_flight(@flight)

      assert Itinerary.describe_segments(flight) ==
               "SK443 GOT 10:05 → CPH 10:50 (45m, SAS Connect); SK909 CPH 12:30 → EWR 14:59 (8h 29m, SAS)"

      assert Itinerary.describe_stops(flight) == "CPH 1h 40m"
      assert Itinerary.describe_stops(%{stops: []}) == ""
    end
  end
end
