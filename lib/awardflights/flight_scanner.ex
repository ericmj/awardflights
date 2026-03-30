defmodule Awardflights.FlightScanner do
  @moduledoc """
  GenServer that manages scanning for award flights.
  Coordinates API calls with configurable parallelism and broadcasts progress via PubSub.
  """
  use GenServer
  require Logger

  alias Awardflights.{SasAwardApi, SasOffersApi, CsvWriter, RequestTracker, RateLimitTracker}

  @pubsub Awardflights.PubSub
  @topic "scanner"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a new scan with the given configuration.

  Config keys:
  - :origins - list of origin airport codes
  - :destinations - list of destination airport codes
  - :start_date - start date (Date or string "YYYY-MM-DD")
  - :end_date - end date (Date or string "YYYY-MM-DD")
  - :award_credentials - list of %{name: string, value: string} for Partner API
  - :offers_credentials - list of %{name: string, cookies: string, auth_token: string} for SAS Direct
  - :max_concurrency - max parallel requests (default 1)
  - :skip_days - skip requests already done within N days (0 = don't skip)
  """
  def start_scan(config) do
    GenServer.call(__MODULE__, {:start_scan, config})
  end

  @doc """
  Stop the current scan.
  """
  def stop_scan do
    GenServer.call(__MODULE__, :stop_scan)
  end

  @doc """
  Get the current scanner status.
  """
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Subscribe to scanner updates.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, initial_state()}
  end

  @impl true
  def handle_call({:start_scan, config}, _from, state) do
    if state.scanning do
      {:reply, {:error, :already_scanning}, state}
    else
      new_state = setup_scan(config)
      send(self(), :spawn_workers)
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:stop_scan, _from, state) do
    # Clear queues and mark as not scanning
    # In-flight tasks will complete but their results will be ignored
    # (handled by the scanning: false check in handle_info)
    new_state = %{state | scanning: false, award_queue: [], offers_queue: []}
    broadcast(:scan_stopped, %{})
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    # Compute paused_until based on whether all credentials are rate limited
    award_paused_until = compute_api_paused_until(state.award_credentials)
    offers_paused_until = compute_api_paused_until(state.offers_credentials)
    paused_until = compute_paused_until(award_paused_until, offers_paused_until)

    status = %{
      scanning: state.scanning,
      paused_until: paused_until,
      award_paused_until: award_paused_until,
      offers_paused_until: offers_paused_until,
      award_current: state.award_current,
      offers_current: state.offers_current,
      completed: state.completed,
      total: state.total,
      results_count: state.results_count,
      award_results_count: state.award_results_count,
      offers_results_count: state.offers_results_count,
      errors_count: state.errors_count,
      skipped_count: state.skipped_count,
      award_in_flight: state.award_in_flight,
      offers_in_flight: state.offers_in_flight,
      # Credential info for UI
      award_credentials:
        Enum.map(
          state.award_credentials,
          &%{
            name: &1.name,
            rate_limited_until: &1.rate_limited_until,
            expired: Map.get(&1, :expired, false)
          }
        ),
      award_active_index: state.award_active_index,
      offers_credentials:
        Enum.map(
          state.offers_credentials,
          &%{
            name: &1.name,
            rate_limited_until: &1.rate_limited_until,
            expired: Map.get(&1, :expired, false)
          }
        ),
      offers_active_index: state.offers_active_index
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:spawn_workers, %{scanning: false} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:spawn_workers, state) do
    do_spawn_workers(state)
  end

  @impl true
  def handle_info({:spawn_award_workers}, state) do
    if state.scanning do
      do_spawn_award_workers(state)
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:spawn_offers_workers}, state) do
    if state.scanning do
      do_spawn_offers_workers(state)
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:scan_result, source, _origin, _destination, _date, _credential_index, _result},
        %{scanning: false} = state
      ) do
    # Scan was stopped, ignore result
    new_state = decrement_in_flight(state, source)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(
        {:scan_result, source, origin, destination, date, credential_index, result},
        state
      ) do
    new_state = decrement_in_flight(state, source)

    case result do
      {:ok, flights} ->
        # Add source to each flight
        flights_with_source = Enum.map(flights, fn f -> Map.put(f, :source, source) end)
        RequestTracker.record_success(source, origin, destination, date)
        CsvWriter.write_results(flights_with_source)

        broadcast(:flights_found, %{
          flights: flights_with_source,
          count: length(flights_with_source),
          source: source
        })

        new_state = update_results_count(new_state, source, length(flights_with_source))
        new_state = %{new_state | completed: new_state.completed + 1}
        broadcast_progress(new_state)

        # Spawn more workers for THIS API only
        send(self(), spawn_message_for(source))
        maybe_finish_scan(new_state)

      {:error, {:rate_limited, remaining_seconds}} ->
        # Handle per-credential rate limiting with rotation
        handle_credential_rate_limit(
          new_state,
          source,
          origin,
          destination,
          date,
          credential_index,
          remaining_seconds
        )

      {:error, :auth_expired} ->
        # Handle auth expiration by marking credential as expired and rotating
        handle_credential_auth_expired(
          new_state,
          source,
          origin,
          destination,
          date,
          credential_index
        )

      {:error, reason} ->
        log_error(source, origin, destination, date, reason)
        CsvWriter.write_failed(source, origin, destination, date, reason)

        broadcast(:scan_error, %{
          source: source,
          origin: origin,
          destination: destination,
          date: date,
          error: reason
        })

        new_state = %{new_state | errors_count: new_state.errors_count + 1}
        new_state = %{new_state | completed: new_state.completed + 1}
        broadcast_progress(new_state)

        # Spawn more workers for THIS API only
        send(self(), spawn_message_for(source))
        maybe_finish_scan(new_state)
    end
  end

  @impl true
  def handle_info({:resume_from_rate_limit, :award, credential_index}, state) do
    credential_name = Enum.at(state.award_credentials, credential_index).name

    Logger.info(
      "Resuming award API credential '#{credential_name}' (#{credential_index}) after rate limit"
    )

    # Clear the rate limit for this specific credential
    updated_credentials =
      List.update_at(state.award_credentials, credential_index, fn cred ->
        %{cred | rate_limited_until: nil}
      end)

    # Clear from persisted CSV
    RateLimitTracker.clear_rate_limit(:award, credential_name)

    new_state = %{state | award_credentials: updated_credentials}
    broadcast(:rate_limit_cleared, %{source: :award, credential_index: credential_index})

    # Resume spawning workers for award API only
    send(self(), {:spawn_award_workers})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:resume_from_rate_limit, :offers, credential_index}, state) do
    credential_name = Enum.at(state.offers_credentials, credential_index).name

    Logger.info(
      "Resuming offers API credential '#{credential_name}' (#{credential_index}) after rate limit"
    )

    # Clear the rate limit for this specific credential
    updated_credentials =
      List.update_at(state.offers_credentials, credential_index, fn cred ->
        %{cred | rate_limited_until: nil}
      end)

    # Clear from persisted CSV
    RateLimitTracker.clear_rate_limit(:offers, credential_name)

    new_state = %{state | offers_credentials: updated_credentials}
    broadcast(:rate_limit_cleared, %{source: :offers, credential_index: credential_index})

    # Resume spawning workers for offers API only
    send(self(), {:spawn_offers_workers})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:skipped, source, origin, destination, date}, state) do
    new_state = decrement_in_flight(state, source)

    new_state = %{
      new_state
      | skipped_count: new_state.skipped_count + 1,
        completed: new_state.completed + 1
    }

    broadcast(:request_skipped, %{
      source: source,
      origin: origin,
      destination: destination,
      date: date
    })

    broadcast_progress(new_state)

    # Spawn more workers for THIS API only
    send(self(), spawn_message_for(source))

    maybe_finish_scan(new_state)
  end

  # Private functions

  # Initial spawn - kicks off both APIs
  defp do_spawn_workers(state) do
    state
    |> do_spawn_award_workers_inner()
    |> do_spawn_offers_workers_inner()
    |> maybe_finish_scan()
  end

  # Spawn workers for award API only
  defp do_spawn_award_workers(state) do
    state
    |> do_spawn_award_workers_inner()
    |> maybe_finish_scan()
  end

  # Spawn workers for offers API only
  defp do_spawn_offers_workers(state) do
    state
    |> do_spawn_offers_workers_inner()
    |> maybe_finish_scan()
  end

  defp do_spawn_award_workers_inner(state) do
    # Find an available credential
    case find_available_credential(state.award_credentials, state.award_active_index) do
      {:all_unavailable, _earliest} ->
        # All credentials are unavailable (rate limited or expired), skip spawning
        state

      {:ok, credential, index} ->
        # Update state with any credential changes (cleared rate limits) and active index
        updated_credentials = List.replace_at(state.award_credentials, index, credential)
        state = %{state | award_credentials: updated_credentials, award_active_index: index}

        available_slots = state.max_concurrency - state.award_in_flight
        {to_process, remaining_queue} = Enum.split(state.award_queue, available_slots)

        new_state = %{state | award_queue: remaining_queue}

        Enum.reduce(to_process, new_state, fn {origin, destination, date}, acc ->
          spawn_award_task(self(), origin, destination, date, acc, acc.skip_days)
        end)
    end
  end

  defp do_spawn_offers_workers_inner(state) do
    # Find an available credential
    case find_available_credential(state.offers_credentials, state.offers_active_index) do
      {:all_unavailable, _earliest} ->
        # All credentials are unavailable (rate limited or expired), skip spawning
        state

      {:ok, credential, index} ->
        # Update state with any credential changes (cleared rate limits) and active index
        updated_credentials = List.replace_at(state.offers_credentials, index, credential)
        state = %{state | offers_credentials: updated_credentials, offers_active_index: index}

        available_slots = state.max_concurrency - state.offers_in_flight
        {to_process, remaining_queue} = Enum.split(state.offers_queue, available_slots)

        new_state = %{state | offers_queue: remaining_queue}

        Enum.reduce(to_process, new_state, fn {origin, destination, date}, acc ->
          spawn_offers_task(self(), origin, destination, date, acc, acc.skip_days)
        end)
    end
  end

  defp maybe_finish_scan(state) do
    # Check if we're done (no more queues and no in-flight for either API)
    all_done =
      state.award_queue == [] and state.offers_queue == [] and
        state.award_in_flight == 0 and state.offers_in_flight == 0

    if all_done do
      finish_scan(state)
    else
      {:noreply, state}
    end
  end

  defp decrement_in_flight(state, :award) do
    %{state | award_in_flight: max(0, state.award_in_flight - 1)}
  end

  defp decrement_in_flight(state, :offers) do
    %{state | offers_in_flight: max(0, state.offers_in_flight - 1)}
  end

  defp spawn_message_for(:award), do: {:spawn_award_workers}
  defp spawn_message_for(:offers), do: {:spawn_offers_workers}

  defp requeue_for_api(state, :award, origin, destination, date) do
    %{state | award_queue: [{origin, destination, date} | state.award_queue]}
  end

  defp requeue_for_api(state, :offers, origin, destination, date) do
    %{state | offers_queue: [{origin, destination, date} | state.offers_queue]}
  end

  defp update_results_count(state, :award, count) do
    %{
      state
      | results_count: state.results_count + count,
        award_results_count: state.award_results_count + count
    }
  end

  defp update_results_count(state, :offers, count) do
    %{
      state
      | results_count: state.results_count + count,
        offers_results_count: state.offers_results_count + count
    }
  end

  defp compute_paused_until(nil, nil), do: nil
  defp compute_paused_until(award, nil), do: award
  defp compute_paused_until(nil, offers), do: offers
  defp compute_paused_until(award, offers), do: Enum.min([award, offers], DateTime)

  # Compute if an API is paused based on all credentials being rate limited
  defp compute_api_paused_until([]), do: nil

  defp compute_api_paused_until(credentials) do
    now = DateTime.utc_now()

    # Find credentials that are still rate limited (not expired)
    active_limits =
      credentials
      |> Enum.map(& &1.rate_limited_until)
      |> Enum.filter(fn
        nil -> false
        until_time -> DateTime.compare(now, until_time) == :lt
      end)

    # If all credentials are rate limited, return the earliest expiry
    if length(active_limits) == length(credentials) do
      Enum.min(active_limits, DateTime)
    else
      nil
    end
  end

  # Find next available credential, starting from given index
  # Returns {:ok, credential, index} or {:all_unavailable, earliest_resume_at}
  # A credential is unavailable if it's expired or rate limited
  defp find_available_credential([], _start_index), do: {:all_unavailable, nil}

  defp find_available_credential(credentials, start_index) do
    now = DateTime.utc_now()
    len = length(credentials)

    result =
      Enum.reduce_while(0..(len - 1), :all_unavailable, fn offset, _acc ->
        index = rem(start_index + offset, len)
        credential = Enum.at(credentials, index)

        cond do
          # Skip expired credentials
          Map.get(credential, :expired, false) ->
            {:cont, :all_unavailable}

          # Available if not rate limited
          credential.rate_limited_until == nil ->
            {:halt, {:ok, credential, index}}

          # Check if rate limit has expired
          DateTime.compare(now, credential.rate_limited_until) == :gt ->
            {:halt, {:ok, %{credential | rate_limited_until: nil}, index}}

          # Still rate limited
          true ->
            {:cont, :all_unavailable}
        end
      end)

    case result do
      {:ok, cred, idx} ->
        {:ok, cred, idx}

      :all_unavailable ->
        # Find earliest resume time (only from non-expired credentials)
        earliest =
          credentials
          |> Enum.reject(&Map.get(&1, :expired, false))
          |> Enum.map(& &1.rate_limited_until)
          |> Enum.filter(&(&1 != nil))
          |> Enum.min(DateTime, fn -> nil end)

        {:all_unavailable, earliest}
    end
  end

  # Mark a credential as rate limited and update the active index
  defp mark_credential_rate_limited(credentials, index, resume_at) do
    List.update_at(credentials, index, fn cred ->
      %{cred | rate_limited_until: resume_at}
    end)
  end

  defp initial_state do
    %{
      scanning: false,
      origins: [],
      destinations: [],
      dates: [],
      # Credential lists with per-credential rate limiting
      award_credentials: [],
      award_active_index: 0,
      offers_credentials: [],
      offers_active_index: 0,
      max_concurrency: 1,
      skip_days: 0,
      # Separate queues per API
      award_queue: [],
      offers_queue: [],
      award_in_flight: 0,
      offers_in_flight: 0,
      # Separate current scan tracking per API
      award_current: nil,
      offers_current: nil,
      completed: 0,
      total: 0,
      results_count: 0,
      award_results_count: 0,
      offers_results_count: 0,
      errors_count: 0,
      skipped_count: 0
    }
  end

  defp setup_scan(config) do
    origins = config[:origins] || []
    destinations = config[:destinations] || []
    dates = build_date_range(config[:start_date], config[:end_date])

    route_dates = build_queue(origins, destinations, dates)

    # Load persisted rate limits
    persisted_statuses = RateLimitTracker.get_all_statuses()

    # Initialize credentials with rate_limited_until and expired fields from persisted state
    # If credential value has changed since expiration, clear the expiration
    award_credentials =
      (config[:award_credentials] || [])
      |> Enum.map(fn cred ->
        persisted = Enum.find(persisted_statuses.award, &(&1.name == cred.name))
        # Check if credential value changed - if so, clear the persisted expiration
        value_changed = RateLimitTracker.credential_value_changed?(:award, cred.name, cred.value)

        if value_changed do
          Logger.info("Award credential '#{cred.name}' value changed, clearing expired status")
          RateLimitTracker.clear_rate_limit(:award, cred.name)
        end

        Map.merge(cred, %{
          rate_limited_until:
            if(value_changed, do: nil, else: persisted && persisted.rate_limited_until),
          expired: if(value_changed, do: false, else: (persisted && persisted.expired) || false)
        })
      end)

    offers_credentials =
      (config[:offers_credentials] || [])
      |> Enum.map(fn cred ->
        persisted = Enum.find(persisted_statuses.offers, &(&1.name == cred.name))
        # For offers, use cookies as the credential value to track changes
        value_changed =
          RateLimitTracker.credential_value_changed?(:offers, cred.name, cred.cookies)

        if value_changed do
          Logger.info("Offers credential '#{cred.name}' value changed, clearing expired status")
          RateLimitTracker.clear_rate_limit(:offers, cred.name)
        end

        Map.merge(cred, %{
          rate_limited_until:
            if(value_changed, do: nil, else: persisted && persisted.rate_limited_until),
          expired: if(value_changed, do: false, else: (persisted && persisted.expired) || false)
        })
      end)

    # APIs are enabled if they have at least one credential
    award_enabled = length(award_credentials) > 0
    offers_enabled = length(offers_credentials) > 0

    # Each API gets its own queue
    award_queue = if award_enabled, do: route_dates, else: []
    offers_queue = if offers_enabled, do: route_dates, else: []
    total = length(award_queue) + length(offers_queue)

    %{
      scanning: true,
      origins: origins,
      destinations: destinations,
      dates: dates,
      award_credentials: award_credentials,
      award_active_index: 0,
      offers_credentials: offers_credentials,
      offers_active_index: 0,
      max_concurrency: config[:max_concurrency] || 1,
      skip_days: config[:skip_days] || 0,
      award_queue: award_queue,
      offers_queue: offers_queue,
      award_in_flight: 0,
      offers_in_flight: 0,
      award_current: nil,
      offers_current: nil,
      completed: 0,
      total: total,
      results_count: 0,
      award_results_count: 0,
      offers_results_count: 0,
      errors_count: 0,
      skipped_count: 0
    }
  end

  defp build_date_range(start_date, end_date) do
    start_date = parse_date(start_date)
    end_date = parse_date(end_date)

    Date.range(start_date, end_date)
    |> Enum.map(&Date.to_string/1)
  end

  defp parse_date(%Date{} = date), do: date

  defp parse_date(date_string) when is_binary(date_string) do
    Date.from_iso8601!(date_string)
  end

  defp build_queue(origins, destinations, dates) do
    for origin <- origins,
        destination <- destinations,
        date <- dates,
        origin != destination do
      {origin, destination, date}
    end
  end

  defp spawn_award_task(scanner, origin, destination, date, state, skip_days) do
    credential_index = state.award_active_index
    credential = Enum.at(state.award_credentials, credential_index)
    auth_token = credential.value

    Task.Supervisor.start_child(Awardflights.TaskSupervisor, fn ->
      if RequestTracker.should_skip?(:award, origin, destination, date, skip_days) do
        send(scanner, {:skipped, :award, origin, destination, date})
      else
        result = SasAwardApi.search_flights(origin, destination, date, auth_token)
        send(scanner, {:scan_result, :award, origin, destination, date, credential_index, result})
      end
    end)

    %{
      state
      | award_in_flight: state.award_in_flight + 1,
        award_current: {origin, destination, date}
    }
  end

  defp spawn_offers_task(scanner, origin, destination, date, state, skip_days) do
    credential_index = state.offers_active_index
    credential = Enum.at(state.offers_credentials, credential_index)
    cookies = credential.cookies
    auth_token = credential.auth_token

    Task.Supervisor.start_child(Awardflights.TaskSupervisor, fn ->
      if RequestTracker.should_skip?(:offers, origin, destination, date, skip_days) do
        send(scanner, {:skipped, :offers, origin, destination, date})
      else
        result = SasOffersApi.search_flights(origin, destination, date, cookies, auth_token)

        send(
          scanner,
          {:scan_result, :offers, origin, destination, date, credential_index, result}
        )
      end
    end)

    %{
      state
      | offers_in_flight: state.offers_in_flight + 1,
        offers_current: {origin, destination, date}
    }
  end

  defp handle_credential_rate_limit(
         state,
         source,
         origin,
         destination,
         date,
         credential_index,
         remaining_seconds
       ) do
    # Add a small buffer to the wait time
    wait_seconds = remaining_seconds + 5
    resume_at = DateTime.add(DateTime.utc_now(), wait_seconds, :second)

    # Mark this specific credential as rate limited
    {credentials_key, active_index_key} =
      case source do
        :award -> {:award_credentials, :award_active_index}
        :offers -> {:offers_credentials, :offers_active_index}
      end

    credentials = Map.get(state, credentials_key)
    updated_credentials = mark_credential_rate_limited(credentials, credential_index, resume_at)
    state = Map.put(state, credentials_key, updated_credentials)

    credential_name = Enum.at(credentials, credential_index).name

    # Persist to CSV via RateLimitTracker
    RateLimitTracker.set_rate_limit(source, credential_name, wait_seconds)

    Logger.warning(
      "#{source} API credential '#{credential_name}' (#{credential_index}) rate limited until #{resume_at}"
    )

    # Schedule resume for this specific credential
    wait_ms = (remaining_seconds + 5) * 1000
    Process.send_after(self(), {:resume_from_rate_limit, source, credential_index}, wait_ms)

    # Try to find next available credential
    next_index = rem(credential_index + 1, length(updated_credentials))

    case find_available_credential(updated_credentials, next_index) do
      {:ok, _credential, new_index} ->
        # Found another credential to use - rotate to it and continue
        state = Map.put(state, active_index_key, new_index)
        new_credential_name = Enum.at(updated_credentials, new_index).name

        Logger.info(
          "Rotating #{source} API to credential '#{new_credential_name}' (#{new_index})"
        )

        # Re-queue the failed request
        state = requeue_for_api(state, source, origin, destination, date)

        broadcast(:credential_rotated, %{
          source: source,
          from_index: credential_index,
          to_index: new_index,
          from_name: credential_name,
          to_name: new_credential_name,
          from_rate_limited_until: resume_at
        })

        # Continue spawning with new credential
        send(self(), spawn_message_for(source))
        maybe_finish_scan(state)

      {:all_unavailable, earliest_resume} ->
        # All credentials are unavailable (rate limited or expired) - pause the API
        Logger.warning(
          "All #{source} API credentials unavailable. Pausing until #{earliest_resume || "manual intervention"}"
        )

        # Re-queue the failed request
        state = requeue_for_api(state, source, origin, destination, date)

        broadcast(:rate_limited, %{
          source: source,
          credential_index: credential_index,
          remaining_seconds: remaining_seconds + 5,
          resume_at: earliest_resume
        })

        # Note: We already scheduled resume for the credential that just got rate limited.
        # When it resumes, it will trigger spawn_workers again.
        # If all credentials are expired (earliest_resume is nil), the scan will stall.
        {:noreply, state}
    end
  end

  defp handle_credential_auth_expired(state, source, origin, destination, date, credential_index) do
    # Mark this specific credential as expired (permanently until restart)
    {credentials_key, active_index_key} =
      case source do
        :award -> {:award_credentials, :award_active_index}
        :offers -> {:offers_credentials, :offers_active_index}
      end

    credentials = Map.get(state, credentials_key)
    credential = Enum.at(credentials, credential_index)
    credential_name = credential.name
    # Get the credential value for hash tracking (value for award, cookies for offers)
    credential_value =
      case source do
        :award -> credential.value
        :offers -> credential.cookies
      end

    updated_credentials = mark_credential_expired(credentials, credential_index)
    state = Map.put(state, credentials_key, updated_credentials)

    # Persist expiration to CSV via RateLimitTracker (with value hash for change detection)
    RateLimitTracker.set_expired(source, credential_name, credential_value)

    Logger.warning(
      "#{source} API credential '#{credential_name}' (#{credential_index}) authentication expired"
    )

    # Broadcast the credential expiration event
    broadcast(:credential_expired, %{
      source: source,
      credential_index: credential_index,
      credential_name: credential_name
    })

    # Try to find next available credential
    next_index = rem(credential_index + 1, length(updated_credentials))

    case find_available_credential(updated_credentials, next_index) do
      {:ok, _credential, new_index} ->
        # Found another credential to use - rotate to it and continue
        state = Map.put(state, active_index_key, new_index)
        new_credential_name = Enum.at(updated_credentials, new_index).name

        Logger.info(
          "Rotating #{source} API to credential '#{new_credential_name}' (#{new_index}) after auth expiration"
        )

        # Re-queue the failed request to retry with the new credential
        state = requeue_for_api(state, source, origin, destination, date)

        broadcast(:credential_rotated, %{
          source: source,
          from_index: credential_index,
          to_index: new_index,
          from_name: credential_name,
          to_name: new_credential_name,
          from_expired: true
        })

        # Continue spawning with new credential
        send(self(), spawn_message_for(source))
        maybe_finish_scan(state)

      {:all_unavailable, _earliest_resume} ->
        # All credentials are unavailable (expired or rate limited) - log scan error
        Logger.warning("All #{source} API credentials are unavailable after auth expiration")

        # Log this specific error since we can't retry
        log_error(source, origin, destination, date, :auth_expired)
        CsvWriter.write_failed(source, origin, destination, date, :auth_expired)

        broadcast(:scan_error, %{
          source: source,
          origin: origin,
          destination: destination,
          date: date,
          error: :auth_expired
        })

        new_state = %{
          state
          | errors_count: state.errors_count + 1,
            completed: state.completed + 1
        }

        broadcast_progress(new_state)

        # Don't try to spawn more workers since all credentials are unavailable
        maybe_finish_scan(new_state)
    end
  end

  defp mark_credential_expired(credentials, index) do
    List.update_at(credentials, index, fn cred ->
      %{cred | expired: true}
    end)
  end

  defp finish_scan(state) do
    new_state = %{state | scanning: false}

    broadcast(:scan_complete, %{
      results_count: state.results_count,
      award_results_count: state.award_results_count,
      offers_results_count: state.offers_results_count,
      errors_count: state.errors_count,
      skipped_count: state.skipped_count
    })

    {:noreply, new_state}
  end

  defp broadcast_progress(state) do
    broadcast(:progress, %{
      award_current: state.award_current,
      offers_current: state.offers_current,
      completed: state.completed,
      total: state.total,
      results_count: state.results_count,
      award_results_count: state.award_results_count,
      offers_results_count: state.offers_results_count,
      errors_count: state.errors_count,
      skipped_count: state.skipped_count
    })
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {event, payload})
  end

  defp log_error(source, origin, destination, date, {:http_error, status, body}) do
    Logger.warning("""
    [#{source}] Scan failed: #{origin} -> #{destination} on #{date}
    Status: #{status}
    Body: #{inspect(body)}
    """)
  end

  defp log_error(source, origin, destination, date, reason) do
    Logger.warning(
      "[#{source}] Scan failed: #{origin} -> #{destination} on #{date}: #{inspect(reason)}"
    )
  end
end
