defmodule AwardflightsWeb.ScanController do
  use AwardflightsWeb, :controller

  alias Awardflights.{FlightScanner, ScanRunner}

  def create(conn, params) do
    case ScanRunner.start(params) do
      {:ok, summary} ->
        json(conn, %{status: "started", config: summary})

      {:error, :already_scanning} ->
        conn |> put_status(409) |> json(%{status: "error", error: "already_scanning"})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{status: "error", error: to_string(reason)})
    end
  end

  def stop(conn, _params) do
    FlightScanner.stop_scan()
    json(conn, %{status: "stopped"})
  end

  def status(conn, _params) do
    s = FlightScanner.get_status()

    json(conn, %{
      scanning: s.scanning,
      completed: s.completed,
      total: s.total,
      results_count: s.results_count,
      award_results_count: Map.get(s, :award_results_count, 0),
      offers_results_count: Map.get(s, :offers_results_count, 0),
      errors_count: s.errors_count,
      skipped_count: s.skipped_count,
      award_in_flight: Map.get(s, :award_in_flight, 0),
      offers_in_flight: Map.get(s, :offers_in_flight, 0),
      award_current: format_current(s.award_current),
      offers_current: format_current(s.offers_current),
      award_paused_until: s.award_paused_until,
      offers_paused_until: s.offers_paused_until
    })
  end

  defp format_current({origin, destination, date}), do: "#{origin}-#{destination} #{date}"
  defp format_current(_), do: nil
end
