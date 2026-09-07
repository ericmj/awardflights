defmodule Awardflights.Itinerary.Stop do
  @moduledoc "A layover between two segments: the airport and the time on the ground in minutes."
  defstruct [:airport, :duration]
end
