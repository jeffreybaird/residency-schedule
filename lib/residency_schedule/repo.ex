defmodule ResidencySchedule.Repo do
  use Ecto.Repo,
    otp_app: :residency_schedule,
    adapter: Ecto.Adapters.Postgres

  alias ResidencySchedule.Observability.Tracing

  @impl true
  def default_options(operation) when operation in [:all, :preload],
    do: Tracing.preload_options()

  def default_options(_), do: []
end
