defmodule AwardflightsWeb.ScannerLive do
  use AwardflightsWeb, :live_view

  alias Awardflights.{FlightScanner, RateLimitTracker}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      FlightScanner.subscribe()
    end

    status = FlightScanner.get_status()

    # Load persisted rate limits for display (even before scanning starts)
    persisted_rate_limits = RateLimitTracker.get_all_statuses()

    {:ok,
     assign(socket,
       origins: "",
       destinations: "",
       start_date: Date.to_string(Date.utc_today()),
       end_date: Date.to_string(Date.add(Date.utc_today(), 7)),
       # Credential lists: [{name: "", value: ""}, ...]
       award_credentials: [%{name: "Default", value: ""}],
       # Offers credentials: [{name: "", cookies: "", auth_token: ""}, ...]
       offers_credentials: [],
       max_concurrency: 1,
       skip_days: 0,
       scanning: status.scanning,
       award_current: status.award_current,
       offers_current: status.offers_current,
       completed: status.completed,
       total: status.total,
       results_count: status.results_count,
       award_results_count: Map.get(status, :award_results_count, 0),
       offers_results_count: Map.get(status, :offers_results_count, 0),
       errors_count: status.errors_count,
       skipped_count: status.skipped_count,
       award_paused_until: status.award_paused_until,
       offers_paused_until: status.offers_paused_until,
       # Credential status from scanner (during scanning)
       award_credential_statuses: Map.get(status, :award_credentials, []),
       offers_credential_statuses: Map.get(status, :offers_credentials, []),
       award_active_index: Map.get(status, :award_active_index, 0),
       offers_active_index: Map.get(status, :offers_active_index, 0),
       # Persisted rate limits for display before scanning starts
       persisted_rate_limits: persisted_rate_limits,
       results: [],
       last_error: nil
     )}
  end

  @impl true
  def handle_event("restore_form", params, socket) do
    # Restore saved form values from localStorage
    # Handle migration from old single-credential format
    award_credentials =
      case params["award_credentials"] do
        nil ->
          # Check for old format auth_token
          case params["auth_token"] do
            nil -> socket.assigns.award_credentials
            "" -> socket.assigns.award_credentials
            token -> [%{name: "Default", value: token}]
          end

        creds when is_list(creds) ->
          Enum.map(creds, fn c ->
            %{name: c["name"] || "Default", value: c["value"] || ""}
          end)
      end

    offers_credentials =
      case params["offers_credentials"] do
        nil ->
          # Check for old format offers_cookies
          case params["offers_cookies"] do
            nil ->
              socket.assigns.offers_credentials

            "" ->
              socket.assigns.offers_credentials

            cookies ->
              auth_token = params["offers_auth_token"] || ""
              [%{name: "Default", cookies: cookies, auth_token: auth_token}]
          end

        creds when is_list(creds) ->
          Enum.map(creds, fn c ->
            %{
              name: c["name"] || "Default",
              cookies: c["cookies"] || "",
              auth_token: c["auth_token"] || ""
            }
          end)
      end

    {:noreply,
     assign(socket,
       origins: params["origins"] || socket.assigns.origins,
       destinations: params["destinations"] || socket.assigns.destinations,
       start_date: params["start_date"] || socket.assigns.start_date,
       end_date: params["end_date"] || socket.assigns.end_date,
       award_credentials: award_credentials,
       offers_credentials: offers_credentials,
       max_concurrency: parse_int(params["max_concurrency"], socket.assigns.max_concurrency),
       skip_days: parse_int(params["skip_days"], socket.assigns.skip_days)
     )}
  end

  @impl true
  def handle_event("update_form", params, socket) do
    # Update award credentials from indexed form fields
    award_credentials =
      update_credentials_from_params(
        socket.assigns.award_credentials,
        params,
        "award_cred",
        [:name, :value]
      )

    # Update offers credentials from indexed form fields
    offers_credentials =
      update_credentials_from_params(
        socket.assigns.offers_credentials,
        params,
        "offers_cred",
        [:name, :cookies, :auth_token]
      )

    {:noreply,
     assign(socket,
       origins: params["origins"] || socket.assigns.origins,
       destinations: params["destinations"] || socket.assigns.destinations,
       start_date: params["start_date"] || socket.assigns.start_date,
       end_date: params["end_date"] || socket.assigns.end_date,
       award_credentials: award_credentials,
       offers_credentials: offers_credentials,
       max_concurrency: parse_int(params["max_concurrency"], socket.assigns.max_concurrency),
       skip_days: parse_int(params["skip_days"], socket.assigns.skip_days)
     )}
  end

  @impl true
  def handle_event("start_scan", _params, socket) do
    origins = parse_airports(socket.assigns.origins)
    destinations = parse_airports(socket.assigns.destinations)

    # Filter out credentials with empty values
    award_credentials =
      socket.assigns.award_credentials
      |> Enum.filter(fn c -> c.value != nil and c.value != "" end)
      |> Enum.map(fn c -> %{name: c.name, value: c.value} end)

    offers_credentials =
      socket.assigns.offers_credentials
      |> Enum.filter(fn c -> c.cookies != nil and c.cookies != "" end)
      |> Enum.map(fn c -> %{name: c.name, cookies: c.cookies, auth_token: c.auth_token} end)

    config = %{
      origins: origins,
      destinations: destinations,
      start_date: socket.assigns.start_date,
      end_date: socket.assigns.end_date,
      award_credentials: award_credentials,
      offers_credentials: offers_credentials,
      max_concurrency: socket.assigns.max_concurrency,
      skip_days: socket.assigns.skip_days
    }

    case FlightScanner.start_scan(config) do
      :ok ->
        # Initialize credential statuses with persisted rate limit data
        persisted = RateLimitTracker.get_all_statuses()

        award_statuses =
          Enum.map(award_credentials, fn cred ->
            persisted_status = Enum.find(persisted.award, &(&1.name == cred.name))

            %{
              name: cred.name,
              rate_limited_until: persisted_status && persisted_status.rate_limited_until,
              expired: (persisted_status && persisted_status.expired) || false
            }
          end)

        offers_statuses =
          Enum.map(offers_credentials, fn cred ->
            persisted_status = Enum.find(persisted.offers, &(&1.name == cred.name))

            %{
              name: cred.name,
              rate_limited_until: persisted_status && persisted_status.rate_limited_until,
              expired: (persisted_status && persisted_status.expired) || false
            }
          end)

        {:noreply,
         assign(socket,
           scanning: true,
           results: [],
           last_error: nil,
           award_paused_until: nil,
           offers_paused_until: nil,
           award_results_count: 0,
           offers_results_count: 0,
           award_credential_statuses: award_statuses,
           offers_credential_statuses: offers_statuses,
           award_active_index: 0,
           offers_active_index: 0
         )}

      {:error, :already_scanning} ->
        {:noreply, assign(socket, last_error: "Scan already in progress")}
    end
  end

  @impl true
  def handle_event("stop_scan", _params, socket) do
    FlightScanner.stop_scan()
    {:noreply, assign(socket, scanning: false)}
  end

  @impl true
  def handle_event("swap_airports", _params, socket) do
    {:noreply,
     assign(socket,
       origins: socket.assigns.destinations,
       destinations: socket.assigns.origins
     )}
  end

  @impl true
  def handle_event("add_award_credential", _params, socket) do
    new_credential = %{name: "Account #{length(socket.assigns.award_credentials) + 1}", value: ""}

    {:noreply,
     assign(socket, award_credentials: socket.assigns.award_credentials ++ [new_credential])}
  end

  @impl true
  def handle_event("remove_award_credential", %{"index" => index}, socket) do
    index = String.to_integer(index)
    credentials = List.delete_at(socket.assigns.award_credentials, index)
    # Ensure at least one credential exists
    credentials = if credentials == [], do: [%{name: "Default", value: ""}], else: credentials
    {:noreply, assign(socket, award_credentials: credentials)}
  end

  @impl true
  def handle_event("add_offers_credential", _params, socket) do
    new_credential = %{
      name: "Account #{length(socket.assigns.offers_credentials) + 1}",
      cookies: "",
      auth_token: ""
    }

    {:noreply,
     assign(socket, offers_credentials: socket.assigns.offers_credentials ++ [new_credential])}
  end

  @impl true
  def handle_event("remove_offers_credential", %{"index" => index}, socket) do
    index = String.to_integer(index)
    credentials = List.delete_at(socket.assigns.offers_credentials, index)
    {:noreply, assign(socket, offers_credentials: credentials)}
  end

  @impl true
  def handle_info({:progress, payload}, socket) do
    {:noreply,
     assign(socket,
       award_current: payload.award_current,
       offers_current: payload.offers_current,
       completed: payload.completed,
       total: payload.total,
       results_count: payload.results_count,
       award_results_count:
         Map.get(payload, :award_results_count, socket.assigns.award_results_count),
       offers_results_count:
         Map.get(payload, :offers_results_count, socket.assigns.offers_results_count),
       errors_count: payload.errors_count,
       skipped_count: payload.skipped_count
     )}
  end

  @impl true
  def handle_info({:flights_found, payload}, socket) do
    # Add received timestamp to new flights for sorting by scan order
    now = System.monotonic_time(:millisecond)
    timestamped_flights = Enum.map(payload.flights, &Map.put(&1, :received_at, now))
    new_results = timestamped_flights ++ socket.assigns.results

    # Aggregate duplicates (same route/date/cabin/class/points) by summing seats, then keep last 100
    aggregated = aggregate_results(new_results)
    {:noreply, assign(socket, results: Enum.take(aggregated, 100))}
  end

  @impl true
  def handle_info({:scan_error, payload}, socket) do
    error_msg =
      "Error scanning #{payload.origin}->#{payload.destination} on #{payload.date}: #{format_error(payload.error)}"

    {:noreply, assign(socket, last_error: error_msg)}
  end

  @impl true
  def handle_info({:scan_complete, _payload}, socket) do
    {:noreply, assign(socket, scanning: false)}
  end

  @impl true
  def handle_info({:scan_stopped, _payload}, socket) do
    {:noreply, assign(socket, scanning: false)}
  end

  @impl true
  def handle_info({:request_skipped, _payload}, socket) do
    # Just update skipped count - progress handler already updates it
    {:noreply, socket}
  end

  @impl true
  def handle_info({:rate_limited, payload}, socket) do
    # Update credential status and paused_until (all credentials rate limited)
    case payload.source do
      :award ->
        statuses =
          update_credential_status(
            socket.assigns.award_credential_statuses,
            payload.credential_index,
            payload.resume_at
          )

        {:noreply,
         assign(socket,
           award_paused_until: payload.resume_at,
           award_credential_statuses: statuses
         )}

      :offers ->
        statuses =
          update_credential_status(
            socket.assigns.offers_credential_statuses,
            payload.credential_index,
            payload.resume_at
          )

        {:noreply,
         assign(socket,
           offers_paused_until: payload.resume_at,
           offers_credential_statuses: statuses
         )}
    end
  end

  @impl true
  def handle_info({:credential_rotated, payload}, socket) do
    # Update active index and mark the from credential as rate limited or expired
    case payload.source do
      :award ->
        statuses =
          if Map.get(payload, :from_expired, false) do
            mark_credential_expired_status(
              socket.assigns.award_credential_statuses,
              payload.from_index
            )
          else
            update_credential_status(
              socket.assigns.award_credential_statuses,
              payload.from_index,
              payload.from_rate_limited_until
            )
          end

        {:noreply,
         assign(socket, award_active_index: payload.to_index, award_credential_statuses: statuses)}

      :offers ->
        statuses =
          if Map.get(payload, :from_expired, false) do
            mark_credential_expired_status(
              socket.assigns.offers_credential_statuses,
              payload.from_index
            )
          else
            update_credential_status(
              socket.assigns.offers_credential_statuses,
              payload.from_index,
              payload.from_rate_limited_until
            )
          end

        {:noreply,
         assign(socket,
           offers_active_index: payload.to_index,
           offers_credential_statuses: statuses
         )}
    end
  end

  @impl true
  def handle_info({:credential_expired, payload}, socket) do
    # Mark the credential as expired in the UI
    case payload.source do
      :award ->
        statuses =
          mark_credential_expired_status(
            socket.assigns.award_credential_statuses,
            payload.credential_index
          )

        {:noreply, assign(socket, award_credential_statuses: statuses)}

      :offers ->
        statuses =
          mark_credential_expired_status(
            socket.assigns.offers_credential_statuses,
            payload.credential_index
          )

        {:noreply, assign(socket, offers_credential_statuses: statuses)}
    end
  end

  @impl true
  def handle_info({:rate_limit_cleared, payload}, socket) do
    credential_index = Map.get(payload, :credential_index, 0)

    case payload.source do
      :award ->
        statuses =
          clear_credential_status(socket.assigns.award_credential_statuses, credential_index)

        paused = compute_api_paused(statuses)

        {:noreply,
         assign(socket, award_paused_until: paused, award_credential_statuses: statuses)}

      :offers ->
        statuses =
          clear_credential_status(socket.assigns.offers_credential_statuses, credential_index)

        paused = compute_api_paused(statuses)

        {:noreply,
         assign(socket, offers_paused_until: paused, offers_credential_statuses: statuses)}
    end
  end

  defp aggregate_results(results) do
    results
    |> Enum.group_by(fn r ->
      {Map.get(r, :source, :award), r.departure, r.arrival, r.date, r.booking_class, r.cabin,
       r.points}
    end)
    |> Enum.map(fn {_key, group} ->
      # Use the most recent received_at from the group
      most_recent = Enum.max_by(group, &Map.get(&1, :received_at, 0))
      total_seats = Enum.sum(Enum.map(group, & &1.available_tickets))
      Map.put(most_recent, :available_tickets, total_seats)
    end)
    # Sort by received_at descending (most recently scanned first)
    |> Enum.sort_by(fn r -> Map.get(r, :received_at, 0) end, :desc)
  end

  defp parse_airports(str) do
    str
    |> String.split(~r/[,\s]+/)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.upcase/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  defp format_error(:auth_expired), do: "Authentication expired"
  defp format_error({:rate_limited, seconds}), do: "Rate limited (#{seconds}s)"
  defp format_error({:http_error, status, _}), do: "HTTP #{status}"
  defp format_error(:cloudflare_blocked), do: "Cloudflare blocked"
  defp format_error(:timeout), do: "Timeout"
  defp format_error(:connection_pool_exhausted), do: "Connection pool exhausted"
  defp format_error(_), do: "Request failed"

  defp format_source(:award), do: "Partner"
  defp format_source(:offers), do: "SAS"
  defp format_source(_), do: "Partner"

  defp progress_percentage(completed, total) when total > 0 do
    Float.round(completed / total * 100, 1)
  end

  defp progress_percentage(_, _), do: 0

  # Update credentials from indexed form params (e.g., award_cred_name_0, award_cred_value_0)
  defp update_credentials_from_params(credentials, params, prefix, fields) do
    Enum.with_index(credentials)
    |> Enum.map(fn {cred, index} ->
      Enum.reduce(fields, cred, fn field, acc ->
        key = "#{prefix}_#{field}_#{index}"

        case Map.get(params, key) do
          nil -> acc
          value -> Map.put(acc, field, value)
        end
      end)
    end)
  end

  # Update a credential's rate_limited_until status
  defp update_credential_status(statuses, index, resume_at) when index < length(statuses) do
    List.update_at(statuses, index, fn status ->
      Map.put(status, :rate_limited_until, resume_at)
    end)
  end

  defp update_credential_status(statuses, _index, _resume_at), do: statuses

  # Clear a credential's rate_limited_until status
  defp clear_credential_status(statuses, index) when index < length(statuses) do
    List.update_at(statuses, index, fn status ->
      Map.put(status, :rate_limited_until, nil)
    end)
  end

  defp clear_credential_status(statuses, _index), do: statuses

  # Mark a credential as expired
  defp mark_credential_expired_status(statuses, index) when index < length(statuses) do
    List.update_at(statuses, index, fn status ->
      Map.put(status, :expired, true)
    end)
  end

  defp mark_credential_expired_status(statuses, _index), do: statuses

  # Check if all credentials are rate limited, return earliest resume time or nil
  defp compute_api_paused([]), do: nil

  defp compute_api_paused(statuses) do
    now = DateTime.utc_now()

    active_limits =
      statuses
      |> Enum.map(&Map.get(&1, :rate_limited_until))
      |> Enum.filter(fn
        nil -> false
        until_time -> DateTime.compare(now, until_time) == :lt
      end)

    if length(active_limits) == length(statuses) do
      Enum.min(active_limits, DateTime)
    else
      nil
    end
  end

  # Check if a credential is rate limited
  defp credential_rate_limited?(statuses, index) do
    case Enum.at(statuses, index) do
      nil ->
        false

      status ->
        case Map.get(status, :rate_limited_until) do
          nil -> false
          until_time -> DateTime.compare(DateTime.utc_now(), until_time) == :lt
        end
    end
  end

  # Check if a credential is expired
  defp credential_expired?(statuses, index) do
    case Enum.at(statuses, index) do
      nil -> false
      status -> Map.get(status, :expired, false)
    end
  end

  # Get time remaining for rate limit
  defp rate_limit_time_remaining(statuses, index) do
    case Enum.at(statuses, index) do
      nil ->
        nil

      status ->
        case Map.get(status, :rate_limited_until) do
          nil ->
            nil

          until_time ->
            diff = DateTime.diff(until_time, DateTime.utc_now())
            if diff > 0, do: diff, else: nil
        end
    end
  end

  defp rate_limit_until(statuses, index) do
    case Enum.at(statuses, index) do
      nil -> nil
      status -> Map.get(status, :rate_limited_until)
    end
  end

  # Determine border class for credential based on its status
  defp credential_border_class(source, scanning, index, active_index, statuses) do
    default_class =
      if source == :award, do: "border-gray-200 bg-white", else: "border-blue-100 bg-white"

    if scanning && index == active_index &&
         !credential_expired?(statuses, index) &&
         !credential_rate_limited?(statuses, index) do
      "border-green-400 bg-green-50"
    else
      default_class
    end
  end

  # Get active credential name
  defp active_credential_name(credentials, index) do
    case Enum.at(credentials, index) do
      nil -> "Unknown"
      cred -> Map.get(cred, :name, "Unknown")
    end
  end

  # Check if there are any active (non-expired) persisted rate limits
  defp has_active_rate_limits?(persisted_rate_limits) do
    now = DateTime.utc_now()

    has_active = fn limits ->
      Enum.any?(limits, fn limit ->
        cond do
          limit.expired -> true
          limit.rate_limited_until == nil -> false
          DateTime.compare(now, limit.rate_limited_until) == :lt -> true
          true -> false
        end
      end)
    end

    has_active.(persisted_rate_limits.award) || has_active.(persisted_rate_limits.offers)
  end

  # Check if a persisted rate limit is still active
  defp persisted_limit_active?(limit) do
    cond do
      limit.expired -> true
      limit.rate_limited_until == nil -> false
      DateTime.compare(DateTime.utc_now(), limit.rate_limited_until) == :lt -> true
      true -> false
    end
  end

  # Format DateTime for display
  defp format_rate_limit_time(nil), do: ""

  defp format_rate_limit_time(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-100 py-8">
      <div class="max-w-6xl mx-auto px-4">
        <div class="flex justify-between items-center mb-8">
          <h1 class="text-3xl font-bold text-gray-900">SAS Award Flight Scanner</h1>
          <a href="/trips" class="text-blue-600 hover:text-blue-800">Trip Correlator →</a>
        </div>

        <%!-- Persisted Rate Limits Warning --%>
        <div
          :if={!@scanning && has_active_rate_limits?(@persisted_rate_limits)}
          class="bg-yellow-50 border border-yellow-200 rounded-lg p-4 mb-6"
        >
          <h3 class="font-semibold text-yellow-800 mb-2">Active Rate Limits</h3>
          <p class="text-sm text-yellow-700 mb-3">
            These credentials are rate limited or expired. Starting a scan will skip them until the limit expires.
          </p>

          <div class="space-y-2">
            <div
              :for={limit <- @persisted_rate_limits.award}
              :if={persisted_limit_active?(limit)}
              class="flex items-center gap-2"
            >
              <span class="text-xs font-medium text-gray-500 w-16">Partner:</span>
              <span class="font-mono text-sm text-gray-800">{limit.name}</span>
              <span
                :if={limit.expired}
                class="inline-flex items-center px-2 py-0.5 rounded text-xs bg-red-100 text-red-800"
              >
                Auth Expired
              </span>
              <span
                :if={!limit.expired && limit.rate_limited_until}
                class="inline-flex items-center px-2 py-0.5 rounded text-xs bg-yellow-100 text-yellow-800"
                id={"persisted-rate-limit-award-#{limit.name}"}
                phx-hook="RateLimitCountdown"
                data-utc={DateTime.to_iso8601(limit.rate_limited_until)}
              >
                Rate limited until {format_rate_limit_time(limit.rate_limited_until)}
              </span>
            </div>
            <div
              :for={limit <- @persisted_rate_limits.offers}
              :if={persisted_limit_active?(limit)}
              class="flex items-center gap-2"
            >
              <span class="text-xs font-medium text-blue-500 w-16">SAS:</span>
              <span class="font-mono text-sm text-gray-800">{limit.name}</span>
              <span
                :if={limit.expired}
                class="inline-flex items-center px-2 py-0.5 rounded text-xs bg-red-100 text-red-800"
              >
                Auth Expired
              </span>
              <span
                :if={!limit.expired && limit.rate_limited_until}
                class="inline-flex items-center px-2 py-0.5 rounded text-xs bg-yellow-100 text-yellow-800"
                id={"persisted-rate-limit-offers-#{limit.name}"}
                phx-hook="RateLimitCountdown"
                data-utc={DateTime.to_iso8601(limit.rate_limited_until)}
              >
                Rate limited until {format_rate_limit_time(limit.rate_limited_until)}
              </span>
            </div>
          </div>
        </div>

        <%!-- Configuration Form --%>
        <div class="bg-white rounded-lg shadow p-6 mb-6">
          <h2 class="text-xl font-semibold mb-4 text-gray-900">Configuration</h2>

          <form id="scanner-form" phx-hook="PersistForm" phx-change="update_form" class="space-y-4">
            <div class="flex items-center gap-2">
              <input
                type="text"
                name="origins"
                value={@origins}
                placeholder="Origins (e.g. GOT, ARN, CPH)"
                class="flex-1 rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                disabled={@scanning}
              />
              <button
                type="button"
                phx-click="swap_airports"
                class="p-2 text-gray-500 hover:text-blue-600 hover:bg-gray-100 rounded-full transition-colors"
                title="Swap origins and destinations"
                disabled={@scanning}
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-5 w-5"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M8 7h12m0 0l-4-4m4 4l-4 4m0 6H4m0 0l4 4m-4-4l4-4"
                  />
                </svg>
              </button>
              <input
                type="text"
                name="destinations"
                value={@destinations}
                placeholder="Destinations (e.g. CDG, LHR, NYC)"
                class="flex-1 rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                disabled={@scanning}
              />
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700">Start Date</label>
                <input
                  type="date"
                  name="start_date"
                  value={@start_date}
                  class="mt-1 block w-full rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                  disabled={@scanning}
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">End Date</label>
                <input
                  type="date"
                  name="end_date"
                  value={@end_date}
                  class="mt-1 block w-full rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                  disabled={@scanning}
                />
              </div>
            </div>

            <%!-- Partner API (award-api) Credentials --%>
            <div class="border border-gray-200 rounded-lg p-4 bg-gray-50">
              <div class="flex justify-between items-center mb-3">
                <h3 class="text-sm font-semibold text-gray-800">Partner API Credentials</h3>
                <button
                  type="button"
                  phx-click="add_award_credential"
                  class="text-xs px-2 py-1 bg-gray-200 hover:bg-gray-300 rounded text-gray-700"
                  disabled={@scanning}
                >
                  + Add Account
                </button>
              </div>

              <div class="space-y-3">
                <div
                  :for={{cred, index} <- Enum.with_index(@award_credentials)}
                  class={"p-3 rounded border #{credential_border_class(:award, @scanning, index, @award_active_index, @award_credential_statuses)}"}
                >
                  <div class="flex items-center gap-2 mb-2">
                    <input
                      type="text"
                      name={"award_cred_name_#{index}"}
                      value={cred.name}
                      placeholder="Account name"
                      class="flex-1 rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500 text-sm"
                      disabled={@scanning}
                    />
                    <button
                      :if={length(@award_credentials) > 1}
                      type="button"
                      phx-click="remove_award_credential"
                      phx-value-index={index}
                      class="text-xs px-2 py-1 text-red-600 hover:bg-red-50 rounded"
                      disabled={@scanning}
                    >
                      Remove
                    </button>
                  </div>
                  <textarea
                    name={"award_cred_value_#{index}"}
                    rows="2"
                    placeholder="Paste Bearer token (JWT) or full cookie string from browser..."
                    class="block w-full rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500 font-mono text-xs"
                    disabled={@scanning}
                  ><%= cred.value %></textarea>

                  <%!-- Status indicator when scanning --%>
                  <div :if={@scanning && length(@award_credential_statuses) > 0} class="mt-2 text-xs">
                    <span
                      :if={credential_expired?(@award_credential_statuses, index)}
                      class="inline-flex items-center px-2 py-0.5 rounded bg-red-100 text-red-800"
                    >
                      Expired
                    </span>
                    <span
                      :if={
                        !credential_expired?(@award_credential_statuses, index) &&
                          index == @award_active_index &&
                          !credential_rate_limited?(@award_credential_statuses, index)
                      }
                      class="inline-flex items-center px-2 py-0.5 rounded bg-green-100 text-green-800"
                    >
                      Active
                    </span>
                    <span
                      :if={
                        !credential_expired?(@award_credential_statuses, index) &&
                          credential_rate_limited?(@award_credential_statuses, index)
                      }
                      class="inline-flex items-center px-2 py-0.5 rounded bg-yellow-100 text-yellow-800"
                      id={"scanning-rate-limit-award-#{index}"}
                      phx-hook="RateLimitCountdown"
                      data-utc={
                        rate_limit_until(@award_credential_statuses, index) &&
                          DateTime.to_iso8601(rate_limit_until(@award_credential_statuses, index))
                      }
                    >
                      Rate limited ({rate_limit_time_remaining(@award_credential_statuses, index)}s)
                    </span>
                    <span
                      :if={
                        !credential_expired?(@award_credential_statuses, index) &&
                          !credential_rate_limited?(@award_credential_statuses, index) &&
                          index != @award_active_index
                      }
                      class="inline-flex items-center px-2 py-0.5 rounded bg-gray-100 text-gray-600"
                    >
                      Ready
                    </span>
                  </div>
                </div>
              </div>
            </div>

            <%!-- SAS API (offers-api) Credentials --%>
            <div class="border border-blue-200 rounded-lg p-4 bg-blue-50">
              <div class="flex justify-between items-center mb-3">
                <h3 class="text-sm font-semibold text-blue-800">
                  SAS Direct API Credentials (Optional)
                </h3>
                <button
                  type="button"
                  phx-click="add_offers_credential"
                  class="text-xs px-2 py-1 bg-blue-200 hover:bg-blue-300 rounded text-blue-700"
                  disabled={@scanning}
                >
                  + Add Account
                </button>
              </div>

              <div :if={@offers_credentials == []} class="text-sm text-gray-500 italic">
                No SAS Direct credentials configured. Click "Add Account" to add one.
              </div>

              <div class="space-y-3">
                <div
                  :for={{cred, index} <- Enum.with_index(@offers_credentials)}
                  class={"p-3 rounded border #{credential_border_class(:offers, @scanning, index, @offers_active_index, @offers_credential_statuses)}"}
                >
                  <div class="flex items-center gap-2 mb-2">
                    <input
                      type="text"
                      name={"offers_cred_name_#{index}"}
                      value={cred.name}
                      placeholder="Account name"
                      class="flex-1 rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500 text-sm"
                      disabled={@scanning}
                    />
                    <button
                      type="button"
                      phx-click="remove_offers_credential"
                      phx-value-index={index}
                      class="text-xs px-2 py-1 text-red-600 hover:bg-red-50 rounded"
                      disabled={@scanning}
                    >
                      Remove
                    </button>
                  </div>
                  <textarea
                    name={"offers_cred_cookies_#{index}"}
                    rows="2"
                    placeholder="Paste full cookie string from browser DevTools..."
                    class="block w-full rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500 font-mono text-xs"
                    disabled={@scanning}
                  ><%= cred.cookies %></textarea>
                  <p class="mt-1 text-xs text-gray-500">
                    LOGIN_AUTH JWT will be extracted automatically from cookies
                  </p>

                  <%!-- Status indicator when scanning --%>
                  <div :if={@scanning && length(@offers_credential_statuses) > 0} class="mt-2 text-xs">
                    <span
                      :if={credential_expired?(@offers_credential_statuses, index)}
                      class="inline-flex items-center px-2 py-0.5 rounded bg-red-100 text-red-800"
                    >
                      Expired
                    </span>
                    <span
                      :if={
                        !credential_expired?(@offers_credential_statuses, index) &&
                          index == @offers_active_index &&
                          !credential_rate_limited?(@offers_credential_statuses, index)
                      }
                      class="inline-flex items-center px-2 py-0.5 rounded bg-green-100 text-green-800"
                    >
                      Active
                    </span>
                    <span
                      :if={
                        !credential_expired?(@offers_credential_statuses, index) &&
                          credential_rate_limited?(@offers_credential_statuses, index)
                      }
                      class="inline-flex items-center px-2 py-0.5 rounded bg-yellow-100 text-yellow-800"
                      id={"scanning-rate-limit-offers-#{index}"}
                      phx-hook="RateLimitCountdown"
                      data-utc={
                        rate_limit_until(@offers_credential_statuses, index) &&
                          DateTime.to_iso8601(rate_limit_until(@offers_credential_statuses, index))
                      }
                    >
                      Rate limited ({rate_limit_time_remaining(@offers_credential_statuses, index)}s)
                    </span>
                    <span
                      :if={
                        !credential_expired?(@offers_credential_statuses, index) &&
                          !credential_rate_limited?(@offers_credential_statuses, index) &&
                          index != @offers_active_index
                      }
                      class="inline-flex items-center px-2 py-0.5 rounded bg-gray-100 text-gray-600"
                    >
                      Ready
                    </span>
                  </div>
                </div>
              </div>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Max Concurrent Requests
                </label>
                <input
                  type="number"
                  name="max_concurrency"
                  value={@max_concurrency}
                  min="1"
                  max="10"
                  class="mt-1 block w-full rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                  disabled={@scanning}
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Skip if scanned within (days)
                </label>
                <input
                  type="number"
                  name="skip_days"
                  value={@skip_days}
                  min="0"
                  max="365"
                  class="mt-1 block w-full rounded-md border-gray-300 bg-white text-gray-900 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                  disabled={@scanning}
                />
                <p class="mt-1 text-xs text-gray-500">0 = don't skip</p>
              </div>
            </div>
          </form>

          <div class="mt-6 flex space-x-4">
            <button
              :if={!@scanning}
              phx-click="start_scan"
              class="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-blue-500"
            >
              Start Scan
            </button>
            <button
              :if={@scanning}
              phx-click="stop_scan"
              class="px-4 py-2 bg-red-600 text-white rounded-md hover:bg-red-700 focus:outline-none focus:ring-2 focus:ring-red-500"
            >
              Stop Scan
            </button>
          </div>
        </div>

        <%!-- Progress Section --%>
        <div :if={@scanning || @completed > 0} class="bg-white rounded-lg shadow p-6 mb-6">
          <h2 class="text-xl font-semibold mb-4 text-gray-900">Progress</h2>

          <div :if={@award_paused_until || @offers_paused_until} class="mb-4 space-y-2">
            <div
              :if={@award_paused_until}
              class="p-3 bg-yellow-50 border border-yellow-200 rounded-md"
            >
              <div class="flex items-center text-yellow-800">
                <svg class="w-5 h-5 mr-2 flex-shrink-0" fill="currentColor" viewBox="0 0 20 20">
                  <path
                    fill-rule="evenodd"
                    d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
                    clip-rule="evenodd"
                  />
                </svg>
                <span class="font-medium">
                  <span class="text-gray-700">Partner API</span>
                  rate limited until
                  <span
                    id="award-paused-until"
                    phx-hook="LocalTime"
                    data-utc={DateTime.to_iso8601(@award_paused_until)}
                  >
                    {Calendar.strftime(@award_paused_until, "%H:%M:%S")} UTC
                  </span>
                </span>
              </div>
            </div>
            <div :if={@offers_paused_until} class="p-3 bg-blue-50 border border-blue-200 rounded-md">
              <div class="flex items-center text-blue-800">
                <svg class="w-5 h-5 mr-2 flex-shrink-0" fill="currentColor" viewBox="0 0 20 20">
                  <path
                    fill-rule="evenodd"
                    d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
                    clip-rule="evenodd"
                  />
                </svg>
                <span class="font-medium">
                  <span class="text-blue-700">SAS Direct API</span>
                  rate limited until
                  <span
                    id="offers-paused-until"
                    phx-hook="LocalTime"
                    data-utc={DateTime.to_iso8601(@offers_paused_until)}
                  >
                    {Calendar.strftime(@offers_paused_until, "%H:%M:%S")} UTC
                  </span>
                </span>
              </div>
            </div>
          </div>

          <div class="mb-4">
            <div class="flex justify-between text-sm text-gray-600 mb-1">
              <div class="flex flex-col gap-0.5">
                <div :if={@scanning && @award_current} class="flex items-center gap-1">
                  <span class="text-xs font-medium text-gray-500">
                    Partner <span :if={length(@award_credentials) > 1} class="text-gray-400">
                      ({active_credential_name(@award_credentials, @award_active_index)})
                    </span>:
                  </span>
                  <span :if={@award_paused_until} class="text-yellow-600">paused</span>
                  <span :if={!@award_paused_until}>
                    {elem(@award_current, 0)} → {elem(@award_current, 1)} ({elem(@award_current, 2)})
                  </span>
                </div>
                <div :if={@scanning && @offers_current} class="flex items-center gap-1">
                  <span class="text-xs font-medium text-blue-500">
                    SAS <span :if={length(@offers_credentials) > 1} class="text-blue-400">
                      ({active_credential_name(@offers_credentials, @offers_active_index)})
                    </span>:
                  </span>
                  <span :if={@offers_paused_until} class="text-yellow-600">paused</span>
                  <span :if={!@offers_paused_until}>
                    {elem(@offers_current, 0)} → {elem(@offers_current, 1)} ({elem(@offers_current, 2)})
                  </span>
                </div>
                <span :if={!@scanning}>Scan complete</span>
                <span :if={@scanning && !@award_current && !@offers_current}>Starting...</span>
              </div>
              <span>{@completed}/{@total} ({progress_percentage(@completed, @total)}%)</span>
            </div>
            <div class="w-full bg-gray-200 rounded-full h-2">
              <div
                class={"h-2 rounded-full transition-all duration-300 #{if @award_paused_until && @offers_paused_until, do: "bg-yellow-500", else: "bg-blue-600"}"}
                style={"width: #{progress_percentage(@completed, @total)}%"}
              >
              </div>
            </div>
          </div>

          <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-7 gap-4 text-center">
            <div class="bg-green-50 rounded p-3">
              <div class="text-2xl font-bold text-green-600">{@results_count}</div>
              <div class="text-sm text-gray-600">Total Flights</div>
            </div>
            <div class="bg-gray-50 rounded p-3">
              <div class="text-2xl font-bold text-gray-700">{@award_results_count}</div>
              <div class="text-sm text-gray-600">Partner API</div>
            </div>
            <div class="bg-blue-50 rounded p-3">
              <div class="text-2xl font-bold text-blue-700">{@offers_results_count}</div>
              <div class="text-sm text-gray-600">SAS Direct</div>
            </div>
            <div class="bg-gray-50 rounded p-3">
              <div class="text-2xl font-bold text-red-600">{@errors_count}</div>
              <div class="text-sm text-gray-600">Errors</div>
            </div>
            <div class="bg-gray-50 rounded p-3">
              <div class="text-2xl font-bold text-amber-600">{@skipped_count}</div>
              <div class="text-sm text-gray-600">Skipped</div>
            </div>
            <div class="bg-gray-50 rounded p-3">
              <div class="text-2xl font-bold text-blue-600">{@completed}</div>
              <div class="text-sm text-gray-600">Completed</div>
            </div>
            <div class="bg-gray-50 rounded p-3">
              <div class="text-2xl font-bold text-gray-600">{@total - @completed}</div>
              <div class="text-sm text-gray-600">Remaining</div>
            </div>
          </div>

          <div :if={@last_error} class="mt-4 p-3 bg-red-50 text-red-700 rounded-md text-sm">
            {@last_error}
          </div>
        </div>

        <%!-- Results Table --%>
        <div :if={length(@results) > 0} class="bg-white rounded-lg shadow p-6 mb-6">
          <h2 class="text-xl font-semibold mb-4 text-gray-900">Recent Results (last 100)</h2>
          <p class="text-sm text-gray-600 mb-4">Full results are saved to results.csv</p>

          <div class="overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Source
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Route
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Date
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Cabin
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Class
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Airlines
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Seats
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Points
                  </th>
                </tr>
              </thead>
              <tbody class="bg-white divide-y divide-gray-200">
                <tr :for={result <- @results} class="hover:bg-gray-50">
                  <td class="px-4 py-3 text-sm text-gray-600">
                    <span class={
                      if Map.get(result, :source) == :offers,
                        do: "text-blue-600 font-medium",
                        else: "text-gray-600"
                    }>
                      {format_source(Map.get(result, :source, :award))}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-sm font-medium text-gray-900">
                    {result.departure} → {result.arrival}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-600">{result.date}</td>
                  <td class="px-4 py-3 text-sm text-gray-600">
                    {Awardflights.TripCorrelator.resolve_cabin(result.cabin, result.booking_class)}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-600">{result.booking_class}</td>
                  <td class="px-4 py-3 text-sm text-gray-600">{Map.get(result, :carriers, "")}</td>
                  <td class="px-4 py-3 text-sm text-gray-600">{result.available_tickets}</td>
                  <td class="px-4 py-3 text-sm text-gray-600">{result.points}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <%!-- File Output Info --%>
        <div class="bg-gray-50 rounded-lg p-4 text-sm text-gray-600">
          <p><strong>Output files:</strong></p>
          <ul class="list-disc list-inside mt-1">
            <li>results.csv - All found flights</li>
            <li>failed_requests.csv - Failed requests for replay</li>
            <li>request_history.csv - Successful requests (for skip feature)</li>
          </ul>
        </div>
      </div>
    </div>
    """
  end
end
