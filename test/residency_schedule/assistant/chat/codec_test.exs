defmodule ResidencySchedule.Assistant.Chat.CodecTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.Chat.Toolbox.Empty

  alias ResidencySchedule.Assistant.Chat.{
    Codec,
    Conversation,
    Message,
    ToolCall,
    ToolResult,
    Transcript
  }

  doctest Codec

  defp base, do: Conversation.new(toolbox: Empty, system: "Be terse.")

  describe "round trip" do
    test "keeps tool calls, results, raw content, pending calls, and usage" do
      call = ToolCall.new("toolu_1", "request_coverage", %{"covering" => "Nora"})
      result = ToolResult.error("toolu_1", "declined")

      conversation = %{
        base()
        | messages: [
            Message.user("Cover me"),
            Message.assistant([{:text, "Filing."}, call], [
              %{"type" => "text", "text" => "Filing."}
            ]),
            Message.tool_results([result])
          ],
          pending: [call],
          usage: %{input_tokens: 12, output_tokens: 3},
          last_stop: :tool_use
      }

      transcript =
        Transcript.new()
        |> Transcript.add(%{kind: :user, text: "Cover me"})
        |> Transcript.append_text("Filing.")
        |> Transcript.start_tool(call)
        |> Transcript.finish_tool("toolu_1", result)

      data = conversation |> Codec.dump(transcript) |> json_round_trip()
      assert {:ok, loaded, loaded_transcript} = Codec.load(data, base())

      assert loaded.messages == conversation.messages
      assert loaded.pending == [call]
      assert loaded.usage == %{input_tokens: 12, output_tokens: 3}
      assert loaded.last_stop == :tool_use
      assert loaded_transcript == transcript
    end

    test "keeps the base conversation's toolbox, user, and system prompt" do
      data = Codec.dump(base(), Transcript.new())
      fresh = Conversation.new(toolbox: Empty, system: "Today is later.", user: :someone)
      assert {:ok, loaded, _transcript} = Codec.load(data, fresh)
      assert {loaded.toolbox, loaded.user, loaded.system} == {Empty, :someone, "Today is later."}
    end

    test "a conversation that never ran has no stop reason" do
      data = base() |> Codec.dump(Transcript.new()) |> json_round_trip()
      assert {:ok, %{last_stop: nil}, _} = Codec.load(data, base())
    end
  end

  describe "load/2" do
    test "refuses a layout it does not know" do
      assert Codec.load(%{"version" => 99}, base()) == {:error, :unreadable}
      assert Codec.load(%{}, base()) == {:error, :unreadable}
    end

    test "drops usage keys it does not know" do
      data = %{
        (base()
         |> Codec.dump(Transcript.new()))
        | "usage" => %{"input_tokens" => 4, "rare" => 1}
      }

      assert {:ok, %{usage: %{input_tokens: 4}}, _} = Codec.load(data, base())
    end

    test "a known layout with broken contents is unreadable" do
      data = %{(base() |> Codec.dump(Transcript.new())) | "messages" => "junk"}
      assert Codec.load(data, base()) == {:error, :unreadable}
    end

    test "drops a stop reason it does not know" do
      data = %{(base() |> Codec.dump(Transcript.new())) | "last_stop" => "something_new"}
      assert {:ok, %{last_stop: nil}, _} = Codec.load(data, base())
    end
  end

  # Postgres hands back what it stored as JSON, so the load side always sees
  # string keys and no atoms.
  defp json_round_trip(data), do: data |> Jason.encode!() |> Jason.decode!()
end
