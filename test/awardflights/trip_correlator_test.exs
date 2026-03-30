defmodule Awardflights.TripCorrelatorTest do
  use ExUnit.Case, async: true

  alias Awardflights.TripCorrelator
  alias Awardflights.TripCorrelator.Flight

  defp results_file, do: Application.get_env(:awardflights, :results_file, "results.csv")

  setup do
    on_exit(fn ->
      File.rm(results_file())
    end)

    :ok
  end

  describe "read_flights/0" do
    test "returns empty list when file doesn't exist" do
      File.rm(results_file())
      assert TripCorrelator.read_flights() == []
    end

    test "parses CSV file into Flight structs" do
      csv_content = """
      departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      GOT,CDG,2026-02-01,X,Economy,5,20000,2026-01-18T10:00:00Z
      ARN,LHR,2026-02-05,Z,Business,2,75000,2026-01-18T10:00:00Z
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
      departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      GOT,CDG,2026-02-01,X,Economy,5,20000,2026-01-18T10:00:00Z
      ARN,CDG,2026-02-01,X,Economy,5,22000,2026-01-18T10:00:00Z
      CDG,GOT,2026-02-08,X,Economy,5,20000,2026-01-18T10:00:00Z
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
      departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      GOT,CDG,2026-02-01,X,Economy,5,20000,2026-01-18T10:00:00Z
      GOT,CDG,2026-02-01,Z,Business,2,75000,2026-01-18T10:00:00Z
      CDG,GOT,2026-02-08,X,Economy,5,20000,2026-01-18T10:00:00Z
      CDG,GOT,2026-02-08,Z,Business,2,75000,2026-01-18T10:00:00Z
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
      departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      GOT,CDG,2026-02-05,X,Economy,5,20000,2026-01-18T10:00:00Z
      GOT,CDG,2026-02-01,Z,Business,2,75000,2026-01-18T10:00:00Z
      CDG,GOT,2026-02-12,X,Economy,5,20000,2026-01-18T10:00:00Z
      CDG,GOT,2026-02-08,Z,Business,2,75000,2026-01-18T10:00:00Z
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
      departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      GOT,CDG,2026-02-01,X,unknown,5,20000,2026-01-18T10:00:00Z
      GOT,CDG,2026-02-01,I,unknown,2,75000,2026-01-18T10:00:00Z
      CDG,GOT,2026-02-08,X,unknown,5,20000,2026-01-18T10:00:00Z
      CDG,GOT,2026-02-08,I,unknown,2,75000,2026-01-18T10:00:00Z
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
      departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      GOT,CDG,2026-01-15,X,Economy,5,20000,2026-01-18T10:00:00Z
      GOT,CDG,2026-02-01,X,Economy,5,20000,2026-01-18T10:00:00Z
      GOT,CDG,2026-03-15,X,Economy,5,20000,2026-01-18T10:00:00Z
      CDG,GOT,2026-01-22,X,Economy,5,20000,2026-01-18T10:00:00Z
      CDG,GOT,2026-02-08,X,Economy,5,20000,2026-01-18T10:00:00Z
      CDG,GOT,2026-03-22,X,Economy,5,20000,2026-01-18T10:00:00Z
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
      departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      GOT,CDG,2026-02-01,X,Economy,5,20000,2026-01-18T10:00:00Z
      ARN,LHR,2026-02-01,X,Economy,5,22000,2026-01-18T10:00:00Z
      CDG,GOT,2026-02-08,X,Economy,5,20000,2026-01-18T10:00:00Z
      LHR,ARN,2026-02-08,X,Economy,5,22000,2026-01-18T10:00:00Z
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

      # Should find GOT->CDG with CDG->GOT and GOT->CDG with LHR->ARN
      # and ARN->LHR with CDG->GOT and ARN->LHR with LHR->ARN
      assert length(trips) == 4
    end
  end
end
