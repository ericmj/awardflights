defmodule Awardflights.RateLimitTrackerTest do
  use ExUnit.Case, async: false

  alias Awardflights.RateLimitTracker

  defp rate_limits_file,
    do: Application.get_env(:awardflights, :rate_limits_file, "rate_limits.csv")

  setup do
    # Clean up and restart the tracker for each test
    File.rm(rate_limits_file())
    Supervisor.terminate_child(Awardflights.Supervisor, RateLimitTracker)
    {:ok, _} = Supervisor.restart_child(Awardflights.Supervisor, RateLimitTracker)

    on_exit(fn ->
      File.rm(rate_limits_file())
    end)

    :ok
  end

  describe "set_rate_limit/3" do
    test "persists rate limit to CSV" do
      RateLimitTracker.set_rate_limit(:award, "Account 1", 300)

      assert File.exists?(rate_limits_file())
      content = File.read!(rate_limits_file())
      assert content =~ "source,credential_name,rate_limited_until,expired"
      assert content =~ "award,Account 1,"
      assert content =~ ",false"
    end

    test "stores rate_limited_until timestamp" do
      RateLimitTracker.set_rate_limit(:award, "Account 1", 300)

      statuses = RateLimitTracker.get_all_statuses()
      assert length(statuses.award) == 1
      [status] = statuses.award
      assert status.name == "Account 1"
      assert status.rate_limited_until != nil
      assert status.expired == false
    end

    test "updates existing rate limit" do
      RateLimitTracker.set_rate_limit(:award, "Account 1", 100)
      first_statuses = RateLimitTracker.get_all_statuses()
      first_until = hd(first_statuses.award).rate_limited_until

      Process.sleep(10)

      RateLimitTracker.set_rate_limit(:award, "Account 1", 500)
      second_statuses = RateLimitTracker.get_all_statuses()
      second_until = hd(second_statuses.award).rate_limited_until

      assert DateTime.compare(second_until, first_until) == :gt
    end
  end

  describe "set_expired/3" do
    test "marks credential as expired" do
      RateLimitTracker.set_expired(:award, "Account 1", "my_token_value")

      statuses = RateLimitTracker.get_all_statuses()
      [status] = statuses.award
      assert status.name == "Account 1"
      assert status.expired == true
      assert status.rate_limited_until == nil
    end

    test "persists expiration to CSV with value hash" do
      RateLimitTracker.set_expired(:offers, "Primary", "my_cookie_value")

      content = File.read!(rate_limits_file())
      assert content =~ "offers,Primary,,true,"
      # Should contain a base64-encoded hash (ends with = for padding)
      lines = String.split(content, "\n", trim: true)
      data_line = Enum.at(lines, 1)
      [_source, _name, _until, _expired, hash] = String.split(data_line, ",")
      assert String.ends_with?(hash, "=")
      # SHA256 base64 is always 44 chars
      assert String.length(hash) == 44
    end
  end

  describe "credential_value_changed?/3" do
    test "returns false for unknown credential" do
      assert RateLimitTracker.credential_value_changed?(:award, "Unknown", "any_value") == false
    end

    test "returns false for non-expired credential" do
      RateLimitTracker.set_rate_limit(:award, "Account 1", 300)
      assert RateLimitTracker.credential_value_changed?(:award, "Account 1", "any_value") == false
    end

    test "returns false when value hash matches" do
      RateLimitTracker.set_expired(:award, "Account 1", "original_token")

      assert RateLimitTracker.credential_value_changed?(:award, "Account 1", "original_token") ==
               false
    end

    test "returns true when value hash differs" do
      RateLimitTracker.set_expired(:award, "Account 1", "original_token")
      assert RateLimitTracker.credential_value_changed?(:award, "Account 1", "new_token") == true
    end

    test "returns false for expired credential without hash (legacy data)" do
      # Simulate legacy data without value_hash
      File.write!(
        rate_limits_file(),
        "source,credential_name,rate_limited_until,expired\naward,Account 1,,true\n"
      )

      Supervisor.terminate_child(Awardflights.Supervisor, RateLimitTracker)
      {:ok, _} = Supervisor.restart_child(Awardflights.Supervisor, RateLimitTracker)

      # Should not crash and should return false (can't detect change without hash)
      assert RateLimitTracker.credential_value_changed?(:award, "Account 1", "any_value") == false
    end
  end

  describe "check_credential/2" do
    test "returns :ok for unknown credential" do
      assert RateLimitTracker.check_credential(:award, "Unknown") == :ok
    end

    test "returns :expired for expired credential" do
      RateLimitTracker.set_expired(:award, "Account 1", "token_value")
      assert RateLimitTracker.check_credential(:award, "Account 1") == :expired
    end

    test "returns {:rate_limited, seconds} for rate limited credential" do
      RateLimitTracker.set_rate_limit(:award, "Account 1", 300)

      result = RateLimitTracker.check_credential(:award, "Account 1")
      assert {:rate_limited, seconds} = result
      assert seconds > 290 and seconds <= 300
    end

    test "returns :ok for expired rate limit" do
      # Set a rate limit that's already expired (negative seconds won't work, so we manipulate the file)
      past_time = DateTime.utc_now() |> DateTime.add(-100, :second) |> DateTime.to_iso8601()

      File.write!(
        rate_limits_file(),
        "source,credential_name,rate_limited_until,expired\naward,Account 1,#{past_time},false\n"
      )

      Supervisor.terminate_child(Awardflights.Supervisor, RateLimitTracker)
      {:ok, _} = Supervisor.restart_child(Awardflights.Supervisor, RateLimitTracker)

      # Expired rate limits are cleaned up on startup
      assert RateLimitTracker.check_credential(:award, "Account 1") == :ok
    end
  end

  describe "clear_rate_limit/2" do
    test "removes rate limit entry" do
      RateLimitTracker.set_rate_limit(:award, "Account 1", 300)
      assert RateLimitTracker.check_credential(:award, "Account 1") != :ok

      RateLimitTracker.clear_rate_limit(:award, "Account 1")
      assert RateLimitTracker.check_credential(:award, "Account 1") == :ok
    end

    test "removes entry from CSV" do
      RateLimitTracker.set_rate_limit(:award, "Account 1", 300)
      RateLimitTracker.set_rate_limit(:award, "Account 2", 300)

      RateLimitTracker.clear_rate_limit(:award, "Account 1")

      content = File.read!(rate_limits_file())
      refute content =~ "Account 1"
      assert content =~ "Account 2"
    end
  end

  describe "get_rate_limits/1" do
    test "returns rate limits for specific source" do
      RateLimitTracker.set_rate_limit(:award, "Account 1", 300)
      RateLimitTracker.set_rate_limit(:offers, "Primary", 300)

      award_limits = RateLimitTracker.get_rate_limits(:award)
      assert length(award_limits) == 1
      assert hd(award_limits).name == "Account 1"

      offers_limits = RateLimitTracker.get_rate_limits(:offers)
      assert length(offers_limits) == 1
      assert hd(offers_limits).name == "Primary"
    end
  end

  describe "get_all_statuses/0" do
    test "returns statuses grouped by source" do
      RateLimitTracker.set_rate_limit(:award, "Account 1", 300)
      RateLimitTracker.set_expired(:offers, "Primary", "cookie_value")

      statuses = RateLimitTracker.get_all_statuses()

      assert Map.has_key?(statuses, :award)
      assert Map.has_key?(statuses, :offers)
      assert length(statuses.award) == 1
      assert length(statuses.offers) == 1
    end
  end

  describe "persistence" do
    test "loads rate limits from file on startup" do
      future_time = DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.to_iso8601()

      File.write!(
        rate_limits_file(),
        "source,credential_name,rate_limited_until,expired\naward,Account 1,#{future_time},false\n"
      )

      Supervisor.terminate_child(Awardflights.Supervisor, RateLimitTracker)
      {:ok, _} = Supervisor.restart_child(Awardflights.Supervisor, RateLimitTracker)

      result = RateLimitTracker.check_credential(:award, "Account 1")
      assert {:rate_limited, _seconds} = result
    end

    test "loads expired credentials from file on startup" do
      File.write!(
        rate_limits_file(),
        "source,credential_name,rate_limited_until,expired\naward,Account 1,,true\n"
      )

      Supervisor.terminate_child(Awardflights.Supervisor, RateLimitTracker)
      {:ok, _} = Supervisor.restart_child(Awardflights.Supervisor, RateLimitTracker)

      assert RateLimitTracker.check_credential(:award, "Account 1") == :expired
    end

    test "cleans up expired rate limits on startup" do
      past_time = DateTime.utc_now() |> DateTime.add(-100, :second) |> DateTime.to_iso8601()

      File.write!(
        rate_limits_file(),
        "source,credential_name,rate_limited_until,expired\naward,Account 1,#{past_time},false\n"
      )

      Supervisor.terminate_child(Awardflights.Supervisor, RateLimitTracker)
      {:ok, _} = Supervisor.restart_child(Awardflights.Supervisor, RateLimitTracker)

      # Should be cleaned up
      statuses = RateLimitTracker.get_all_statuses()
      assert statuses.award == []
    end

    test "keeps expired auth credentials on startup" do
      File.write!(
        rate_limits_file(),
        "source,credential_name,rate_limited_until,expired\naward,Account 1,,true\n"
      )

      Supervisor.terminate_child(Awardflights.Supervisor, RateLimitTracker)
      {:ok, _} = Supervisor.restart_child(Awardflights.Supervisor, RateLimitTracker)

      # Should NOT be cleaned up
      statuses = RateLimitTracker.get_all_statuses()
      assert length(statuses.award) == 1
      assert hd(statuses.award).expired == true
    end

    test "handles corrupt CSV gracefully" do
      File.write!(rate_limits_file(), "not,valid,csv\ngarbage data here")

      Supervisor.terminate_child(Awardflights.Supervisor, RateLimitTracker)
      {:ok, _} = Supervisor.restart_child(Awardflights.Supervisor, RateLimitTracker)

      # Should start fresh
      statuses = RateLimitTracker.get_all_statuses()
      assert statuses.award == []
      assert statuses.offers == []
    end

    test "handles missing file gracefully" do
      File.rm(rate_limits_file())

      Supervisor.terminate_child(Awardflights.Supervisor, RateLimitTracker)
      {:ok, _} = Supervisor.restart_child(Awardflights.Supervisor, RateLimitTracker)

      statuses = RateLimitTracker.get_all_statuses()
      assert statuses.award == []
      assert statuses.offers == []
    end
  end
end
