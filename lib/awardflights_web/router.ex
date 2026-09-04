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

  scope "/api", AwardflightsWeb do
    pipe_through :api

    post "/scan", ScanController, :create
    post "/scan/stop", ScanController, :stop
    get "/scan/status", ScanController, :status
  end
end
