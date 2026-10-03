defmodule ResidencySchedule.DetailedSchedules.ImportBatch do
  @moduledoc "Provenance for a confirmed QGenda workbook within one academic year."
  use Ecto.Schema

  schema "detailed_import_batches" do
    belongs_to :schedule, ResidencySchedule.Schedules.Schedule
    belongs_to :created_by, ResidencySchedule.Accounts.User
    field :fingerprint, :string
    field :header_start, :date
    field :header_end, :date
    timestamps(type: :utc_datetime)
  end
end
