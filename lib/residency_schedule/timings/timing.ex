defmodule ResidencySchedule.Timings.Timing do
  @moduledoc "How precisely one saved source occurrence states its time, preserving its inputs."
  use Ecto.Schema

  schema "activity_source_timings" do
    field :original_source_id, :integer
    belongs_to :activity_source, ResidencySchedule.DetailedSchedules.ActivitySource
    field :namespace, :string
    field :source_date, :date
    field :precision, :string
    field :period, :string
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :time_zone, :string
    field :source_snapshot, :map, default: %{}
    field :input_digest, :string
    field :rule_version, :string
    field :policy, :string
    field :evidence_origin, :string
    timestamps(type: :utc_datetime)
  end
end
