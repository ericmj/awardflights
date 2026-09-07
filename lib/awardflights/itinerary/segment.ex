defmodule Awardflights.Itinerary.Segment do
  @moduledoc """
  One flight leg. Times are ISO 8601 local times, with a UTC offset when the API
  gives one, and duration is in minutes. `operating_carrier` falls back to the
  marketing carrier when the API does not name a separate operator. `layover`
  is the time on the ground after this leg as stated by the API; it feeds the
  itinerary's stops rather than being stored per segment.
  """
  defstruct [
    :flight_number,
    :departure,
    :arrival,
    :departure_time,
    :arrival_time,
    :duration,
    :marketing_carrier,
    :operating_carrier,
    :layover
  ]
end
