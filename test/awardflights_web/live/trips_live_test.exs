defmodule AwardflightsWeb.TripsLiveTest do
  use AwardflightsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  defp results_file, do: Application.get_env(:awardflights, :results_file, "results.csv")

  setup do
    on_exit(fn ->
      File.rm(results_file())
    end)

    :ok
  end

  describe "mounting" do
    test "renders the trips correlator form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/trips")

      assert html =~ "Trip Correlator"
      assert html =~ "Outbound Start Date"
      assert html =~ "Outbound End Date"
      assert html =~ "Min Trip Days"
      assert html =~ "Max Trip Days"
      assert html =~ "Outbound Departure Airports"
      assert html =~ "Outbound Arrival Airports"
      assert html =~ "Return Departure Airports"
      assert html =~ "Return Arrival Airports"
      assert html =~ "Cabin Classes"
      assert html =~ "Find Trips"
    end

    test "shows link back to scanner", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/trips")

      assert html =~ "Back to Scanner"
    end
  end

  describe "form updates" do
    test "updates form values on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/trips")

      html =
        view
        |> element("form")
        |> render_change(%{
          "outbound_departure" => "GOT, ARN",
          "outbound_arrival" => "CDG, LHR",
          "min_trip_days" => "7",
          "max_trip_days" => "14"
        })

      assert html =~ "GOT, ARN"
      assert html =~ "CDG, LHR"
    end
  end

  describe "finding trips" do
    test "shows message when no trips found", %{conn: conn} do
      # No CSV file, so no trips
      File.rm(results_file())

      {:ok, view, _html} = live(conn, "/trips")

      html =
        view
        |> element("form")
        |> render_submit()

      assert html =~ "No matching trips found"
    end

    test "displays found trips in table", %{conn: conn} do
      csv_content = """
      departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      GOT,CDG,2026-02-01,X,Economy,5,20000,2026-01-18T10:00:00Z
      CDG,GOT,2026-02-08,X,Economy,5,20000,2026-01-18T10:00:00Z
      """

      File.write!(results_file(), csv_content)

      {:ok, view, _html} = live(conn, "/trips")

      view
      |> element("form")
      |> render_change(%{
        "start_date" => "2026-02-01",
        "end_date" => "2026-02-28",
        "min_trip_days" => "5",
        "max_trip_days" => "10",
        "outbound_departure" => "GOT",
        "outbound_arrival" => "CDG",
        "return_departure" => "CDG",
        "return_arrival" => "GOT"
      })

      html =
        view
        |> element("form")
        |> render_submit()

      assert html =~ "Found 1 Round Trips"
      assert html =~ "GOT"
      assert html =~ "CDG"
    end

    test "allows filtering by cabin class", %{conn: conn} do
      csv_content = """
      departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      GOT,CDG,2026-02-01,X,Economy,5,20000,2026-01-18T10:00:00Z
      GOT,CDG,2026-02-01,Z,Business,2,75000,2026-01-18T10:00:00Z
      CDG,GOT,2026-02-08,X,Economy,5,20000,2026-01-18T10:00:00Z
      CDG,GOT,2026-02-08,Z,Business,2,75000,2026-01-18T10:00:00Z
      """

      File.write!(results_file(), csv_content)

      {:ok, view, _html} = live(conn, "/trips")

      view
      |> element("form")
      |> render_change(%{
        "start_date" => "2026-02-01",
        "end_date" => "2026-02-28",
        "min_trip_days" => "5",
        "max_trip_days" => "10",
        "outbound_departure" => "GOT",
        "outbound_arrival" => "CDG",
        "return_departure" => "CDG",
        "return_arrival" => "GOT",
        "cabin_classes" => "Business"
      })

      html =
        view
        |> element("form")
        |> render_submit()

      assert html =~ "Found 1 Round Trips"
      assert html =~ "Business"
    end
  end

  describe "sorting" do
    test "sorts by outbound date by default", %{conn: conn} do
      csv_content = """
      departure,arrival,date,booking_class,cabin,available_tickets,points,timestamp
      GOT,CDG,2026-02-05,X,Economy,5,20000,2026-01-18T10:00:00Z
      GOT,CDG,2026-02-01,X,Economy,5,25000,2026-01-18T10:00:00Z
      CDG,GOT,2026-02-12,X,Economy,5,20000,2026-01-18T10:00:00Z
      CDG,GOT,2026-02-08,X,Economy,5,25000,2026-01-18T10:00:00Z
      """

      File.write!(results_file(), csv_content)

      {:ok, view, _html} = live(conn, "/trips")

      view
      |> element("form")
      |> render_change(%{
        "start_date" => "2026-02-01",
        "end_date" => "2026-02-28",
        "min_trip_days" => "5",
        "max_trip_days" => "10",
        "outbound_departure" => "GOT",
        "outbound_arrival" => "CDG",
        "return_departure" => "CDG",
        "return_arrival" => "GOT"
      })

      html =
        view
        |> element("form")
        |> render_submit()

      # Default sort is by outbound date, so 2026-02-01 should appear before 2026-02-05
      assert html =~ ~r/2026-02-01.*2026-02-05/s
    end
  end
end
