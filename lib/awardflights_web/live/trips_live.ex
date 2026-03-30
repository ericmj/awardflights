defmodule AwardflightsWeb.TripsLive do
  use AwardflightsWeb, :live_view

  alias Awardflights.TripCorrelator

  @per_page 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       start_date: Date.to_string(Date.utc_today()),
       end_date: Date.to_string(Date.add(Date.utc_today(), 30)),
       min_trip_days: "5",
       max_trip_days: "14",
       min_seats: "1",
       outbound_departure: "",
       outbound_arrival: "",
       return_departure: "",
       return_arrival: "",
       cabin_classes: "",
       source: "",
       trips: [],
       sort_by: :outbound_date,
       searching: false,
       error: nil,
       page: 1,
       total_pages: 1
     )}
  end

  @impl true
  def handle_event("update_form", params, socket) do
    {:noreply,
     assign(socket,
       start_date: params["start_date"] || socket.assigns.start_date,
       end_date: params["end_date"] || socket.assigns.end_date,
       min_trip_days: params["min_trip_days"] || socket.assigns.min_trip_days,
       max_trip_days: params["max_trip_days"] || socket.assigns.max_trip_days,
       min_seats: params["min_seats"] || socket.assigns.min_seats,
       outbound_departure: params["outbound_departure"] || socket.assigns.outbound_departure,
       outbound_arrival: params["outbound_arrival"] || socket.assigns.outbound_arrival,
       return_departure: params["return_departure"] || socket.assigns.return_departure,
       return_arrival: params["return_arrival"] || socket.assigns.return_arrival,
       cabin_classes: params["cabin_classes"] || socket.assigns.cabin_classes,
       source: params["source"] || socket.assigns.source
     )}
  end

  @impl true
  def handle_event("restore_form", params, socket) do
    {:noreply,
     assign(socket,
       start_date: params["start_date"] || socket.assigns.start_date,
       end_date: params["end_date"] || socket.assigns.end_date,
       min_trip_days: params["min_trip_days"] || socket.assigns.min_trip_days,
       max_trip_days: params["max_trip_days"] || socket.assigns.max_trip_days,
       min_seats: params["min_seats"] || socket.assigns.min_seats,
       outbound_departure: params["outbound_departure"] || socket.assigns.outbound_departure,
       outbound_arrival: params["outbound_arrival"] || socket.assigns.outbound_arrival,
       return_departure: params["return_departure"] || socket.assigns.return_departure,
       return_arrival: params["return_arrival"] || socket.assigns.return_arrival,
       cabin_classes: params["cabin_classes"] || socket.assigns.cabin_classes,
       source: params["source"] || socket.assigns.source
     )}
  end

  @impl true
  def handle_event("find_trips", _params, socket) do
    opts = build_filter_opts(socket.assigns)

    trips = TripCorrelator.find_trips(opts)
    sorted_trips = sort_trips(trips, socket.assigns.sort_by)
    total_pages = max(1, ceil(length(sorted_trips) / @per_page))

    # Write results to CSV
    TripCorrelator.write_trips_csv(sorted_trips)

    {:noreply,
     assign(socket,
       trips: sorted_trips,
       searching: false,
       error: if(Enum.empty?(trips), do: "No matching trips found", else: nil),
       page: 1,
       total_pages: total_pages
     )}
  end

  @impl true
  def handle_event("sort_by", %{"field" => field}, socket) do
    sort_by = String.to_existing_atom(field)
    sorted_trips = sort_trips(socket.assigns.trips, sort_by)

    {:noreply, assign(socket, trips: sorted_trips, sort_by: sort_by, page: 1)}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    page = String.to_integer(page)
    page = max(1, min(page, socket.assigns.total_pages))
    {:noreply, assign(socket, page: page)}
  end

  defp build_filter_opts(assigns) do
    [
      start_date: parse_date(assigns.start_date),
      end_date: parse_date(assigns.end_date),
      min_trip_days: parse_int(assigns.min_trip_days, 1),
      max_trip_days: parse_int(assigns.max_trip_days, 365),
      min_seats: parse_int(assigns.min_seats, 1),
      outbound_departure: parse_airports(assigns.outbound_departure),
      outbound_arrival: parse_airports(assigns.outbound_arrival),
      return_departure: parse_airports(assigns.return_departure),
      return_arrival: parse_airports(assigns.return_arrival),
      cabin_classes: parse_cabins(assigns.cabin_classes),
      source: assigns.source
    ]
  end

  defp parse_date(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_airports(str) when str in [nil, ""], do: []

  defp parse_airports(str) do
    str
    |> String.split(~r/[,\s]+/)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.upcase/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp parse_cabins(str) when str in [nil, ""], do: []

  defp parse_cabins(str) do
    str
    |> String.split(~r/[,]+/)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp sort_trips(trips, :outbound_date), do: Enum.sort_by(trips, & &1.outbound.date, Date)
  defp sort_trips(trips, :trip_days), do: Enum.sort_by(trips, & &1.trip_days)
  defp sort_trips(trips, _), do: trips

  defp paginate_trips(trips, page) do
    trips
    |> Enum.drop((page - 1) * @per_page)
    |> Enum.take(@per_page)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-100 py-8">
      <div class="max-w-6xl mx-auto px-4">
        <div class="flex justify-between items-center mb-8">
          <h1 class="text-3xl font-bold text-gray-900">Trip Correlator</h1>
          <a href="/" class="text-blue-600 hover:text-blue-800">← Back to Scanner</a>
        </div>

        <%!-- Filter Form --%>
        <div class="bg-white rounded-lg shadow p-6 mb-6">
          <h2 class="text-xl font-semibold mb-4 text-gray-900">Find Round Trips</h2>

          <form
            id="trips-form"
            phx-hook="PersistForm"
            data-storage-key="trips_form"
            phx-change="update_form"
            phx-submit="find_trips"
            class="space-y-4"
          >
            <%!-- Date Range --%>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Outbound Start Date
                </label>
                <input
                  type="date"
                  name="start_date"
                  value={@start_date}
                  class="mt-1 block w-full rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Outbound End Date
                </label>
                <input
                  type="date"
                  name="end_date"
                  value={@end_date}
                  class="mt-1 block w-full rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                />
              </div>
            </div>

            <%!-- Trip Length & Seats --%>
            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Min Trip Days
                </label>
                <input
                  type="number"
                  name="min_trip_days"
                  value={@min_trip_days}
                  min="1"
                  class="mt-1 block w-full rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Max Trip Days
                </label>
                <input
                  type="number"
                  name="max_trip_days"
                  value={@max_trip_days}
                  min="1"
                  class="mt-1 block w-full rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Min Seats
                </label>
                <input
                  type="number"
                  name="min_seats"
                  value={@min_seats}
                  min="1"
                  class="mt-1 block w-full rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                />
              </div>
            </div>

            <%!-- Outbound Airports --%>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Outbound Departure Airports
                </label>
                <input
                  type="text"
                  name="outbound_departure"
                  value={@outbound_departure}
                  placeholder="GOT, ARN, CPH"
                  class="mt-1 block w-full rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                />
                <p class="mt-1 text-xs text-gray-500">Comma-separated airport codes</p>
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Outbound Arrival Airports
                </label>
                <input
                  type="text"
                  name="outbound_arrival"
                  value={@outbound_arrival}
                  placeholder="CDG, LHR, NYC"
                  class="mt-1 block w-full rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                />
                <p class="mt-1 text-xs text-gray-500">Comma-separated airport codes</p>
              </div>
            </div>

            <%!-- Return Airports --%>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Return Departure Airports
                </label>
                <input
                  type="text"
                  name="return_departure"
                  value={@return_departure}
                  placeholder="CDG, LHR, AMS"
                  class="mt-1 block w-full rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                />
                <p class="mt-1 text-xs text-gray-500">Comma-separated airport codes</p>
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Return Arrival Airports
                </label>
                <input
                  type="text"
                  name="return_arrival"
                  value={@return_arrival}
                  placeholder="GOT, ARN, CPH"
                  class="mt-1 block w-full rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                />
                <p class="mt-1 text-xs text-gray-500">Comma-separated airport codes</p>
              </div>
            </div>

            <%!-- Cabin Classes & Source --%>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Cabin Classes (optional)
                </label>
                <input
                  type="text"
                  name="cabin_classes"
                  value={@cabin_classes}
                  placeholder="Economy, Business"
                  class="mt-1 block w-full rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                />
                <p class="mt-1 text-xs text-gray-500">Leave empty to include all classes</p>
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Source (optional)
                </label>
                <select
                  name="source"
                  class="mt-1 block w-full rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                >
                  <option value="" selected={@source == ""}>All</option>
                  <option value="offers" selected={@source == "offers"}>SAS</option>
                  <option value="award" selected={@source == "award"}>Partner</option>
                </select>
              </div>
            </div>

            <div class="mt-6">
              <button
                type="submit"
                class="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-blue-500"
              >
                Find Trips
              </button>
            </div>
          </form>
        </div>

        <%!-- Error Message --%>
        <div :if={@error} class="bg-yellow-50 border border-yellow-200 rounded-lg p-4 mb-6">
          <p class="text-yellow-800">{@error}</p>
        </div>

        <%!-- Results --%>
        <% paginated_trips = paginate_trips(@trips, @page) %>
        <% start_idx = (@page - 1) * 100 + 1 %>
        <% end_idx = min(@page * 100, length(@trips)) %>
        <div :if={length(@trips) > 0} class="bg-white rounded-lg shadow p-6">
          <div class="flex justify-between items-center mb-4">
            <h2 class="text-xl font-semibold text-gray-900">
              Found {length(@trips)} Round Trips
              <span :if={@total_pages > 1} class="text-base font-normal text-gray-500">
                (showing {start_idx}-{end_idx})
              </span>
            </h2>
            <div class="flex items-center space-x-2">
              <span class="text-sm text-gray-600">Sort by:</span>
              <button
                phx-click="sort_by"
                phx-value-field="outbound_date"
                class={"px-3 py-1 text-sm rounded #{if @sort_by == :outbound_date, do: "bg-blue-600 text-white", else: "bg-gray-200 text-gray-700 hover:bg-gray-300"}"}
              >
                Date
              </button>
              <button
                phx-click="sort_by"
                phx-value-field="trip_days"
                class={"px-3 py-1 text-sm rounded #{if @sort_by == :trip_days, do: "bg-blue-600 text-white", else: "bg-gray-200 text-gray-700 hover:bg-gray-300"}"}
              >
                Duration
              </button>
            </div>
          </div>

          <div class="overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th
                    colspan="7"
                    class="px-4 py-3 text-center text-xs font-medium text-gray-500 uppercase bg-blue-50"
                  >
                    Outbound
                  </th>
                  <th
                    colspan="7"
                    class="px-4 py-3 text-center text-xs font-medium text-gray-500 uppercase bg-green-50"
                  >
                    Return
                  </th>
                  <th class="px-4 py-3 text-center text-xs font-medium text-gray-500 uppercase"></th>
                </tr>
                <tr>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase bg-blue-50">
                    Source
                  </th>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase bg-blue-50">
                    Date
                  </th>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase bg-blue-50">
                    Route
                  </th>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase bg-blue-50">
                    Cabin
                  </th>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase bg-blue-50">
                    Class
                  </th>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase bg-blue-50">
                    Airlines
                  </th>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase bg-blue-50">
                    Seats
                  </th>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase bg-green-50">
                    Source
                  </th>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase bg-green-50">
                    Date
                  </th>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase bg-green-50">
                    Route
                  </th>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase bg-green-50">
                    Cabin
                  </th>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase bg-green-50">
                    Class
                  </th>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase bg-green-50">
                    Airlines
                  </th>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase bg-green-50">
                    Seats
                  </th>
                  <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    Days
                  </th>
                </tr>
              </thead>
              <tbody class="bg-white divide-y divide-gray-200">
                <tr :for={trip <- paginated_trips} class="hover:bg-gray-50">
                  <%!-- Outbound --%>
                  <td class="px-4 py-3 text-sm bg-blue-50/30">
                    <span class={
                      if trip.outbound.source == "offers",
                        do: "text-blue-600 font-medium",
                        else: "text-gray-600"
                    }>
                      {TripCorrelator.format_source(trip.outbound.source)}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-600 bg-blue-50/30">
                    {Date.to_string(trip.outbound.date)}
                  </td>
                  <td class="px-4 py-3 text-sm font-medium text-gray-900 bg-blue-50/30">
                    {trip.outbound.departure} → {trip.outbound.arrival}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-600 bg-blue-50/30">
                    {trip.outbound.cabin}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-600 bg-blue-50/30">
                    {trip.outbound.booking_class}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-600 bg-blue-50/30">
                    {trip.outbound.carriers}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-600 bg-blue-50/30">
                    {trip.outbound.available_tickets}
                  </td>
                  <%!-- Return --%>
                  <td class="px-4 py-3 text-sm bg-green-50/30">
                    <span class={
                      if trip.return.source == "offers",
                        do: "text-blue-600 font-medium",
                        else: "text-gray-600"
                    }>
                      {TripCorrelator.format_source(trip.return.source)}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-600 bg-green-50/30">
                    {Date.to_string(trip.return.date)}
                  </td>
                  <td class="px-4 py-3 text-sm font-medium text-gray-900 bg-green-50/30">
                    {trip.return.departure} → {trip.return.arrival}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-600 bg-green-50/30">
                    {trip.return.cabin}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-600 bg-green-50/30">
                    {trip.return.booking_class}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-600 bg-green-50/30">
                    {trip.return.carriers}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-600 bg-green-50/30">
                    {trip.return.available_tickets}
                  </td>
                  <%!-- Totals --%>
                  <td class="px-4 py-3 text-sm text-gray-600">{trip.trip_days}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <%!-- Pagination Controls --%>
          <div
            :if={@total_pages > 1}
            class="mt-4 flex items-center justify-between border-t border-gray-200 pt-4"
          >
            <div class="text-sm text-gray-600">
              Page {@page} of {@total_pages}
            </div>
            <div class="flex items-center space-x-2">
              <button
                :if={@page > 1}
                phx-click="change_page"
                phx-value-page={1}
                class="px-3 py-1 text-sm rounded bg-gray-200 text-gray-700 hover:bg-gray-300"
              >
                First
              </button>
              <button
                :if={@page > 1}
                phx-click="change_page"
                phx-value-page={@page - 1}
                class="px-3 py-1 text-sm rounded bg-gray-200 text-gray-700 hover:bg-gray-300"
              >
                Previous
              </button>
              <span class="px-3 py-1 text-sm text-gray-600">
                {@page} / {@total_pages}
              </span>
              <button
                :if={@page < @total_pages}
                phx-click="change_page"
                phx-value-page={@page + 1}
                class="px-3 py-1 text-sm rounded bg-gray-200 text-gray-700 hover:bg-gray-300"
              >
                Next
              </button>
              <button
                :if={@page < @total_pages}
                phx-click="change_page"
                phx-value-page={@total_pages}
                class="px-3 py-1 text-sm rounded bg-gray-200 text-gray-700 hover:bg-gray-300"
              >
                Last
              </button>
            </div>
          </div>
        </div>

        <%!-- Info --%>
        <div class="mt-6 bg-gray-50 rounded-lg p-4 text-sm text-gray-600">
          <p><strong>How it works:</strong></p>
          <ul class="list-disc list-inside mt-1 space-y-1">
            <li>Enter your travel criteria above</li>
            <li>The correlator matches outbound flights with valid return flights</li>
            <li>Results are sorted by total points (lowest first)</li>
            <li>Make sure you've run the scanner first to populate results.csv</li>
          </ul>
        </div>
      </div>
    </div>
    """
  end
end
