defmodule ResidencySchedule.TaskMappings.Target do
  @moduledoc "One of a task mapping revision's independently retained activity targets."
  use Ecto.Schema

  @primary_key false
  schema "source_task_mapping_targets" do
    belongs_to :mapping, ResidencySchedule.TaskMappings.Mapping, primary_key: true
    field :activity_type_code, :string, primary_key: true
  end
end
