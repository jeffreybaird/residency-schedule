defmodule ResidencySchedule.Repo do
  use Ecto.Repo,
    otp_app: :residency_schedule,
    adapter: Ecto.Adapters.Postgres
end
