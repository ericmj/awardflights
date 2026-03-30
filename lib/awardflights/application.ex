defmodule Awardflights.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AwardflightsWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:awardflights, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Awardflights.PubSub},
      Awardflights.CsvWriter,
      Awardflights.RequestTracker,
      Awardflights.RateLimitTracker,
      {Task.Supervisor, name: Awardflights.TaskSupervisor},
      Awardflights.FlightScanner,
      # Start to serve requests, typically the last entry
      AwardflightsWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Awardflights.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AwardflightsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
