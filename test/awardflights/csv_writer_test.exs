defmodule Awardflights.CsvWriterTest do
  use ExUnit.Case, async: false

  alias Awardflights.{Csv, CsvWriter}
  alias Awardflights.Itinerary.{Segment, Stop}

  @headers ~w(source departure arrival date booking_class cabin available_tickets points carriers operating_carriers departure_time arrival_time duration segments stops timestamp)

  defp results_file, do: Application.get_env(:awardflights, :results_file, "results.csv")
  defp failed_file, do: Application.get_env(:awardflights, :failed_file, "failed_requests.csv")

  setup do
    CsvWriter.clear_files()

    on_exit(fn ->
      File.rm(results_file())
      File.rm(failed_file())
    end)

    :ok
  end

  # Casts to the writer, then waits until it has processed the message.
  defp write_results(source, origin, destination, date, results) do
    CsvWriter.write_results(source, origin, destination, date, results)
    _ = :sys.get_state(CsvWriter)
  end

  defp write_failed(args) do
    apply(CsvWriter, :write_failed, args)
    _ = :sys.get_state(CsvWriter)
  end

  defp read_results do
    [headers | rows] = results_file() |> File.read!() |> Csv.parse_string(skip_headers: false)
    {headers, Enum.map(rows, &Map.new(Enum.zip(headers, &1)))}
  end

  defp read_failed do
    [headers | rows] = failed_file() |> File.read!() |> Csv.parse_string(skip_headers: false)
    {headers, Enum.map(rows, &Map.new(Enum.zip(headers, &1)))}
  end

  @segment %Segment{
    flight_number: "SK1",
    departure: "GOT",
    arrival: "CDG",
    departure_time: "2026-01-23T10:05:00+01:00",
    arrival_time: "2026-01-23T12:30:00+01:00",
    duration: 145,
    marketing_carrier: "SAS",
    operating_carrier: "SAS Connect"
  }

  defp flight(overrides \\ %{}) do
    Map.merge(
      %{
        departure: "GOT",
        arrival: "CDG",
        date: "2026-01-23",
        booking_class: "X",
        cabin: "Economy",
        available_tickets: 9,
        points: 24000,
        carriers: "SAS",
        operating_carriers: "SAS Connect",
        departure_time: "2026-01-23T10:05:00+01:00",
        arrival_time: "2026-01-23T12:30:00+01:00",
        duration: 145,
        segments: [@segment],
        stops: []
      },
      overrides
    )
  end

  defp via_cph(overrides \\ %{}) do
    flight(
      Map.merge(
        %{
          operating_carriers: "SAS",
          departure_time: "2026-01-23T07:00:00+01:00",
          arrival_time: "2026-01-23T12:30:00+01:00",
          duration: 330,
          segments: [
            %Segment{
              @segment
              | flight_number: "SK400",
                arrival: "CPH",
                departure_time: "2026-01-23T07:00:00+01:00",
                arrival_time: "2026-01-23T07:45:00+01:00",
                duration: 45,
                operating_carrier: "SAS"
            },
            %Segment{
              @segment
              | flight_number: "SK560",
                departure: "CPH",
                departure_time: "2026-01-23T10:30:00+01:00",
                duration: 120,
                operating_carrier: "SAS"
            }
          ],
          stops: [%Stop{airport: "CPH", duration: 165}]
        },
        overrides
      )
    )
  end

  describe "write_results/5" do
    test "writes the header and every column of a result" do
      write_results(:award, "GOT", "CDG", "2026-01-23", [flight()])

      {headers, [row]} = read_results()

      assert headers == @headers
      assert row["source"] == "award"
      assert row["departure"] == "GOT"
      assert row["arrival"] == "CDG"
      assert row["date"] == "2026-01-23"
      assert row["booking_class"] == "X"
      assert row["cabin"] == "Economy"
      assert row["available_tickets"] == "9"
      assert row["points"] == "24000"
      assert row["carriers"] == "SAS"
      assert row["operating_carriers"] == "SAS Connect"
      assert row["departure_time"] == "2026-01-23T10:05:00+01:00"
      assert row["arrival_time"] == "2026-01-23T12:30:00+01:00"
      assert row["duration"] == "145"

      assert row["segments"] ==
               "SK1|GOT|CDG|2026-01-23T10:05:00+01:00|2026-01-23T12:30:00+01:00|145|SAS|SAS Connect"

      assert row["stops"] == ""
      assert {:ok, _, _} = DateTime.from_iso8601(row["timestamp"])
    end

    test "writes the source of the query" do
      write_results(:offers, "GOT", "CDG", "2026-01-23", [flight()])

      {_headers, [row]} = read_results()
      assert row["source"] == "offers"
    end

    test "stores each itinerary on its own row" do
      write_results(:award, "GOT", "CDG", "2026-01-23", [flight(), via_cph()])

      {_headers, rows} = read_results()

      assert Enum.map(rows, & &1["stops"]) == ["", "CPH|165"]
      assert Enum.map(rows, & &1["duration"]) == ["145", "330"]
      assert Enum.map(rows, & &1["available_tickets"]) == ["9", "9"]
    end

    test "sums seats of results with the same itinerary, cabin, class and points" do
      write_results(:award, "GOT", "CDG", "2026-01-23", [
        flight(%{available_tickets: 5}),
        flight(%{available_tickets: 3}),
        flight(%{available_tickets: 2, booking_class: "Z", cabin: "Business", points: 75000})
      ])

      {_headers, rows} = read_results()

      assert Enum.map(rows, &{&1["booking_class"], &1["available_tickets"]}) == [
               {"X", "8"},
               {"Z", "2"}
             ]
    end

    test "replaces the rows of the same query and keeps other queries" do
      write_results(:award, "GOT", "CDG", "2026-01-23", [
        flight(),
        flight(%{booking_class: "Z", cabin: "Business", points: 75000})
      ])

      write_results(:award, "ARN", "LHR", "2026-01-24", [
        flight(%{departure: "ARN", arrival: "LHR", date: "2026-01-24"})
      ])

      write_results(:offers, "GOT", "CDG", "2026-01-23", [flight(%{available_tickets: 4})])

      write_results(:award, "GOT", "CDG", "2026-01-23", [flight(%{available_tickets: 1})])

      {_headers, rows} = read_results()

      assert Enum.map(
               rows,
               &{&1["source"], &1["departure"], &1["arrival"], &1["booking_class"],
                &1["available_tickets"]}
             ) == [
               {"award", "ARN", "LHR", "X", "9"},
               {"offers", "GOT", "CDG", "X", "4"},
               {"award", "GOT", "CDG", "X", "1"}
             ]
    end

    test "an empty result removes the rows previously stored for the query" do
      write_results(:award, "GOT", "CDG", "2026-01-23", [flight()])
      write_results(:award, "GOT", "CDG", "2026-01-23", [])

      {headers, rows} = read_results()
      assert headers == @headers
      assert rows == []
    end

    test "leaves itinerary columns empty for results without itinerary data" do
      write_results(:award, "GOT", "CDG", "2026-01-23", [
        %{
          departure: "GOT",
          arrival: "CDG",
          date: "2026-01-23",
          booking_class: "X",
          cabin: "Economy",
          available_tickets: 9,
          points: 24000
        }
      ])

      {_headers, [row]} = read_results()

      assert row["carriers"] == ""
      assert row["operating_carriers"] == ""
      assert row["departure_time"] == ""
      assert row["duration"] == ""
      assert row["segments"] == ""
      assert row["stops"] == ""
    end

    test "escapes fields containing commas and quotes" do
      write_results(:award, "GOT", "CDG", "2026-01-23", [
        flight(%{carriers: "SAS, KLM", cabin: "Economy \"Basic\""})
      ])

      content = File.read!(results_file())
      assert content =~ "\"SAS, KLM\""
      assert content =~ "\"Economy \"\"Basic\"\"\""

      {_headers, [row]} = read_results()
      assert row["carriers"] == "SAS, KLM"
      assert row["cabin"] == "Economy \"Basic\""
    end
  end

  describe "write_failed/5" do
    test "creates failed requests CSV with header" do
      write_failed(["GOT", "NYC", "2026-02-15", :auth_expired])

      {headers, [row]} = read_failed()

      assert headers == ~w(source origin destination date error timestamp)
      assert row["source"] == "award"
      assert row["origin"] == "GOT"
      assert row["destination"] == "NYC"
      assert row["date"] == "2026-02-15"
      assert row["error"] == "auth_expired"
    end

    test "writes failed request with explicit source" do
      write_failed([:offers, "GOT", "NYC", "2026-02-15", :cloudflare_blocked])

      {_headers, [row]} = read_failed()
      assert row["source"] == "offers"
      assert row["error"] == "cloudflare_blocked"
    end

    test "appends rows" do
      write_failed(["GOT", "NYC", "2026-02-15", :auth_expired])
      write_failed(["GOT", "NYC", "2026-02-16", {:http_error, 500, %{}}])
      write_failed(["GOT", "NYC", "2026-02-17", {:request_failed, %{}}])

      {_headers, rows} = read_failed()
      assert Enum.map(rows, & &1["error"]) == ["auth_expired", "http_500", "request_failed"]
    end
  end

  describe "clear_files/0" do
    test "removes both CSV files" do
      write_results(:award, "GOT", "CDG", "2026-01-23", [flight()])
      write_failed(["GOT", "NYC", "2026-02-15", :auth_expired])

      assert File.exists?(results_file())
      assert File.exists?(failed_file())

      CsvWriter.clear_files()

      refute File.exists?(results_file())
      refute File.exists?(failed_file())
    end
  end
end
