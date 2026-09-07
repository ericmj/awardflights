defmodule AwardflightsWeb.ItineraryComponents do
  @moduledoc "Function components for rendering a flight's itinerary in result tables."
  use Phoenix.Component

  alias Awardflights.Itinerary

  @doc """
  Route with stop airports, followed by times, total duration, layovers and
  one line per segment when segment data is available.
  """
  attr :flight, :map, required: true

  def itinerary(assigns) do
    flight = assigns.flight

    assigns =
      assign(assigns,
        base: Map.get(flight, :departure_time),
        segments: Map.get(flight, :segments) || [],
        stops: Map.get(flight, :stops) || []
      )

    ~H"""
    <div>
      <div class="font-medium text-gray-900">{Itinerary.route(@flight)}</div>
      <div :if={@segments != []} class="mt-1 space-y-0.5 text-xs text-gray-500">
        <div>
          {Itinerary.format_time(@base, @base)} – {Itinerary.format_time(
            Map.get(@flight, :arrival_time),
            @base
          )} · {Itinerary.format_duration(Map.get(@flight, :duration))} · {stops_text(@stops)}
        </div>
        <div :for={segment <- @segments}>{Itinerary.describe_segment(segment, @base)}</div>
      </div>
    </div>
    """
  end

  @doc "Marketing carriers, with the operating carriers underneath when they differ."
  attr :flight, :map, required: true

  def carriers(assigns) do
    flight = assigns.flight
    carriers = Map.get(flight, :carriers) || ""
    operating = Map.get(flight, :operating_carriers) || ""

    assigns =
      assign(assigns,
        carriers: carriers,
        operating: if(operating != "" and operating != carriers, do: operating)
      )

    ~H"""
    <div>
      <div>{@carriers}</div>
      <div :if={@operating} class="text-xs text-gray-400">operated by {@operating}</div>
    </div>
    """
  end

  defp stops_text([]), do: "Direct"

  defp stops_text(stops) do
    label = if length(stops) == 1, do: "1 stop", else: "#{length(stops)} stops"

    details =
      Enum.map_join(stops, ", ", fn stop ->
        [stop.airport, Itinerary.format_duration(stop.duration)]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" ")
      end)

    "#{label}: #{details}"
  end
end
