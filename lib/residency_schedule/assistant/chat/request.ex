defmodule ResidencySchedule.Assistant.Chat.Request do
  @moduledoc """
  Everything a provider needs for one model turn: the system prompt, the
  conversation so far, and the tools on offer. Model and generation settings
  come from provider config, not the request.
  """

  alias ResidencySchedule.Assistant.Chat.{Message, Tool}

  defstruct system: "", messages: [], tools: []

  @type t :: %__MODULE__{system: String.t(), messages: [Message.t()], tools: [Tool.t()]}

  @doc """
  Builds a request.

      iex> alias ResidencySchedule.Assistant.Chat.Message
      iex> request = ResidencySchedule.Assistant.Chat.Request.new(system: "You help with schedules.", messages: [Message.user("Hi")])
      iex> {request.system, length(request.messages), request.tools}
      {"You help with schedules.", 1, []}
  """
  def new(attrs) when is_list(attrs), do: struct!(__MODULE__, attrs)
end
