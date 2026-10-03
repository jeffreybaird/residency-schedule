defmodule ResidencySchedule.DetailedSchedules.Activity do
  @moduledoc "One literal QGenda task for a resident on a calendar date."
  use Ecto.Schema

  schema "detailed_activities" do
    belongs_to :schedule_resident, ResidencySchedule.Residents.ScheduleResident
    field :date, :date
    field :raw_task, :string
    field :period, :string
    field :site, :string
    has_many :sources, ResidencySchedule.DetailedSchedules.ActivitySource
    timestamps(type: :utc_datetime)
  end
end
