defmodule ResidencySchedule.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias ResidencySchedule.Assistant.Chat.Session

  @impl true
  def start(_type, _args) do
    children =
      [
        ResidencyScheduleWeb.Telemetry,
        ResidencySchedule.Repo,
        {DNSCluster,
         query: Application.get_env(:residency_schedule, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: ResidencySchedule.PubSub}
      ] ++
        Session.children() ++
        [
          # Start to serve requests, typically the last entry
          ResidencyScheduleWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ResidencySchedule.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ResidencyScheduleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
