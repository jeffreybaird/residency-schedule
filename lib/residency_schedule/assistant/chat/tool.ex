defmodule ResidencySchedule.Assistant.Chat.Tool do
  @moduledoc """
  A tool the model may call, described with JSON Schema. Providers translate
  this to their own wire format.
  """

  @enforce_keys [:name, :description, :input_schema]
  defstruct [:name, :description, :input_schema]

  @type t :: %__MODULE__{name: String.t(), description: String.t(), input_schema: map}

  @doc """
  Builds a tool definition.

      iex> tool = ResidencySchedule.Assistant.Chat.Tool.new("who_is_on", "Who is on a service", %{type: "object", properties: %{rotation: %{type: "string"}}, required: ["rotation"]})
      iex> {tool.name, tool.input_schema.required}
      {"who_is_on", ["rotation"]}
  """
  def new(name, description, input_schema)
      when is_binary(name) and is_binary(description) and is_map(input_schema) do
    %__MODULE__{name: name, description: description, input_schema: input_schema}
  end
end
