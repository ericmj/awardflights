defmodule Awardflights.ScanRunner do
  @moduledoc """
  Programmatic entry point for starting scans, building the same config the
  ScannerLive form builds. Credentials are read from CredentialStore, so a
  caller only supplies routes and dates. Progress is broadcast over the
  "scanner" PubSub topic, so an open ScannerLive follows along live.
  """

  alias Awardflights.{CredentialStore, FlightScanner}

  @doc """
  Start a scan from a params map (string or atom keys).

  Keys:
    - origins / destinations: list of codes or a comma/space separated string
    - start_date / end_date: "YYYY-MM-DD"
    - max_concurrency: integer (default 2)
    - skip_days: integer (default 30)

  Returns `{:ok, summary}` or `{:error, reason}`.
  """
  def start(params) do
    config = %{
      origins: parse_airports(fetch(params, :origins)),
      destinations: parse_airports(fetch(params, :destinations)),
      start_date: fetch(params, :start_date),
      end_date: fetch(params, :end_date),
      award_credentials: award_credentials(),
      offers_credentials: offers_credentials(),
      max_concurrency: to_int(fetch(params, :max_concurrency), 2),
      skip_days: to_int(fetch(params, :skip_days), 30)
    }

    with :ok <- validate(config),
         :ok <- FlightScanner.start_scan(config) do
      {:ok, summary(config)}
    end
  end

  defp validate(config) do
    cond do
      config.origins == [] ->
        {:error, :no_origins}

      config.destinations == [] ->
        {:error, :no_destinations}

      is_nil(config.start_date) or is_nil(config.end_date) ->
        {:error, :no_dates}

      not valid_date?(config.start_date) ->
        {:error, :bad_start_date}

      not valid_date?(config.end_date) ->
        {:error, :bad_end_date}

      config.award_credentials == [] and config.offers_credentials == [] ->
        {:error, :no_credentials}

      true ->
        :ok
    end
  end

  defp summary(config) do
    %{
      origins: config.origins,
      destinations: config.destinations,
      start_date: config.start_date,
      end_date: config.end_date,
      max_concurrency: config.max_concurrency,
      skip_days: config.skip_days,
      award_credentials: length(config.award_credentials),
      offers_credentials: length(config.offers_credentials)
    }
  end

  defp award_credentials do
    CredentialStore.list(:award)
    |> Enum.map(&%{name: &1.name, value: &1.value})
    |> Enum.reject(&(&1.value in [nil, ""]))
  end

  defp offers_credentials do
    CredentialStore.list(:offers)
    |> Enum.map(&%{name: &1.name, cookies: &1.value, auth_token: ""})
    |> Enum.reject(&(&1.cookies in [nil, ""]))
  end

  defp fetch(params, key), do: params[key] || params[to_string(key)]

  defp parse_airports(nil), do: []

  defp parse_airports(list) when is_list(list) do
    list
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.upcase()))
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_airports(str) when is_binary(str) do
    str
    |> String.split(~r/[,\s]+/)
    |> Enum.map(&(&1 |> String.trim() |> String.upcase()))
    |> Enum.reject(&(&1 == ""))
  end

  defp to_int(nil, default), do: default
  defp to_int(n, _default) when is_integer(n), do: n

  defp to_int(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  defp valid_date?(%Date{}), do: true
  defp valid_date?(str) when is_binary(str), do: match?({:ok, _}, Date.from_iso8601(str))
  defp valid_date?(_), do: false
end
