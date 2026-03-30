defmodule Awardflights.SasAwardApi do
  @moduledoc """
  Client for the SAS award-api to search for bonus point flights.
  """
  require Logger

  @base_url "https://www.sas.se/award-api/flights"

  @default_headers [
    {"channel", "WEB"},
    {"language", "sv"},
    {"locale", "sv-se"},
    {"pos", "SE"},
    {"accept", "application/json"},
    {"user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"}
  ]

  @doc """
  Search for award flights between origin and destination on a specific date.

  Accepts either a Bearer token (JWT) or cookies for authentication.
  When using cookies, pass the session_id separately (from sas-user-session-id header).

  Returns `{:ok, flights}` or `{:error, reason}`.
  """
  def search_flights(origin, destination, date, credential, session_id \\ nil) do
    headers = build_headers(credential, session_id)

    query_params = [
      origin: origin,
      destination: destination,
      outboundDate: date,
      tripType: "one-way",
      selectedCouponCodes: "",
      adults: 1,
      children: 0,
      infants: 0,
      youths: 0
    ]

    opts = [headers: headers, params: query_params] ++ req_options()

    try do
      case Req.get(@base_url, opts) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          {:ok, parse_response(body, origin, destination, date)}

        {:ok, %Req.Response{status: 401}} ->
          {:error, :auth_expired}

        {:ok, %Req.Response{status: 429, body: body}} ->
          Logger.warning("429 Response Body: #{inspect(body, pretty: true)}")
          remaining_time = get_in(body, ["payload", "remainingTime"]) || 60
          {:error, {:rate_limited, remaining_time}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, exception} ->
          {:error, {:request_failed, exception}}
      end
    rescue
      e in RuntimeError ->
        # Handle Finch connection pool exhaustion
        if String.contains?(e.message, "excess queuing") do
          {:error, :connection_pool_exhausted}
        else
          {:error, {:request_failed, e}}
        end
    end
  end

  defp parse_response(body, origin, destination, date) do
    outbound_flights = get_in(body, ["outboundFlights"]) || []

    Enum.flat_map(outbound_flights, fn flight ->
      parse_flight(flight, origin, destination, date)
    end)
  end

  defp parse_flight(flight, origin, destination, date) do
    cabins = get_in(flight, ["cabins"]) || []
    departure = get_in(flight, ["origin", "code"]) || origin
    arrival = get_in(flight, ["destination", "code"]) || destination
    carriers = extract_carriers(flight)

    Enum.flat_map(cabins, fn cabin ->
      parse_cabin(cabin, departure, arrival, date, carriers)
    end)
  end

  defp parse_cabin(cabin, departure, arrival, date, carriers) do
    # Check for Format 2 fields (session cookie auth)
    points_v2 = get_in(cabin, ["price", "points"])

    if points_v2 do
      # Format 2: points at cabin level
      parse_cabin_format2(cabin, departure, arrival, date, carriers)
    else
      # Format 1: points at fare level
      parse_cabin_format1(cabin, departure, arrival, date, carriers)
    end
  end

  # Format 1 (Bearer Token Auth):
  # Points are in fares[].points.base
  defp parse_cabin_format1(cabin, departure, arrival, date, carriers) do
    cabin_name = get_in(cabin, ["cabinName"]) || "unknown"
    fares = get_in(cabin, ["fares"]) || []

    Enum.flat_map(fares, fn fare ->
      parse_fare(fare, departure, arrival, date, cabin_name, carriers)
    end)
  end

  # Format 2 (Session Cookie Auth):
  # Points are in cabin.price.points, seats in cabin.availableSeats
  defp parse_cabin_format2(cabin, departure, arrival, date, carriers) do
    cabin_name = get_in(cabin, ["cabin"]) || get_in(cabin, ["productName"]) || "unknown"
    points = get_in(cabin, ["price", "points"]) || 0
    available_seats = get_in(cabin, ["availableSeats"]) || 0
    fares = get_in(cabin, ["fares"]) || []
    booking_class = get_in(fares, [Access.at(0), "bookingClass"])

    if available_seats > 0 do
      [
        %{
          departure: departure,
          arrival: arrival,
          date: date,
          booking_class: booking_class,
          cabin: format_cabin_name(cabin_name),
          available_tickets: available_seats,
          points: points,
          carriers: carriers
        }
      ]
    else
      []
    end
  end

  defp extract_carriers(flight) do
    segments = get_in(flight, ["segments"]) || []

    segments
    |> Enum.map(&get_in(&1, ["marketingCarrier", "name"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  defp format_cabin_name(name) when is_binary(name) do
    name |> String.downcase() |> String.capitalize()
  end

  defp format_cabin_name(_), do: "Unknown"

  defp parse_fare(fare, departure, arrival, date, cabin_name, carriers) do
    booking_class = get_in(fare, ["bookingClass"])
    available_seats = get_in(fare, ["avlSeats"]) || 0
    points = get_in(fare, ["points", "base"]) || get_in(fare, ["points"]) || 0

    if available_seats > 0 do
      [
        %{
          departure: departure,
          arrival: arrival,
          date: date,
          booking_class: booking_class,
          cabin: cabin_name,
          available_tickets: available_seats,
          points: points,
          carriers: carriers
        }
      ]
    else
      []
    end
  end

  defp req_options do
    # Always disable retry - we handle rate limiting ourselves in FlightScanner
    base_opts = [retry: false]

    if plug = Application.get_env(:awardflights, :sas_award_api_plug) do
      [plug: plug] ++ base_opts
    else
      base_opts
    end
  end

  # Hard-coded session ID for testing
  @hardcoded_session_id "fbff2a07-057a-4d7b-ad56-5279c28137fe"

  defp build_headers(credential, _explicit_session_id) do
    credential = credential |> sanitize_credential() |> strip_bearer_prefix()

    cond do
      is_bearer_token?(credential) ->
        [
          {"authorization", "Bearer #{credential}"},
          {"sas-user-session-id", @hardcoded_session_id}
        ] ++ @default_headers

      is_cookie_string?(credential) ->
        # Full cookie string
        # Sanitize to remove any newlines/carriage returns from browser copy-paste
        clean_cookie = sanitize_cookie(credential)

        [
          {"authorization", "Bearer"},
          {"cookie", clean_cookie},
          {"sas-user-session-id", @hardcoded_session_id}
        ] ++ @default_headers

      credential && credential != "" ->
        # Assume single __session cookie value
        clean_cookie = sanitize_cookie(credential)

        headers =
          [
            {"authorization", "Bearer"},
            {"cookie", "__session=#{clean_cookie}"},
            {"sas-user-session-id", @hardcoded_session_id}
          ] ++ @default_headers

        headers

      true ->
        @default_headers
    end
  end

  # Remove newlines, carriage returns, and trim whitespace from cookie strings
  # (browser copy-paste can introduce these invalid HTTP header characters)
  defp sanitize_cookie(cookie) when is_binary(cookie) do
    cookie
    |> String.replace(~r/[\r\n]+/, "")
    |> String.trim()
  end

  defp sanitize_cookie(cookie), do: cookie

  defp sanitize_credential(credential) when is_binary(credential) do
    credential
    |> String.replace(~r/[\r\n]+/, "")
    |> String.trim()
  end

  defp sanitize_credential(credential), do: credential

  defp strip_bearer_prefix("Bearer " <> token), do: token
  defp strip_bearer_prefix(credential), do: credential

  # Cookie string contains multiple cookies separated by "; "
  defp is_cookie_string?(credential) when is_binary(credential) do
    String.contains?(credential, "; ") and String.contains?(credential, "=")
  end

  defp is_cookie_string?(_), do: false

  # Bearer token is a JWT with exactly 3 parts and has customerSessionId in payload
  defp is_bearer_token?(credential) when is_binary(credential) do
    case String.split(credential, ".") do
      [_header, payload, _signature] ->
        case Base.url_decode64(payload, padding: false) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, %{"customerSessionId" => _}} -> true
              _ -> false
            end

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp is_bearer_token?(_), do: false
end
