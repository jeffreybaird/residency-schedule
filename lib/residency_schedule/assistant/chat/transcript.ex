defmodule ResidencySchedule.Assistant.Chat.Transcript do
  @moduledoc """
  What the user sees of a conversation: an ordered list of entries built from
  the events a turn emits.

  Each entry is a map with an `:id` and a `:kind`. `:user` and `:assistant`
  entries carry `:text`; a `:tool` entry carries the `:call` and, once the
  tool has run, its `:result`. Streamed text is appended to the last
  assistant entry, so a reply grows in place as it arrives.
  """

  alias ResidencySchedule.Assistant.Chat.{ToolCall, ToolResult}

  defstruct entries: [], next_id: 1

  @type t :: %__MODULE__{entries: [map()], next_id: pos_integer()}

  @doc """
  An empty transcript.

      iex> ResidencySchedule.Assistant.Chat.Transcript.new().entries
      []
  """
  def new, do: %__MODULE__{}

  @doc """
  Appends an entry, giving it the next id.

      iex> alias ResidencySchedule.Assistant.Chat.Transcript
      iex> transcript = Transcript.add(Transcript.new(), %{kind: :user, text: "Who is on onc?"})
      iex> transcript.entries
      [%{id: 1, kind: :user, text: "Who is on onc?"}]
  """
  def add(%__MODULE__{entries: entries, next_id: id} = transcript, entry) do
    %{transcript | entries: entries ++ [Map.put(entry, :id, id)], next_id: id + 1}
  end

  @doc """
  Adds streamed text to the reply in progress, or starts one.

      iex> alias ResidencySchedule.Assistant.Chat.Transcript
      iex> transcript =
      ...>   Transcript.new()
      ...>   |> Transcript.add(%{kind: :user, text: "Hi"})
      ...>   |> Transcript.append_text("Nora is ")
      ...>   |> Transcript.append_text("on onc.")
      iex> List.last(transcript.entries)
      %{id: 2, kind: :assistant, text: "Nora is on onc."}
  """
  def append_text(%__MODULE__{entries: entries} = transcript, text) do
    case List.last(entries) do
      %{kind: :assistant} ->
        update_last(transcript, fn entry -> %{entry | text: entry.text <> text} end)

      _other ->
        add(transcript, %{kind: :assistant, text: text})
    end
  end

  @doc """
  Records a tool call the model made; its result arrives with `finish_tool/3`.

      iex> alias ResidencySchedule.Assistant.Chat.{ToolCall, Transcript}
      iex> call = ToolCall.new("toolu_1", "who_is_on", %{"rotation" => "onc"})
      iex> [entry] = Transcript.start_tool(Transcript.new(), call).entries
      iex> {entry.kind, entry.call.name, entry.result}
      {:tool, "who_is_on", nil}
  """
  def start_tool(%__MODULE__{} = transcript, %ToolCall{} = call) do
    add(transcript, %{kind: :tool, call: call, result: nil})
  end

  @doc """
  Attaches a result to the tool entry with the matching call id.

      iex> alias ResidencySchedule.Assistant.Chat.{ToolCall, ToolResult, Transcript}
      iex> call = ToolCall.new("toolu_1", "who_is_on", %{"rotation" => "onc"})
      iex> result = ToolResult.ok("toolu_1", "Nora")
      iex> [entry] = Transcript.new() |> Transcript.start_tool(call) |> Transcript.finish_tool("toolu_1", result) |> Map.fetch!(:entries)
      iex> entry.result.content
      "Nora"
  """
  def finish_tool(%__MODULE__{entries: entries} = transcript, call_id, %ToolResult{} = result) do
    entries =
      Enum.map(entries, fn
        %{kind: :tool, call: %ToolCall{id: ^call_id}} = entry -> %{entry | result: result}
        entry -> entry
      end)

    %{transcript | entries: entries}
  end

  @doc """
  Removes assistant entries that never received any text, which a turn that
  only called tools or failed early can leave behind.

      iex> alias ResidencySchedule.Assistant.Chat.Transcript
      iex> transcript = Transcript.new() |> Transcript.add(%{kind: :assistant, text: ""}) |> Transcript.add(%{kind: :assistant, text: "Done."})
      iex> Enum.map(Transcript.drop_empty(transcript).entries, & &1.text)
      ["Done."]
  """
  def drop_empty(%__MODULE__{entries: entries} = transcript) do
    %{transcript | entries: Enum.reject(entries, &match?(%{kind: :assistant, text: ""}, &1))}
  end

  @doc """
  Applies one event from a running turn. Events the transcript does not show
  (`:done`, `:approval_required`) leave it unchanged.

      iex> alias ResidencySchedule.Assistant.Chat.Transcript
      iex> transcript = Transcript.apply_event(Transcript.new(), {:text_delta, "Hello"})
      iex> transcript.entries
      [%{id: 1, kind: :assistant, text: "Hello"}]
  """
  def apply_event(%__MODULE__{} = transcript, {:text_delta, text}),
    do: append_text(transcript, text)

  def apply_event(%__MODULE__{} = transcript, {:tool_call, %ToolCall{} = call}),
    do: start_tool(transcript, call)

  def apply_event(
        %__MODULE__{} = transcript,
        {:tool_result, %ToolCall{id: id}, %ToolResult{} = result}
      ),
      do: finish_tool(transcript, id, result)

  def apply_event(%__MODULE__{} = transcript, _other), do: transcript

  defp update_last(%__MODULE__{entries: entries} = transcript, fun) do
    %{transcript | entries: List.update_at(entries, -1, fun)}
  end
end
