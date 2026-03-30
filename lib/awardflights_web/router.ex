defmodule AwardflightsWeb.Router do
  use AwardflightsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AwardflightsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AwardflightsWeb do
    pipe_through :browser

    live "/", ScannerLive
    live "/trips", TripsLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", AwardflightsWeb do
  #   pipe_through :api
  # end
end
