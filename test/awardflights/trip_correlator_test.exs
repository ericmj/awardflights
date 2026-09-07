defmodule Awardflights.TripCorrelatorTest do
  use ExUnit.Case, async: true

  alias Awardflights.{Csv, TripCorrelator}
  alias Awardflights.Itinerary.{Segment, Stop}
  alias Awardflights.TripCorrelator.Flight

  defp results_file, do: Application.get_env(:awardflights, :results_file, "results.csv")
  defp trips_file, do: Application.get_env(:awardflights, :trips_file, "trips.csv")

  setup do
    on_exit(fn ->
      File.rm(results_file())
      File.rm(trips_file())
    end)

    :ok
  end

  @headers "source,departure,arrival,date,booking_class,cabin,available_tickets,points,carriers,operating_carriers,departure_time,arrival_time,duration,segments,stops,timestamp"

  @segments "SK443|GOT|CPH|2026-02-01T10:05:00+01:00|2026-02-01T10:50:00+01:00|45|SAS|SAS Connect;" <>
              "SK909|CPH|EWR|2026-02-01T12:30:00+01:00|2026-02-01T14:59:00-05:00|509|SAS|SAS"

  defp full_row(departure, arrival, date, segments, stops) do
    [
      "award",
      departure,
      arrival,
      date,
      "X",
      "Economy",
      "5",
      "20000",
      "SAS",
      "SAS Connect, SAS",
      "#{date}T10:05:00+01:00",
      "#{date}T14:59:00-05:00",
      "654",
      segments,
      stops,
      "2026-01-18T10:00:00Z"
    ]
    |> then(&Csv.dump_to_iodata([&1]))
    |> IO.iodata_to_binary()
    |> String.trim_trailing("\n")
  end

  describe "read_flights/0" do
    test "returns empty list when file doesn't exist" do
      File.rm(results_file())
      assert TripCorrelator.read_flights() == []
    end

    test "parses CSV file into Flight structs" do
      csv_content = """
      source,departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      award,GOT,CDG,2026-02-01,X,Economy,5,20000,2026-01-18T10:00:00Z
      award,ARN,LHR,2026-02-05,Z,Business,2,75000,2026-01-18T10:00:00Z
      """

      File.write!(results_file(), csv_content)

      flights = TripCorrelator.read_flights()

      assert length(flights) == 2

      [flight1, flight2] = flights

      assert flight1.departure == "GOT"
      assert flight1.arrival == "CDG"
      assert flight1.date == ~D[2026-02-01]
      assert flight1.cabin == "Economy"
      assert flight1.points == 20000

      assert flight2.departure == "ARN"
      assert flight2.arrival == "LHR"
      assert flight2.date == ~D[2026-02-05]
      assert flight2.cabin == "Business"
      assert flight2.points == 75000
    end
  end

  describe "read_flights/0 itinerary columns" do
    test "parses segments, stops and itinerary fields" do
      File.write!(
        results_file(),
        Enum.join([@headers, full_row("GOT", "EWR", "2026-02-01", @segments, "CPH|100")], "\n") <>
          "\n"
      )

      assert [flight] = TripCorrelator.read_flights()

      assert flight.carriers == "SAS"
      assert flight.operating_carriers == "SAS Connect, SAS"
      assert flight.departure_time == "2026-02-01T10:05:00+01:00"
      assert flight.arrival_time == "2026-02-01T14:59:00-05:00"
      assert flight.duration == 654
      assert flight.stops == [%Stop{airport: "CPH", duration: 100}]

      assert [
               %Segment{flight_number: "SK443", operating_carrier: "SAS Connect", duration: 45},
               second
             ] = flight.segments

      assert second.flight_number == "SK909"
      assert second.arrival == "EWR"
    end

    test "leaves itinerary fields empty for rows without them" do
      File.write!(results_file(), """
      source,departure,arrival,date,booking_class,cabin,available_tickets,points,carriers,timestamp
      award,GOT,CDG,2026-02-01,X,Economy,5,20000,SAS,2026-01-18T10:00:00Z
      """)

      assert [flight] = TripCorrelator.read_flights()

      assert flight.carriers == "SAS"
      assert flight.operating_carriers == ""
      assert flight.departure_time == nil
      assert flight.duration == nil
      assert flight.segments == []
      assert flight.stops == []
    end

    test "reads quoted fields containing commas" do
      File.write!(results_file(), """
      source,departure,arrival,date,booking_class,cabin,available_tickets,points,carriers,timestamp
      award,GOT,CDG,2026-02-01,X,Economy,5,20000,"SAS, KLM",2026-01-18T10:00:00Z
      """)

      assert [flight] = TripCorrelator.read_flights()
      assert flight.carriers == "SAS, KLM"
    end

    test "skips rows missing required columns" do
      File.write!(results_file(), """
      departure,arrival,date
      GOT,CDG,2026-02-01
      """)

      assert TripCorrelator.read_flights() == []
    end
  end

  describe "write_trips_csv/1" do
    test "writes one row per trip with itinerary columns for both legs" do
      File.write!(
        results_file(),
        Enum.join(
          [
            @headers,
            full_row("GOT", "EWR", "2026-02-01", @segments, "CPH|100"),
            full_row(
              "EWR",
              "GOT",
              "2026-02-08",
              "SK910|EWR|GOT|2026-02-08T18:00:00-05:00|2026-02-09T08:30:00+01:00|510|SAS|SAS",
              ""
            )
          ],
          "\n"
        ) <> "\n"
      )

      trips = TripCorrelator.find_trips(min_trip_days: 5, max_trip_days: 10)
      assert length(trips) == 1

      assert :ok = TripCorrelator.write_trips_csv(trips)

      [headers, row] = trips_file() |> File.read!() |> Csv.parse_string(skip_headers: false)

      assert headers ==
               ~w(outbound_source outbound_date outbound_route outbound_cabin outbound_class outbound_carriers outbound_seats outbound_operating_carriers outbound_departure_time outbound_arrival_time outbound_duration outbound_stops outbound_segments return_source return_date return_route return_cabin return_class return_carriers return_seats return_operating_carriers return_departure_time return_arrival_time return_duration return_stops return_segments trip_days)

      assert row == [
               "Partner",
               "2026-02-01",
               "GOT-EWR",
               "Economy",
               "X",
               "SAS",
               "5",
               "SAS Connect, SAS",
               "10:05",
               "14:59",
               "10h 54m",
               "CPH 1h 40m",
               "SK443 GOT 10:05 → CPH 10:50 (45m, SAS Connect); SK909 CPH 12:30 → EWR 14:59 (8h 29m, SAS)",
               "Partner",
               "2026-02-08",
               "EWR-GOT",
               "Economy",
               "X",
               "SAS",
               "5",
               "SAS Connect, SAS",
               "10:05",
               "14:59",
               "10h 54m",
               "",
               "SK910 EWR 18:00 → GOT 08:30+1 (8h 30m, SAS)",
               "7"
             ]
    end

    test "quotes fields containing commas" do
      File.write!(results_file(), """
      source,departure,arrival,date,booking_class,cabin,available_tickets,points,carriers,timestamp
      award,GOT,CDG,2026-02-01,X,Economy,5,20000,"SAS, KLM",2026-01-18T10:00:00Z
      award,CDG,GOT,2026-02-08,X,Economy,5,20000,"KLM, SAS",2026-01-18T10:00:00Z
      """)

      trips = TripCorrelator.find_trips(min_trip_days: 5, max_trip_days: 10)
      assert :ok = TripCorrelator.write_trips_csv(trips)

      content = File.read!(trips_file())
      assert content =~ "\"SAS, KLM\""

      [_headers, row] = Csv.parse_string(content, skip_headers: false)
      assert Enum.at(row, 5) == "SAS, KLM"
      assert Enum.at(row, 18) == "KLM, SAS"
    end
  end

  describe "correlate/3" do
    test "matches outbound and return flights within date range" do
      outbound = [
        %Flight{
          departure: "GOT",
          arrival: "CDG",
          date: ~D[2026-02-01],
          cabin: "Economy",
          points: 20000
        }
      ]

      return = [
        %Flight{
          departure: "CDG",
          arrival: "GOT",
          date: ~D[2026-02-08],
          cabin: "Economy",
          points: 20000
        }
      ]

      opts = [min_trip_days: 5, max_trip_days: 10]
      trips = TripCorrelator.correlate(outbound, return, opts)

      assert length(trips) == 1
      [trip] = trips

      assert trip.outbound.departure == "GOT"
      assert trip.return.departure == "CDG"
      assert trip.total_points == 40000
      assert trip.trip_days == 7
    end

    test "excludes return flights outside date range" do
      outbound = [
        %Flight{
          departure: "GOT",
          arrival: "CDG",
          date: ~D[2026-02-01],
          cabin: "Economy",
          points: 20000
        }
      ]

      return = [
        %Flight{
          departure: "CDG",
          arrival: "GOT",
          date: ~D[2026-02-03],
          cabin: "Economy",
          points: 20000
        },
        %Flight{
          departure: "CDG",
          arrival: "GOT",
          date: ~D[2026-02-20],
          cabin: "Economy",
          points: 20000
        }
      ]

      opts = [min_trip_days: 5, max_trip_days: 10]
      trips = TripCorrelator.correlate(outbound, return, opts)

      assert trips == []
    end

    test "creates all valid combinations" do
      outbound = [
        %Flight{
          departure: "GOT",
          arrival: "CDG",
          date: ~D[2026-02-01],
          cabin: "Economy",
          points: 20000
        },
        %Flight{
          departure: "GOT",
          arrival: "CDG",
          date: ~D[2026-02-02],
          cabin: "Business",
          points: 50000
        }
      ]

      return = [
        %Flight{
          departure: "CDG",
          arrival: "GOT",
          date: ~D[2026-02-08],
          cabin: "Economy",
          points: 20000
        },
        %Flight{
          departure: "CDG",
          arrival: "GOT",
          date: ~D[2026-02-09],
          cabin: "Business",
          points: 50000
        }
      ]

      opts = [min_trip_days: 5, max_trip_days: 10]
      trips = TripCorrelator.correlate(outbound, return, opts)

      assert length(trips) == 4
    end
  end

  describe "resolve_cabin/2" do
    test "returns cabin as-is when not unknown" do
      assert TripCorrelator.resolve_cabin("Economy", "X") == "Economy"
      assert TripCorrelator.resolve_cabin("Business", "I") == "Business"
    end

    test "guesses cabin from booking class with ? suffix" do
      assert TripCorrelator.resolve_cabin("unknown", "X") == "Economy?"
      assert TripCorrelator.resolve_cabin("unknown", "N") == "Economy?"
      assert TripCorrelator.resolve_cabin("unknown", "A") == "Economy?"
      assert TripCorrelator.resolve_cabin("unknown", "I") == "Business?"
      assert TripCorrelator.resolve_cabin("unknown", "O") == "Business?"
      assert TripCorrelator.resolve_cabin("unknown", "G") == "Business?"
    end

    test "returns unknown for unmapped booking class" do
      assert TripCorrelator.resolve_cabin("unknown", "Z") == "unknown"
    end
  end

  describe "find_trips/1" do
    test "filters by departure airports" do
      csv_content = """
      source,departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      award,GOT,CDG,2026-02-01,X,Economy,5,20000,2026-01-18T10:00:00Z
      award,ARN,CDG,2026-02-01,X,Economy,5,22000,2026-01-18T10:00:00Z
      award,CDG,GOT,2026-02-08,X,Economy,5,20000,2026-01-18T10:00:00Z
      """

      File.write!(results_file(), csv_content)

      opts = [
        start_date: ~D[2026-02-01],
        end_date: ~D[2026-02-28],
        min_trip_days: 5,
        max_trip_days: 10,
        outbound_departure: ["GOT"],
        outbound_arrival: ["CDG"],
        return_departure: ["CDG"],
        return_arrival: ["GOT"]
      ]

      trips = TripCorrelator.find_trips(opts)

      assert length(trips) == 1
      [trip] = trips
      assert trip.outbound.departure == "GOT"
    end

    test "filters by cabin class" do
      csv_content = """
      source,departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      award,GOT,CDG,2026-02-01,X,Economy,5,20000,2026-01-18T10:00:00Z
      award,GOT,CDG,2026-02-01,Z,Business,2,75000,2026-01-18T10:00:00Z
      award,CDG,GOT,2026-02-08,X,Economy,5,20000,2026-01-18T10:00:00Z
      award,CDG,GOT,2026-02-08,Z,Business,2,75000,2026-01-18T10:00:00Z
      """

      File.write!(results_file(), csv_content)

      opts = [
        start_date: ~D[2026-02-01],
        end_date: ~D[2026-02-28],
        min_trip_days: 5,
        max_trip_days: 10,
        outbound_departure: ["GOT"],
        outbound_arrival: ["CDG"],
        return_departure: ["CDG"],
        return_arrival: ["GOT"],
        cabin_classes: ["Economy"]
      ]

      trips = TripCorrelator.find_trips(opts)

      assert length(trips) == 1
      [trip] = trips
      assert trip.outbound.cabin == "Economy"
      assert trip.return.cabin == "Economy"
    end

    test "filters by source" do
      csv_content = """
      source,departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      offers,GOT,CDG,2026-02-01,X,Economy,5,20000,2026-01-18T10:00:00Z
      award,GOT,CDG,2026-02-01,X,Economy,3,25000,2026-01-18T10:00:00Z
      offers,CDG,GOT,2026-02-08,X,Economy,5,20000,2026-01-18T10:00:00Z
      award,CDG,GOT,2026-02-08,X,Economy,3,25000,2026-01-18T10:00:00Z
      """

      File.write!(results_file(), csv_content)

      base_opts = [
        start_date: ~D[2026-02-01],
        end_date: ~D[2026-02-28],
        min_trip_days: 5,
        max_trip_days: 10,
        outbound_departure: ["GOT"],
        outbound_arrival: ["CDG"],
        return_departure: ["CDG"],
        return_arrival: ["GOT"]
      ]

      # All sources
      trips = TripCorrelator.find_trips(base_opts)
      assert length(trips) == 4

      # SAS only
      trips = TripCorrelator.find_trips(Keyword.put(base_opts, :source, "offers"))
      assert length(trips) == 1
      assert trips |> hd() |> Map.get(:outbound) |> Map.get(:source) == "offers"
      assert trips |> hd() |> Map.get(:return) |> Map.get(:source) == "offers"

      # Partner only
      trips = TripCorrelator.find_trips(Keyword.put(base_opts, :source, "award"))
      assert length(trips) == 1
      assert trips |> hd() |> Map.get(:outbound) |> Map.get(:source) == "award"
    end

    test "returns trips sorted by outbound date" do
      csv_content = """
      source,departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      award,GOT,CDG,2026-02-05,X,Economy,5,20000,2026-01-18T10:00:00Z
      award,GOT,CDG,2026-02-01,Z,Business,2,75000,2026-01-18T10:00:00Z
      award,CDG,GOT,2026-02-12,X,Economy,5,20000,2026-01-18T10:00:00Z
      award,CDG,GOT,2026-02-08,Z,Business,2,75000,2026-01-18T10:00:00Z
      """

      File.write!(results_file(), csv_content)

      opts = [
        start_date: ~D[2026-02-01],
        end_date: ~D[2026-02-28],
        min_trip_days: 5,
        max_trip_days: 10,
        outbound_departure: ["GOT"],
        outbound_arrival: ["CDG"],
        return_departure: ["CDG"],
        return_arrival: ["GOT"]
      ]

      trips = TripCorrelator.find_trips(opts)

      dates = Enum.map(trips, & &1.outbound.date)
      assert dates == Enum.sort(dates, Date)
    end

    test "cabin filter matches guessed cabins" do
      csv_content = """
      source,departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      award,GOT,CDG,2026-02-01,X,unknown,5,20000,2026-01-18T10:00:00Z
      award,GOT,CDG,2026-02-01,I,unknown,2,75000,2026-01-18T10:00:00Z
      award,CDG,GOT,2026-02-08,X,unknown,5,20000,2026-01-18T10:00:00Z
      award,CDG,GOT,2026-02-08,I,unknown,2,75000,2026-01-18T10:00:00Z
      """

      File.write!(results_file(), csv_content)

      opts = [
        start_date: ~D[2026-02-01],
        end_date: ~D[2026-02-28],
        min_trip_days: 5,
        max_trip_days: 10,
        outbound_departure: ["GOT"],
        outbound_arrival: ["CDG"],
        return_departure: ["CDG"],
        return_arrival: ["GOT"],
        cabin_classes: ["Economy"]
      ]

      trips = TripCorrelator.find_trips(opts)

      assert length(trips) == 1
      [trip] = trips
      assert trip.outbound.cabin == "Economy?"
      assert trip.return.cabin == "Economy?"
    end

    test "filters by date range" do
      csv_content = """
      source,departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      award,GOT,CDG,2026-01-15,X,Economy,5,20000,2026-01-18T10:00:00Z
      award,GOT,CDG,2026-02-01,X,Economy,5,20000,2026-01-18T10:00:00Z
      award,GOT,CDG,2026-03-15,X,Economy,5,20000,2026-01-18T10:00:00Z
      award,CDG,GOT,2026-01-22,X,Economy,5,20000,2026-01-18T10:00:00Z
      award,CDG,GOT,2026-02-08,X,Economy,5,20000,2026-01-18T10:00:00Z
      award,CDG,GOT,2026-03-22,X,Economy,5,20000,2026-01-18T10:00:00Z
      """

      File.write!(results_file(), csv_content)

      opts = [
        start_date: ~D[2026-02-01],
        end_date: ~D[2026-02-28],
        min_trip_days: 5,
        max_trip_days: 10,
        outbound_departure: ["GOT"],
        outbound_arrival: ["CDG"],
        return_departure: ["CDG"],
        return_arrival: ["GOT"]
      ]

      trips = TripCorrelator.find_trips(opts)

      assert length(trips) == 1
      [trip] = trips
      assert trip.outbound.date == ~D[2026-02-01]
    end

    test "supports multiple airports" do
      csv_content = """
      source,departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      award,GOT,CDG,2026-02-01,X,Economy,5,20000,2026-01-18T10:00:00Z
      award,ARN,LHR,2026-02-01,X,Economy,5,22000,2026-01-18T10:00:00Z
      award,CDG,GOT,2026-02-08,X,Economy,5,20000,2026-01-18T10:00:00Z
      award,LHR,ARN,2026-02-08,X,Economy,5,22000,2026-01-18T10:00:00Z
      """

      File.write!(results_file(), csv_content)

      opts = [
        start_date: ~D[2026-02-01],
        end_date: ~D[2026-02-28],
        min_trip_days: 5,
        max_trip_days: 10,
        outbound_departure: ["GOT", "ARN"],
        outbound_arrival: ["CDG", "LHR"],
        return_departure: ["CDG", "LHR"],
        return_arrival: ["GOT", "ARN"]
      ]

      trips = TripCorrelator.find_trips(opts)

      # Routes must reverse: GOT->CDG pairs only with CDG->GOT, ARN->LHR only with LHR->ARN
      assert length(trips) == 2
    end
  end
end
