defmodule Awardflights.SasOffersApi do
  @moduledoc """
  Client for the SAS /api/offers/flights endpoint using Docker + curl-impersonate
  to bypass Cloudflare TLS fingerprinting.
  """

  @base_url "https://www.sas.se/api/offers/flights"

  @doc """
  Search for award flights between origin and destination on a specific date.

  Uses Docker with curl-impersonate to make requests that bypass Cloudflare.

  ## Parameters
  - origin: Airport code (e.g., "GOT")
  - destination: Airport code (e.g., "CDG")
  - date: Date string in YYYY-MM-DD format (converted to YYYYMMDD internally)
  - cookies: Full cookie string from browser
  - auth_token: LOGIN_AUTH JWT value (optional - will be extracted from cookies if not provided)

  ## Returns
  - `{:ok, flights}` on success
  - `{:error, reason}` on failure
  """
  @spec search_flights(String.t(), String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, list(map())} | {:error, term()}
  def search_flights(origin, destination, date, cookies, auth_token \\ nil) do
    # Extract LOGIN_AUTH from cookies if auth_token not provided
    auth_token = auth_token || extract_cookie_value(cookies, "LOGIN_AUTH") || ""
    customer_session_id = extract_customer_session_id(auth_token)
    url = build_url(origin, destination, date, customer_session_id)

    args = build_docker_args(url, cookies)

    case execute_docker(args) do
      {output, 0} ->
        parse_response(output, origin, destination, date)

      {_output, 28} ->
        # curl timeout exit code
        {:error, :timeout}

      {output, 22} ->
        # HTTP error (curl --fail returns 22 for HTTP errors)
        handle_http_error(output)

      {output, exit_code} ->
        {:error, {:curl_failed, exit_code, output}}
    end
  end

  defp build_url(origin, destination, date, _customer_session_id) do
    # Convert YYYY-MM-DD to YYYYMMDD
    out_date = String.replace(date, "-", "")

    # Use exact parameters that the SAS website uses
    query =
      URI.encode_query(%{
        "from" => origin,
        "to" => destination,
        "outDate" => out_date,
        "adt" => "1",
        "chd" => "0",
        "inf" => "0",
        "yth" => "0",
        "bookingFlow" => "points",
        "pos" => "se",
        "channel" => "web",
        "displayType" => "upsell"
      })

    "#{@base_url}?#{query}"
  end

  defp build_docker_args(url, cookies) do
    # Sanitize cookies to remove newlines/carriage returns from browser copy-paste
    clean_cookies = sanitize_cookie(cookies)

    [
      "run",
      "--rm",
      "lwthiker/curl-impersonate:0.6-chrome",
      "curl_chrome110",
      "-s",
      "--max-time",
      "30",
      "-H",
      "accept: application/json, text/plain, */*",
      "-H",
      "accept-language: sv-SE,sv;q=0.9,en-US;q=0.8,en;q=0.7",
      "-H",
      "origin: https://www.sas.se",
      "-H",
      "referer: https://www.sas.se/book/flights",
      "-H",
      "sec-fetch-dest: empty",
      "-H",
      "sec-fetch-mode: cors",
      "-H",
      "sec-fetch-site: same-origin",
      "-H",
      "cookie: #{clean_cookies}",
      url
    ]
  end

  # Remove newlines, carriage returns, and trim whitespace from cookie strings
  defp sanitize_cookie(cookie) when is_binary(cookie) do
    cookie
    |> String.replace(~r/[\r\n]+/, "")
    |> String.trim()
  end

  defp sanitize_cookie(cookie), do: cookie

  defp execute_docker(args) do
    case Application.get_env(:awardflights, :sas_offers_executor) do
      nil -> System.cmd("docker", args, stderr_to_stdout: true)
      executor -> executor.(args)
    end
  end

  defp handle_http_error(output) do
    # Strip Docker platform warnings (appears before JSON/XML on ARM Macs)
    stripped_output = strip_to_content(output)

    # Check if response is XML (SAS returns XML errors sometimes)
    if String.starts_with?(stripped_output, "<") do
      # XML error response - check for specific error patterns
      cond do
        String.contains?(String.downcase(stripped_output), "cloudflare") ->
          {:error, :cloudflare_blocked}

        true ->
          # Generic XML error - treat as server error
          {:error, {:http_error, :xml_error, stripped_output}}
      end
    else
      case Jason.decode(stripped_output) do
        {:ok, %{"statusCode" => 401}} ->
          {:error, :auth_expired}

        {:ok, %{"statusCode" => 429} = body} ->
          remaining_time = get_in(body, ["payload", "remainingTime"]) || 60
          {:error, {:rate_limited, remaining_time}}

        {:ok, %{"statusCode" => status}} ->
          {:error, {:http_error, status, output}}

        {:error, _} ->
          # Check if it's a Cloudflare block (HTML response)
          if String.contains?(String.downcase(output), "cloudflare") do
            {:error, :cloudflare_blocked}
          else
            {:error, {:json_parse_error, output}}
          end
      end
    end
  end

  defp parse_response(output, origin, destination, date) do
    # Strip Docker platform warnings (appears before JSON/XML on ARM Macs)
    stripped_output = strip_to_content(output)

    # Check if response is XML (SAS returns XML errors sometimes)
    if String.starts_with?(stripped_output, "<") do
      # XML error response - treat as no availability
      {:ok, []}
    else
      case Jason.decode(stripped_output) do
        {:ok, %{"errors" => _errors}} ->
          # SAS returns errors array when no availability - treat as empty results
          {:ok, []}

        {:ok, body} ->
          flights = parse_flights(body, origin, destination, date)
          {:ok, flights}

        {:error, _} ->
          # Check if it's a Cloudflare block
          if String.contains?(String.downcase(output), "cloudflare") do
            {:error, :cloudflare_blocked}
          else
            {:error, {:json_parse_error, output}}
          end
      end
    end
  end

  defp strip_to_content(output) do
    # Find the first { (JSON) or < (XML) character, whichever comes first
    json_pos =
      case :binary.match(output, "{") do
        {pos, _} -> pos
        :nomatch -> byte_size(output)
      end

    xml_pos =
      case :binary.match(output, "<") do
        {pos, _} -> pos
        :nomatch -> byte_size(output)
      end

    start_pos = min(json_pos, xml_pos)

    if start_pos < byte_size(output) do
      binary_part(output, start_pos, byte_size(output) - start_pos)
    else
      output
    end
  end

  defp parse_flights(body, origin, destination, date) do
    outbound_flights = get_in(body, ["outboundFlights"]) || %{}

    outbound_flights
    |> Map.values()
    |> Enum.flat_map(&parse_flight(&1, origin, destination, date))
  end

  defp parse_flight(flight, origin, destination, date) do
    departure = get_in(flight, ["origin", "code"]) || origin
    arrival = get_in(flight, ["destination", "code"]) || destination
    cabins = get_in(flight, ["cabins"]) || %{}
    carriers = extract_carriers(flight)

    cabins
    |> Enum.flat_map(fn {cabin_name, cabin_types} ->
      parse_cabin_types(cabin_types, cabin_name, departure, arrival, date, carriers)
    end)
  end

  defp parse_cabin_types(cabin_types, cabin_name, departure, arrival, date, carriers)
       when is_map(cabin_types) do
    cabin_types
    |> Enum.flat_map(fn {_type_name, type_data} ->
      parse_products(type_data, cabin_name, departure, arrival, date, carriers)
    end)
  end

  defp parse_cabin_types(_, _, _, _, _, _), do: []

  defp parse_products(%{"products" => products}, cabin_name, departure, arrival, date, carriers)
       when is_map(products) do
    products
    |> Map.values()
    |> Enum.flat_map(&parse_product(&1, cabin_name, departure, arrival, date, carriers))
  end

  defp parse_products(_, _, _, _, _, _), do: []

  defp parse_product(product, cabin_name, departure, arrival, date, carriers) do
    points = get_in(product, ["price", "points"]) || 0
    base_price = get_in(product, ["price", "basePrice"]) || 0
    fares = get_in(product, ["fares"]) || []

    fares
    |> Enum.flat_map(fn fare ->
      booking_class = get_in(fare, ["bookingClass"])
      available_seats = get_in(fare, ["avlSeats"]) || 0

      # Only include points-only awards (basePrice == 0) to filter out mixed cash+points pricing
      # Points-only awards have basePrice of 0 (only taxes), while mixed pricing has positive basePrice
      if available_seats > 0 and points > 0 and base_price == 0 do
        [
          %{
            source: :offers,
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
    end)
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

  defp extract_cookie_value(cookie_string, name) when is_binary(cookie_string) do
    cookie_string
    |> String.split("; ")
    |> Enum.find_value(fn cookie ->
      case String.split(cookie, "=", parts: 2) do
        [^name, value] -> value
        _ -> nil
      end
    end)
  end

  defp extract_cookie_value(_, _), do: nil

  defp extract_customer_session_id(auth_token) when is_binary(auth_token) do
    case String.split(auth_token, ".") do
      [_header, payload, _signature] ->
        case Base.url_decode64(payload, padding: false) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, %{"customerSessionId" => id}} -> id
              _ -> ""
            end

          _ ->
            ""
        end

      _ ->
        ""
    end
  rescue
    _ -> ""
  end

  defp extract_customer_session_id(_), do: ""
end
