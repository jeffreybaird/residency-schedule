defmodule ResidencySchedule.DetailedSchedules.ActivitySource do
  @moduledoc "An occurrence of a detailed task in an imported workbook."
  use Ecto.Schema

  schema "detailed_activity_sources" do
    belongs_to :activity, ResidencySchedule.DetailedSchedules.Activity
    belongs_to :batch, ResidencySchedule.DetailedSchedules.ImportBatch
    field :source_sheet, :string
    field :source_cell, :string
    field :raw_staff, :string
    field :display_name, :string
    field :previous_name, :string
    field :notes, {:array, :map}, default: []
    timestamps(type: :utc_datetime)
  end
end
