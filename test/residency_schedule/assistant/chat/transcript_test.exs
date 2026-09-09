defmodule ResidencySchedule.Assistant.Chat.TranscriptTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.Chat.{ToolCall, ToolResult, Transcript}

  doctest Transcript

  describe "append_text/2" do
    test "starts an assistant entry when the last entry is not one" do
      transcript =
        Transcript.new()
        |> Transcript.add(%{kind: :user, text: "Hi"})
        |> Transcript.append_text("Hello")

      assert [%{kind: :user}, %{id: 2, kind: :assistant, text: "Hello"}] = transcript.entries
    end

    test "starts an assistant entry on an empty transcript" do
      assert [%{id: 1, kind: :assistant, text: "Hello"}] =
               Transcript.new() |> Transcript.append_text("Hello") |> Map.fetch!(:entries)
    end

    test "extends the reply in progress" do
      transcript =
        Transcript.new() |> Transcript.append_text("Hel") |> Transcript.append_text("lo")

      assert [%{text: "Hello"}] = transcript.entries
    end

    test "starts a new reply after a tool ran" do
      transcript =
        Transcript.new()
        |> Transcript.append_text("Checking.")
        |> Transcript.start_tool(ToolCall.new("toolu_1", "who_is_on"))
        |> Transcript.append_text("Found them.")

      assert [%{text: "Checking."}, %{kind: :tool}, %{text: "Found them."}] = transcript.entries
    end
  end

  describe "finish_tool/3" do
    test "leaves other tool entries alone" do
      transcript =
        Transcript.new()
        |> Transcript.start_tool(ToolCall.new("toolu_1", "who_is_on"))
        |> Transcript.start_tool(ToolCall.new("toolu_2", "find_resident"))
        |> Transcript.finish_tool("toolu_2", ToolResult.error("toolu_2", "No such resident"))

      assert [%{result: nil}, %{result: %ToolResult{error?: true}}] = transcript.entries
    end
  end

  describe "drop_empty/1" do
    test "keeps user entries and tool entries" do
      transcript =
        Transcript.new()
        |> Transcript.add(%{kind: :user, text: ""})
        |> Transcript.start_tool(ToolCall.new("toolu_1", "who_is_on"))
        |> Transcript.add(%{kind: :assistant, text: ""})

      assert [%{kind: :user}, %{kind: :tool}] = Transcript.drop_empty(transcript).entries
    end
  end

  describe "apply_event/2" do
    test "maps tool events onto entries" do
      call = ToolCall.new("toolu_1", "who_is_on", %{"rotation" => "onc"})
      result = ToolResult.ok("toolu_1", "Nora")

      transcript =
        Transcript.new()
        |> Transcript.apply_event({:tool_call, call})
        |> Transcript.apply_event({:tool_result, call, result})

      assert [%{kind: :tool, result: ^result}] = transcript.entries
    end

    test "ignores events it does not show" do
      transcript = Transcript.new()
      assert Transcript.apply_event(transcript, {:done, :end_turn}) == transcript
      assert Transcript.apply_event(transcript, {:approval_required, []}) == transcript
    end
  end
end
