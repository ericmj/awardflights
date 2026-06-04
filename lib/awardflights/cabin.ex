defmodule Awardflights.Cabin do
  @moduledoc """
  Helpers for normalizing cabin names returned by the SAS APIs.
  """

  @doc """
  Normalizes a raw cabin name to title case.

  Splits on whitespace and underscores so multi-word cabins such as
  "PREMIUM ECONOMY" or "PREMIUM_ECONOMY" become "Premium Economy" rather than
  being collapsed to "Premium economy". Non-binary input becomes "Unknown".
  """
  def format_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.split(~r/[\s_]+/, trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def format_name(_), do: "Unknown"
end
