defmodule ResidencySchedule.TaskMappings.ActivityType do
  @moduledoc "Stable activity codes retained independently of presentation labels."
  use Ecto.Schema

  schema "activity_types" do
    field :code, :string
    field :label, :string
    field :description, :string
    timestamps(type: :utc_datetime)
  end
end
