defmodule Awardflights.RequestTrackerTest do
  use ExUnit.Case, async: false

  alias Awardflights.RequestTracker

  defp history_file, do: Application.get_env(:awardflights, :history_file, "request_history.csv")

  setup do
    # Clean up and restart the tracker for each test
    File.rm(history_file())
    Supervisor.terminate_child(Awardflights.Supervisor, RequestTracker)
    {:ok, _} = Supervisor.restart_child(Awardflights.Supervisor, RequestTracker)

    on_exit(fn ->
      File.rm(history_file())
    end)

    :ok
  end

  describe "record_success/4" do
    test "records a successful request with default source" do
      RequestTracker.record_success("GOT", "CDG", "2026-01-23")

      # Give the cast time to process
      Process.sleep(10)

      history = RequestTracker.get_history()
      assert Map.has_key?(history, {:award, "GOT", "CDG", "2026-01-23"})
    end

    test "records a successful request with explicit source" do
      RequestTracker.record_success(:offers, "GOT", "CDG", "2026-01-23")

      Process.sleep(10)

      history = RequestTracker.get_history()
      assert Map.has_key?(history, {:offers, "GOT", "CDG", "2026-01-23"})
    end

    test "persists to CSV file" do
      RequestTracker.record_success("ARN", "LHR", "2026-02-01")

      # Give the cast time to process
      Process.sleep(10)

      assert File.exists?(history_file())
      content = File.read!(history_file())
      assert content =~ "source,origin,destination,date,scanned_at"
      assert content =~ "award,ARN,LHR,2026-02-01"
    end

    test "updates timestamp for same route/date" do
      RequestTracker.record_success("GOT", "CDG", "2026-01-23")
      Process.sleep(10)

      first_history = RequestTracker.get_history()
      first_timestamp = first_history[{:award, "GOT", "CDG", "2026-01-23"}]

      Process.sleep(100)

      RequestTracker.record_success("GOT", "CDG", "2026-01-23")
      Process.sleep(10)

      second_history = RequestTracker.get_history()
      second_timestamp = second_history[{:award, "GOT", "CDG", "2026-01-23"}]

      assert second_timestamp > first_timestamp
    end

    test "tracks history separately per source" do
      RequestTracker.record_success(:award, "GOT", "CDG", "2026-01-23")
      RequestTracker.record_success(:offers, "GOT", "CDG", "2026-01-23")
      Process.sleep(10)

      history = RequestTracker.get_history()
      assert Map.has_key?(history, {:award, "GOT", "CDG", "2026-01-23"})
      assert Map.has_key?(history, {:offers, "GOT", "CDG", "2026-01-23"})
    end
  end

  describe "should_skip?/5" do
    test "returns false when skip_days is 0" do
      RequestTracker.record_success("GOT", "CDG", "2026-01-23")
      Process.sleep(10)

      refute RequestTracker.should_skip?("GOT", "CDG", "2026-01-23", 0)
    end

    test "returns false when request not in history" do
      refute RequestTracker.should_skip?("GOT", "CDG", "2026-01-23", 7)
    end

    test "returns true when request was done within skip_days" do
      RequestTracker.record_success("GOT", "CDG", "2026-01-23")
      Process.sleep(10)

      assert RequestTracker.should_skip?("GOT", "CDG", "2026-01-23", 7)
    end

    test "returns false when request was done outside skip_days" do
      # Manually add an old entry to history (new format with source)
      old_time = DateTime.utc_now() |> DateTime.add(-10, :day) |> DateTime.to_iso8601()

      File.write!(
        history_file(),
        "source,origin,destination,date,scanned_at\naward,GOT,CDG,2026-01-23,#{old_time}\n"
      )

      # Restart tracker to load the history
      Supervisor.terminate_child(Awardflights.Supervisor, RequestTracker)
      {:ok, _} = Supervisor.restart_child(Awardflights.Supervisor, RequestTracker)

      refute RequestTracker.should_skip?("GOT", "CDG", "2026-01-23", 7)
    end

    test "respects source when checking skip" do
      RequestTracker.record_success(:award, "GOT", "CDG", "2026-01-23")
      Process.sleep(10)

      # Award should skip
      assert RequestTracker.should_skip?(:award, "GOT", "CDG", "2026-01-23", 7)
      # Offers should NOT skip (different source)
      refute RequestTracker.should_skip?(:offers, "GOT", "CDG", "2026-01-23", 7)
    end
  end

  describe "count_skippable/4" do
    test "returns count of skippable requests" do
      RequestTracker.record_success("GOT", "CDG", "2026-01-23")
      RequestTracker.record_success("GOT", "LHR", "2026-01-23")
      Process.sleep(10)

      count =
        RequestTracker.count_skippable(
          ["GOT"],
          ["CDG", "LHR", "NYC"],
          ["2026-01-23"],
          7
        )

      assert count == 2
    end

    test "returns 0 when skip_days is 0" do
      RequestTracker.record_success("GOT", "CDG", "2026-01-23")
      Process.sleep(10)

      count = RequestTracker.count_skippable(["GOT"], ["CDG"], ["2026-01-23"], 0)
      assert count == 0
    end

    test "excludes same origin/destination pairs" do
      RequestTracker.record_success("GOT", "GOT", "2026-01-23")
      Process.sleep(10)

      count = RequestTracker.count_skippable(["GOT"], ["GOT"], ["2026-01-23"], 7)
      assert count == 0
    end
  end

  describe "clear_history/0" do
    test "clears all history" do
      RequestTracker.record_success("GOT", "CDG", "2026-01-23")
      Process.sleep(10)

      assert RequestTracker.get_history() != %{}

      RequestTracker.clear_history()

      assert RequestTracker.get_history() == %{}
      refute File.exists?(history_file())
    end
  end

  describe "persistence" do
    test "loads history from new format file on startup" do
      # Create a history file with new format (source column)
      File.write!(
        history_file(),
        "source,origin,destination,date,scanned_at\naward,GOT,CDG,2026-01-23,2026-01-18T12:00:00Z\n"
      )

      # Restart tracker to load the history
      Supervisor.terminate_child(Awardflights.Supervisor, RequestTracker)
      {:ok, _} = Supervisor.restart_child(Awardflights.Supervisor, RequestTracker)

      history = RequestTracker.get_history()
      assert Map.has_key?(history, {:award, "GOT", "CDG", "2026-01-23"})
      assert history[{:award, "GOT", "CDG", "2026-01-23"}] == "2026-01-18T12:00:00Z"
    end

    test "loads history from old format file on startup (backward compatibility)" do
      # Create a history file with old format (no source column)
      File.write!(
        history_file(),
        "origin,destination,date,scanned_at\nGOT,CDG,2026-01-23,2026-01-18T12:00:00Z\n"
      )

      # Restart tracker to load the history
      Supervisor.terminate_child(Awardflights.Supervisor, RequestTracker)
      {:ok, _} = Supervisor.restart_child(Awardflights.Supervisor, RequestTracker)

      history = RequestTracker.get_history()
      # Old format should default to :award source
      assert Map.has_key?(history, {:award, "GOT", "CDG", "2026-01-23"})
      assert history[{:award, "GOT", "CDG", "2026-01-23"}] == "2026-01-18T12:00:00Z"
    end

    test "keeps most recent timestamp for duplicate entries" do
      # Create a history file with duplicates (new format)
      content = """
      source,origin,destination,date,scanned_at
      award,GOT,CDG,2026-01-23,2026-01-15T12:00:00Z
      award,GOT,CDG,2026-01-23,2026-01-18T12:00:00Z
      award,GOT,CDG,2026-01-23,2026-01-16T12:00:00Z
      """

      File.write!(history_file(), content)

      # Restart tracker to load the history
      Supervisor.terminate_child(Awardflights.Supervisor, RequestTracker)
      {:ok, _} = Supervisor.restart_child(Awardflights.Supervisor, RequestTracker)

      history = RequestTracker.get_history()
      # Should keep the most recent (2026-01-18)
      assert history[{:award, "GOT", "CDG", "2026-01-23"}] == "2026-01-18T12:00:00Z"
    end
  end
end
