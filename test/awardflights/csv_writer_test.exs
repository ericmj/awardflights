defmodule Awardflights.CsvWriterTest do
  use ExUnit.Case, async: false

  alias Awardflights.CsvWriter

  defp results_file, do: Application.get_env(:awardflights, :results_file, "results.csv")
  defp failed_file, do: Application.get_env(:awardflights, :failed_file, "failed_requests.csv")

  setup do
    # Clean up files and clear writer state
    CsvWriter.clear_files()

    on_exit(fn ->
      File.rm(results_file())
      File.rm(failed_file())
    end)

    :ok
  end

  describe "write_result/1" do
    test "creates CSV file with header on first write" do
      result = %{
        departure: "GOT",
        arrival: "CDG",
        date: "2026-01-23",
        booking_class: "X",
        cabin: "Economy",
        available_tickets: 9,
        points: 24000
      }

      CsvWriter.write_result(result)

      # Give the async cast time to complete
      :timer.sleep(50)

      assert File.exists?(results_file())

      content = File.read!(results_file())
      lines = String.split(content, "\n", trim: true)

      assert length(lines) == 2

      assert hd(lines) ==
               "source,departure,arrival,date,booking_class,cabin,available_tickets,points,carriers,timestamp"

      [_header, data_line] = lines
      parts = String.split(data_line, ",")

      # Source defaults to :award when not specified
      assert Enum.at(parts, 0) == "award"
      assert Enum.at(parts, 1) == "GOT"
      assert Enum.at(parts, 2) == "CDG"
      assert Enum.at(parts, 3) == "2026-01-23"
      assert Enum.at(parts, 4) == "X"
      assert Enum.at(parts, 5) == "Economy"
      assert Enum.at(parts, 6) == "9"
      assert Enum.at(parts, 7) == "24000"
    end

    test "writes result with offers source" do
      result = %{
        source: :offers,
        departure: "GOT",
        arrival: "CDG",
        date: "2026-01-23",
        booking_class: "X",
        cabin: "Economy",
        available_tickets: 9,
        points: 24000
      }

      CsvWriter.write_result(result)
      :timer.sleep(50)

      content = File.read!(results_file())
      lines = String.split(content, "\n", trim: true)
      [_header, data_line] = lines
      parts = String.split(data_line, ",")

      assert Enum.at(parts, 0) == "offers"
    end

    test "appends multiple results to the same file" do
      result1 = %{
        departure: "GOT",
        arrival: "CDG",
        date: "2026-01-23",
        booking_class: "X",
        cabin: "Economy",
        available_tickets: 9,
        points: 24000
      }

      result2 = %{
        departure: "ARN",
        arrival: "LHR",
        date: "2026-01-24",
        booking_class: "Z",
        cabin: "Business",
        available_tickets: 2,
        points: 75000
      }

      CsvWriter.write_result(result1)
      CsvWriter.write_result(result2)

      :timer.sleep(50)

      content = File.read!(results_file())
      lines = String.split(content, "\n", trim: true)

      assert length(lines) == 3
    end
  end

  describe "write_results/1" do
    test "writes multiple results at once" do
      results = [
        %{
          departure: "GOT",
          arrival: "CDG",
          date: "2026-01-23",
          booking_class: "X",
          cabin: "Economy",
          available_tickets: 9,
          points: 24000
        },
        %{
          departure: "ARN",
          arrival: "LHR",
          date: "2026-01-24",
          booking_class: "Z",
          cabin: "Business",
          available_tickets: 2,
          points: 75000
        }
      ]

      CsvWriter.write_results(results)

      :timer.sleep(50)

      content = File.read!(results_file())
      lines = String.split(content, "\n", trim: true)

      assert length(lines) == 3
    end
  end

  describe "write_failed/5" do
    test "creates failed requests CSV with header" do
      CsvWriter.write_failed("GOT", "NYC", "2026-02-15", :auth_expired)

      :timer.sleep(50)

      assert File.exists?(failed_file())

      content = File.read!(failed_file())
      lines = String.split(content, "\n", trim: true)

      assert length(lines) == 2
      assert hd(lines) == "source,origin,destination,date,error,timestamp"

      [_header, data_line] = lines
      parts = String.split(data_line, ",")

      # Source defaults to :award
      assert Enum.at(parts, 0) == "award"
      assert Enum.at(parts, 1) == "GOT"
      assert Enum.at(parts, 2) == "NYC"
      assert Enum.at(parts, 3) == "2026-02-15"
      assert Enum.at(parts, 4) == "auth_expired"
    end

    test "writes failed request with explicit source" do
      CsvWriter.write_failed(:offers, "GOT", "NYC", "2026-02-15", :cloudflare_blocked)

      :timer.sleep(50)

      content = File.read!(failed_file())
      lines = String.split(content, "\n", trim: true)
      [_header, data_line] = lines
      parts = String.split(data_line, ",")

      assert Enum.at(parts, 0) == "offers"
      assert Enum.at(parts, 4) == "cloudflare_blocked"
    end

    test "handles http_error tuples" do
      CsvWriter.write_failed("GOT", "NYC", "2026-02-15", {:http_error, 500, %{}})

      :timer.sleep(50)

      content = File.read!(failed_file())
      lines = String.split(content, "\n", trim: true)
      [_header, data_line] = lines

      assert String.contains?(data_line, "http_500")
    end

    test "handles request_failed errors" do
      CsvWriter.write_failed("GOT", "NYC", "2026-02-15", {:request_failed, %{}})

      :timer.sleep(50)

      content = File.read!(failed_file())
      lines = String.split(content, "\n", trim: true)
      [_header, data_line] = lines

      assert String.contains?(data_line, "request_failed")
    end
  end

  describe "clear_files/0" do
    test "removes both CSV files" do
      CsvWriter.write_result(%{
        departure: "GOT",
        arrival: "CDG",
        date: "2026-01-23",
        booking_class: "X",
        cabin: "Economy",
        available_tickets: 9,
        points: 24000
      })

      CsvWriter.write_failed("GOT", "NYC", "2026-02-15", :auth_expired)

      :timer.sleep(50)

      assert File.exists?(results_file())
      assert File.exists?(failed_file())

      CsvWriter.clear_files()

      refute File.exists?(results_file())
      refute File.exists?(failed_file())
    end
  end

  describe "deduplication" do
    test "replaces existing result with same key" do
      # Write initial result
      result1 = %{
        source: :award,
        departure: "GOT",
        arrival: "CDG",
        date: "2026-01-23",
        booking_class: "X",
        cabin: "Economy",
        available_tickets: 5,
        points: 24000
      }

      CsvWriter.write_result(result1)
      :timer.sleep(50)

      # Write updated result with same key but different availability
      result2 = %{
        source: :award,
        departure: "GOT",
        arrival: "CDG",
        date: "2026-01-23",
        booking_class: "X",
        cabin: "Economy",
        available_tickets: 3,
        points: 20000
      }

      CsvWriter.write_result(result2)
      :timer.sleep(50)

      content = File.read!(results_file())
      lines = String.split(content, "\n", trim: true)

      # Should have header + 1 data row (not 2)
      assert length(lines) == 2

      [_header, data_line] = lines
      parts = String.split(data_line, ",")

      # Should have the updated values
      assert Enum.at(parts, 6) == "3"
      assert Enum.at(parts, 7) == "20000"
    end

    test "keeps results with different keys" do
      result1 = %{
        source: :award,
        departure: "GOT",
        arrival: "CDG",
        date: "2026-01-23",
        booking_class: "X",
        cabin: "Economy",
        available_tickets: 5,
        points: 24000
      }

      result2 = %{
        source: :award,
        departure: "GOT",
        arrival: "CDG",
        date: "2026-01-23",
        booking_class: "Z",
        cabin: "Business",
        available_tickets: 2,
        points: 75000
      }

      CsvWriter.write_result(result1)
      CsvWriter.write_result(result2)
      :timer.sleep(50)

      content = File.read!(results_file())
      lines = String.split(content, "\n", trim: true)

      # Should have header + 2 data rows (different booking class/cabin)
      assert length(lines) == 3
    end

    test "different sources are treated as different keys" do
      result1 = %{
        source: :award,
        departure: "GOT",
        arrival: "CDG",
        date: "2026-01-23",
        booking_class: "X",
        cabin: "Economy",
        available_tickets: 5,
        points: 24000
      }

      result2 = %{
        source: :offers,
        departure: "GOT",
        arrival: "CDG",
        date: "2026-01-23",
        booking_class: "X",
        cabin: "Economy",
        available_tickets: 3,
        points: 20000
      }

      CsvWriter.write_result(result1)
      CsvWriter.write_result(result2)
      :timer.sleep(50)

      content = File.read!(results_file())
      lines = String.split(content, "\n", trim: true)

      # Should have header + 2 data rows (different source)
      assert length(lines) == 3
    end
  end

  describe "CSV escaping" do
    test "escapes fields containing commas" do
      result = %{
        departure: "GOT",
        arrival: "CDG",
        date: "2026-01-23",
        booking_class: "X",
        cabin: "Economy, Plus",
        available_tickets: 9,
        points: 24000
      }

      CsvWriter.write_result(result)

      :timer.sleep(50)

      content = File.read!(results_file())

      assert String.contains?(content, "\"Economy, Plus\"")
    end

    test "escapes fields containing quotes" do
      result = %{
        departure: "GOT",
        arrival: "CDG",
        date: "2026-01-23",
        booking_class: "X",
        cabin: "Economy \"Basic\"",
        available_tickets: 9,
        points: 24000
      }

      CsvWriter.write_result(result)

      :timer.sleep(50)

      content = File.read!(results_file())

      assert String.contains?(content, "\"Economy \"\"Basic\"\"\"")
    end
  end
end
