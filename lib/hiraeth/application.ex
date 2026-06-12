defmodule Hiraeth.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      HiraethWeb.Telemetry,
      Hiraeth.Repo,
      {AshAuthentication.Supervisor, otp_app: :hiraeth},
      {DNSCluster, query: Application.get_env(:hiraeth, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Hiraeth.PubSub},
      # Start a worker by calling: Hiraeth.Worker.start_link(arg)
      # {Hiraeth.Worker, arg},
      # Start to serve requests, typically the last entry
      HiraethWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Hiraeth.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HiraethWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
