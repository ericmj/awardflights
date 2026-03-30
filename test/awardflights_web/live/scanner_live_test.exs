defmodule AwardflightsWeb.ScannerLiveTest do
  use AwardflightsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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

  describe "mounting" do
    test "renders the scanner form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "SAS Award Flight Scanner"
      assert html =~ "Origins"
      assert html =~ "Destinations"
      assert html =~ "Start Date"
      assert html =~ "End Date"
      assert html =~ "Partner API Credentials"
      assert html =~ "Start Scan"
    end

    test "shows max concurrency input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Max Concurrent Requests"
    end

    test "shows default credential input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "award_cred_name_0"
      assert html =~ "award_cred_value_0"
    end
  end

  describe "form updates" do
    test "updates form values on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        view
        |> element("form")
        |> render_change(%{
          "origins" => "GOT, ARN",
          "destinations" => "CDG, LHR",
          "start_date" => "2026-02-01",
          "end_date" => "2026-02-07"
        })

      assert html =~ "GOT, ARN"
      assert html =~ "CDG, LHR"
    end
  end

  describe "starting a scan" do
    test "starts scan when clicking start button", %{conn: conn} do
      stub_api(fn conn ->
        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      {:ok, view, _html} = live(conn, "/")

      # Fill in the form with credential
      view
      |> element("form")
      |> render_change(%{
        "origins" => "GOT",
        "destinations" => "CDG",
        "start_date" => "2026-01-23",
        "end_date" => "2026-01-23",
        "award_cred_name_0" => "Test Account",
        "award_cred_value_0" => "test_token",
        "max_concurrency" => "1"
      })

      # Click start
      html =
        view
        |> element("button", "Start Scan")
        |> render_click()

      # Should show Stop button when scanning
      assert html =~ "Stop Scan"
    end

    test "displays progress when scan is running", %{conn: conn} do
      stub_api(fn conn ->
        :timer.sleep(10)
        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      {:ok, view, _html} = live(conn, "/")

      view
      |> element("form")
      |> render_change(%{
        "origins" => "GOT",
        "destinations" => "CDG",
        "start_date" => "2026-01-23",
        "end_date" => "2026-01-23",
        "award_cred_name_0" => "Test Account",
        "award_cred_value_0" => "test_token",
        "max_concurrency" => "1"
      })

      view
      |> element("button", "Start Scan")
      |> render_click()

      # Wait for progress update
      :timer.sleep(100)
      html = render(view)

      assert html =~ "Progress"
    end
  end

  describe "stopping a scan" do
    test "stops scan when clicking stop button", %{conn: conn} do
      stub_api(fn conn ->
        :timer.sleep(200)
        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      {:ok, view, _html} = live(conn, "/")

      view
      |> element("form")
      |> render_change(%{
        "origins" => "GOT",
        "destinations" => "CDG",
        "start_date" => "2026-01-23",
        "end_date" => "2026-01-30",
        "award_cred_name_0" => "Test Account",
        "award_cred_value_0" => "test_token",
        "max_concurrency" => "1"
      })

      view
      |> element("button", "Start Scan")
      |> render_click()

      :timer.sleep(10)

      html =
        view
        |> element("button", "Stop Scan")
        |> render_click()

      # Should show Start button again
      assert html =~ "Start Scan"
    end
  end

  describe "displaying results" do
    test "shows found flights in table", %{conn: conn} do
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

      {:ok, view, _html} = live(conn, "/")

      view
      |> element("form")
      |> render_change(%{
        "origins" => "GOT",
        "destinations" => "CDG",
        "start_date" => "2026-01-23",
        "end_date" => "2026-01-23",
        "award_cred_name_0" => "Test Account",
        "award_cred_value_0" => "test_token",
        "max_concurrency" => "1"
      })

      view
      |> element("button", "Start Scan")
      |> render_click()

      # Wait for results
      :timer.sleep(200)
      html = render(view)

      assert html =~ "GOT"
      assert html =~ "CDG"
      assert html =~ "Economy"
      assert html =~ "20000"
    end
  end

  describe "error handling" do
    test "displays error message on scan failure", %{conn: conn} do
      stub_api(fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "Unauthorized"})
      end)

      {:ok, view, _html} = live(conn, "/")

      view
      |> element("form")
      |> render_change(%{
        "origins" => "GOT",
        "destinations" => "CDG",
        "start_date" => "2026-01-23",
        "end_date" => "2026-01-23",
        "award_cred_name_0" => "Test Account",
        "award_cred_value_0" => "bad_token",
        "max_concurrency" => "1"
      })

      view
      |> element("button", "Start Scan")
      |> render_click()

      # Wait for error
      :timer.sleep(200)
      html = render(view)

      assert html =~ "Authentication expired"
    end
  end

  describe "credential management" do
    test "can add a new credential", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Click add credential button (use phx-click to be specific)
      html =
        view
        |> element("button[phx-click=add_award_credential]")
        |> render_click()

      # Should have two credential inputs now
      assert html =~ "award_cred_name_0"
      assert html =~ "award_cred_name_1"
    end

    test "can remove a credential", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Add a credential first
      view
      |> element("button[phx-click=add_award_credential]")
      |> render_click()

      # Now remove the first one (use CSS attribute selector with quotes)
      html =
        view
        |> element(~s|button[phx-click="remove_award_credential"][phx-value-index="0"]|)
        |> render_click()

      # Should still have at least one credential
      assert html =~ "award_cred_name_0"
      refute html =~ "award_cred_name_1"
    end

    test "does not show remove button when only one credential", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      # With only one credential, there should be no Remove button
      refute html =~ "remove_award_credential"
    end
  end
end
