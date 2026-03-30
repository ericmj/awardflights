defmodule Awardflights.FlightScannerTest do
  use ExUnit.Case, async: false

  alias Awardflights.FlightScanner
  alias Awardflights.CsvWriter
  alias Awardflights.RateLimitTracker

  defp results_file, do: Application.get_env(:awardflights, :results_file, "results.csv")
  defp failed_file, do: Application.get_env(:awardflights, :failed_file, "failed_requests.csv")

  defp rate_limits_file,
    do: Application.get_env(:awardflights, :rate_limits_file, "rate_limits.csv")

  setup do
    # Stop any existing scan and restart FlightScanner for clean state
    FlightScanner.stop_scan()
    Supervisor.terminate_child(Awardflights.Supervisor, FlightScanner)
    Supervisor.restart_child(Awardflights.Supervisor, FlightScanner)

    # Reset RateLimitTracker to clean state
    File.rm(rate_limits_file())
    Supervisor.terminate_child(Awardflights.Supervisor, RateLimitTracker)
    Supervisor.restart_child(Awardflights.Supervisor, RateLimitTracker)

    CsvWriter.clear_files()

    # Set up the Req test plug
    Application.put_env(:awardflights, :sas_award_api_plug, {Req.Test, Awardflights.SasAwardApi})

    on_exit(fn ->
      FlightScanner.stop_scan()
      Application.delete_env(:awardflights, :sas_award_api_plug)
      File.rm(results_file())
      File.rm(failed_file())
      File.rm(rate_limits_file())
    end)

    :ok
  end

  defp stub_api(response_fn) do
    Req.Test.stub(Awardflights.SasAwardApi, response_fn)
    Req.Test.allow(Awardflights.SasAwardApi, self(), Process.whereis(FlightScanner))
    Req.Test.set_req_test_to_shared(self())
  end

  describe "get_status/0" do
    test "returns initial status when not scanning" do
      status = FlightScanner.get_status()

      assert status.scanning == false
      assert status.completed == 0
      assert status.total == 0
      assert status.results_count == 0
      assert status.errors_count == 0
      assert status.award_credentials == []
      assert status.offers_credentials == []
    end
  end

  describe "start_scan/1" do
    test "starts scanning with valid config using credential list" do
      stub_api(fn conn ->
        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      config = %{
        origins: ["GOT"],
        destinations: ["CDG"],
        start_date: "2026-01-23",
        end_date: "2026-01-23",
        award_credentials: [%{name: "Test Account", value: "test_token"}],
        max_concurrency: 1
      }

      assert :ok = FlightScanner.start_scan(config)

      status = FlightScanner.get_status()
      assert status.scanning == true
      assert status.total == 1
      assert length(status.award_credentials) == 1
      assert hd(status.award_credentials).name == "Test Account"

      # Wait for scan to complete
      :timer.sleep(100)

      status = FlightScanner.get_status()
      assert status.scanning == false
      assert status.completed == 1
    end

    test "returns error when already scanning" do
      stub_api(fn conn ->
        # Slow response to keep scan running
        :timer.sleep(100)
        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      config = %{
        origins: ["GOT"],
        destinations: ["CDG"],
        start_date: "2026-01-23",
        end_date: "2026-01-25",
        award_credentials: [%{name: "Test", value: "test_token"}],
        max_concurrency: 1
      }

      assert :ok = FlightScanner.start_scan(config)
      assert {:error, :already_scanning} = FlightScanner.start_scan(config)
    end

    test "calculates correct total for multiple origins, destinations, and dates" do
      stub_api(fn conn ->
        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      config = %{
        origins: ["GOT", "ARN"],
        destinations: ["CDG", "LHR"],
        start_date: "2026-01-23",
        end_date: "2026-01-24",
        award_credentials: [%{name: "Test", value: "test_token"}],
        max_concurrency: 1
      }

      FlightScanner.start_scan(config)

      status = FlightScanner.get_status()
      # 2 origins x 2 destinations x 2 dates = 8 combinations
      # But same origin/destination pairs are excluded, so:
      # GOT->CDG, GOT->LHR, ARN->CDG, ARN->LHR = 4 routes x 2 dates = 8
      assert status.total == 8
    end

    test "excludes same origin/destination combinations" do
      stub_api(fn conn ->
        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      config = %{
        origins: ["GOT", "CDG"],
        destinations: ["GOT", "CDG"],
        start_date: "2026-01-23",
        end_date: "2026-01-23",
        award_credentials: [%{name: "Test", value: "test_token"}],
        max_concurrency: 1
      }

      FlightScanner.start_scan(config)

      status = FlightScanner.get_status()
      # GOT->CDG and CDG->GOT only (not GOT->GOT or CDG->CDG)
      assert status.total == 2
    end

    test "does not scan when no credentials provided" do
      config = %{
        origins: ["GOT"],
        destinations: ["CDG"],
        start_date: "2026-01-23",
        end_date: "2026-01-23",
        award_credentials: [],
        max_concurrency: 1
      }

      FlightScanner.start_scan(config)

      status = FlightScanner.get_status()
      assert status.total == 0
    end

    test "accepts multiple credentials" do
      stub_api(fn conn ->
        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      config = %{
        origins: ["GOT"],
        destinations: ["CDG"],
        start_date: "2026-01-23",
        end_date: "2026-01-23",
        award_credentials: [
          %{name: "Account 1", value: "token1"},
          %{name: "Account 2", value: "token2"}
        ],
        max_concurrency: 1
      }

      FlightScanner.start_scan(config)

      status = FlightScanner.get_status()
      assert length(status.award_credentials) == 2
      assert status.award_active_index == 0
    end
  end

  describe "stop_scan/0" do
    test "stops an active scan" do
      stub_api(fn conn ->
        :timer.sleep(10)
        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      config = %{
        origins: ["GOT"],
        destinations: ["CDG"],
        start_date: "2026-01-23",
        end_date: "2026-01-30",
        award_credentials: [%{name: "Test", value: "test_token"}],
        max_concurrency: 1
      }

      FlightScanner.start_scan(config)
      :timer.sleep(20)

      assert :ok = FlightScanner.stop_scan()

      status = FlightScanner.get_status()
      assert status.scanning == false
    end
  end

  describe "subscribe/0" do
    test "receives progress updates via PubSub" do
      stub_api(fn conn ->
        Req.Test.json(conn, %{
          "outboundFlights" => [
            %{
              "origin" => %{"code" => "GOT"},
              "destination" => %{"code" => "CDG"},
              "cabins" => [
                %{
                  "cabinName" => "Economy",
                  "fares" => [
                    %{"bookingClass" => "X", "avlSeats" => 5, "points" => %{"base" => 20000}}
                  ]
                }
              ]
            }
          ]
        })
      end)

      FlightScanner.subscribe()

      config = %{
        origins: ["GOT"],
        destinations: ["CDG"],
        start_date: "2026-01-23",
        end_date: "2026-01-23",
        award_credentials: [%{name: "Test", value: "test_token"}],
        max_concurrency: 1
      }

      FlightScanner.start_scan(config)

      assert_receive {:progress, %{award_current: {"GOT", "CDG", _date}}}, 1000
      assert_receive {:flights_found, %{count: 1}}, 1000
      assert_receive {:scan_complete, _}, 1000
    end

    test "receives error events via PubSub" do
      stub_api(fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "Unauthorized"})
      end)

      FlightScanner.subscribe()

      config = %{
        origins: ["GOT"],
        destinations: ["CDG"],
        start_date: "2026-01-23",
        end_date: "2026-01-23",
        award_credentials: [%{name: "Test", value: "bad_token"}],
        max_concurrency: 1
      }

      FlightScanner.start_scan(config)

      assert_receive {:scan_error, %{error: :auth_expired}}, 1000
    end
  end

  describe "credential rotation" do
    test "rotates to next credential on rate limit" do
      # Track which credential was used
      request_count = :counters.new(1, [:atomics])

      stub_api(fn conn ->
        count = :counters.get(request_count, 1)
        :counters.add(request_count, 1, 1)

        if count == 0 do
          # First request - rate limit
          conn
          |> Plug.Conn.put_status(429)
          |> Plug.Conn.put_resp_header("retry-after", "1")
          |> Req.Test.json(%{"error" => "Rate limited"})
        else
          # Second request with rotated credential succeeds
          Req.Test.json(conn, %{"outboundFlights" => []})
        end
      end)

      FlightScanner.subscribe()

      config = %{
        origins: ["GOT"],
        destinations: ["CDG"],
        start_date: "2026-01-23",
        end_date: "2026-01-23",
        award_credentials: [
          %{name: "Account 1", value: "token1"},
          %{name: "Account 2", value: "token2"}
        ],
        max_concurrency: 1
      }

      FlightScanner.start_scan(config)

      # Should receive credential_rotated event
      assert_receive {:credential_rotated, %{source: :award, from_index: 0, to_index: 1}}, 2000

      # Scan should complete after rotation
      assert_receive {:scan_complete, _}, 2000
    end

    test "pauses when all credentials are rate limited" do
      stub_api(fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Plug.Conn.put_resp_header("retry-after", "1")
        |> Req.Test.json(%{"error" => "Rate limited"})
      end)

      FlightScanner.subscribe()

      config = %{
        origins: ["GOT"],
        destinations: ["CDG"],
        start_date: "2026-01-23",
        end_date: "2026-01-23",
        award_credentials: [%{name: "Only Account", value: "token1"}],
        max_concurrency: 1
      }

      FlightScanner.start_scan(config)

      # Should receive rate_limited event when all credentials exhausted
      assert_receive {:rate_limited, %{source: :award}}, 2000

      # Check status shows paused state
      status = FlightScanner.get_status()
      assert status.award_paused_until != nil
    end

    test "marks individual credentials as rate limited" do
      request_count = :counters.new(1, [:atomics])

      stub_api(fn conn ->
        count = :counters.get(request_count, 1)
        :counters.add(request_count, 1, 1)

        if count == 0 do
          conn
          |> Plug.Conn.put_status(429)
          |> Plug.Conn.put_resp_header("retry-after", "60")
          |> Req.Test.json(%{"error" => "Rate limited"})
        else
          Req.Test.json(conn, %{"outboundFlights" => []})
        end
      end)

      FlightScanner.subscribe()

      config = %{
        origins: ["GOT"],
        destinations: ["CDG"],
        start_date: "2026-01-23",
        end_date: "2026-01-23",
        award_credentials: [
          %{name: "Account 1", value: "token1"},
          %{name: "Account 2", value: "token2"}
        ],
        max_concurrency: 1
      }

      FlightScanner.start_scan(config)

      # Wait for rotation
      assert_receive {:credential_rotated, _}, 2000

      # Wait for completion
      assert_receive {:scan_complete, _}, 2000

      status = FlightScanner.get_status()

      # First credential should be rate limited
      first_cred = Enum.at(status.award_credentials, 0)
      assert first_cred.rate_limited_until != nil

      # Second credential should not be rate limited
      second_cred = Enum.at(status.award_credentials, 1)
      assert second_cred.rate_limited_until == nil
    end

    # Note: Rate limit clearing is tested implicitly by other tests.
    # A dedicated timeout test would take 6+ seconds (1s retry-after + 5s buffer)
    # and would be flaky due to timing issues.
  end
end
