defmodule ResidencySchedule.Assistant.Chat.Providers.Anthropic.AccumulatorTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.Chat.Providers.Anthropic.Accumulator
  alias ResidencySchedule.Assistant.Chat.ToolCall

  doctest Accumulator

  defp run(events) do
    Enum.reduce(events, {Accumulator.new(), []}, fn event, {state, emitted} ->
      {state, new} = Accumulator.apply(state, event)
      {state, emitted ++ new}
    end)
  end

  defp start(index, block),
    do: %{"type" => "content_block_start", "index" => index, "content_block" => block}

  defp delta(index, delta),
    do: %{"type" => "content_block_delta", "index" => index, "delta" => delta}

  defp stop(index), do: %{"type" => "content_block_stop", "index" => index}

  defp message_delta(reason, usage \\ %{}),
    do: %{"type" => "message_delta", "delta" => %{"stop_reason" => reason}, "usage" => usage}

  describe "tool_use blocks" do
    test "assemble partial JSON and emit one tool call on stop" do
      {state, emitted} =
        run([
          start(0, %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "who_is_on",
            "input" => %{}
          }),
          delta(0, %{"type" => "input_json_delta", "partial_json" => ~s({"rota)}),
          delta(0, %{"type" => "input_json_delta", "partial_json" => ~s(tion": "onc"})}),
          stop(0),
          message_delta("tool_use")
        ])

      call = ToolCall.new("toolu_1", "who_is_on", %{"rotation" => "onc"})
      assert emitted == [tool_call: call]
      assert {:ok, message, %{stop: :tool_use}} = Accumulator.finish(state)
      assert message.parts == [call]

      assert message.raw == [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_1",
                 "name" => "who_is_on",
                 "input" => %{"rotation" => "onc"}
               }
             ]
    end

    test "empty input decodes to an empty map" do
      {_state, emitted} =
        run([
          start(0, %{"type" => "tool_use", "id" => "toolu_1", "name" => "whoami", "input" => %{}}),
          stop(0)
        ])

      assert emitted == [tool_call: ToolCall.new("toolu_1", "whoami", %{})]
    end

    test "truncated input drops the block without emitting" do
      {state, emitted} =
        run([
          start(0, %{"type" => "tool_use", "id" => "toolu_1", "name" => "whoami", "input" => %{}}),
          delta(0, %{"type" => "input_json_delta", "partial_json" => ~s({"rota)}),
          stop(0),
          message_delta("max_tokens")
        ])

      assert emitted == []
      assert {:ok, message, %{stop: :max_tokens}} = Accumulator.finish(state)
      assert message.parts == []
      assert message.raw == []
    end

    test "non-object input drops the block" do
      {state, []} =
        run([
          start(0, %{"type" => "tool_use", "id" => "toolu_1", "name" => "whoami", "input" => %{}}),
          delta(0, %{"type" => "input_json_delta", "partial_json" => "[1]"}),
          stop(0)
        ])

      assert state.blocks == %{}
    end
  end

  describe "thinking blocks" do
    test "are kept in raw with their signature but not in parts" do
      {state, emitted} =
        run([
          start(0, %{"type" => "thinking", "thinking" => ""}),
          delta(0, %{"type" => "thinking_delta", "thinking" => "hmm"}),
          delta(0, %{"type" => "signature_delta", "signature" => "sig"}),
          stop(0),
          start(1, %{"type" => "redacted_thinking", "data" => "opaque"}),
          stop(1),
          start(2, %{"type" => "text", "text" => ""}),
          delta(2, %{"type" => "text_delta", "text" => "Yes."}),
          stop(2),
          message_delta("end_turn")
        ])

      assert emitted == [text_delta: "Yes."]
      assert {:ok, message, _meta} = Accumulator.finish(state)
      assert message.parts == [text: "Yes."]

      assert message.raw == [
               %{"type" => "thinking", "thinking" => "hmm", "signature" => "sig"},
               %{"type" => "redacted_thinking", "data" => "opaque"},
               %{"type" => "text", "text" => "Yes."}
             ]
    end
  end

  describe "text blocks" do
    test "empty text blocks are kept raw but produce no part" do
      {state, []} = run([start(0, %{"type" => "text", "text" => ""}), stop(0)])
      assert {:ok, message, _meta} = Accumulator.finish(state)
      assert {message.parts, message.raw} == {[], [%{"type" => "text", "text" => ""}]}
    end

    test "a start block with a nil text field is normalised" do
      {state, _} = run([start(0, %{"type" => "text", "text" => nil})])
      assert state.blocks[0]["text"] == ""
    end

    test "blocks are ordered by index regardless of arrival" do
      {state, _} =
        run([
          start(1, %{"type" => "text", "text" => "b"}),
          start(0, %{"type" => "text", "text" => "a"})
        ])

      assert {:ok, message, _meta} = Accumulator.finish(state)
      assert message.parts == [text: "a", text: "b"]
    end
  end

  describe "deltas for unknown blocks" do
    test "an unknown delta type is ignored" do
      {state, []} =
        run([
          start(0, %{"type" => "text", "text" => ""}),
          delta(0, %{"type" => "citations_delta"})
        ])

      assert state.blocks[0] == %{"type" => "text", "text" => ""}
    end

    test "a delta before its start creates the block" do
      {state, [text_delta: "x"]} = run([delta(3, %{"type" => "text_delta", "text" => "x"})])
      assert state.blocks[3] == %{"text" => "x"}
    end

    test "a stop for an unknown index is ignored" do
      assert {%Accumulator{}, []} = run([stop(9)])
    end
  end

  describe "message events" do
    test "usage merges start and delta counts" do
      {state, []} =
        run([
          %{
            "type" => "message_start",
            "message" => %{
              "model" => "m",
              "usage" => %{
                "input_tokens" => 5,
                "cache_read_input_tokens" => 2,
                "service_tier" => "x"
              }
            }
          },
          message_delta("end_turn", %{"output_tokens" => 9})
        ])

      assert {:ok, _message, meta} = Accumulator.finish(state)

      assert meta == %{
               stop: :end_turn,
               usage: %{input_tokens: 5, cache_read_input_tokens: 2, output_tokens: 9},
               model: "m"
             }
    end

    test "a message_start without usage is fine" do
      {state, []} = run([%{"type" => "message_start", "message" => %{"model" => "m"}}])
      assert state.usage == %{}
    end

    test "an error event fails finish" do
      {state, []} =
        run([
          %{
            "type" => "error",
            "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
          }
        ])

      assert Accumulator.finish(state) ==
               {:error,
                {:api_error, %{status: nil, type: "overloaded_error", message: "Overloaded"}}}
    end

    test "ping and message_stop are ignored" do
      assert {%Accumulator{}, []} = run([%{"type" => "ping"}, %{"type" => "message_stop"}])
    end

    test "finish without a message_delta reports an unknown stop" do
      assert {:ok, _message, %{stop: :unknown}} = Accumulator.finish(Accumulator.new())
    end
  end

  describe "stop_reason/1" do
    test "maps every documented reason" do
      assert Accumulator.stop_reason(%{"stop_reason" => "end_turn"}) == :end_turn
      assert Accumulator.stop_reason(%{"stop_reason" => "stop_sequence"}) == :end_turn
      assert Accumulator.stop_reason(%{"stop_reason" => "max_tokens"}) == :max_tokens
      assert Accumulator.stop_reason(%{"stop_reason" => "pause_turn"}) == :unknown
      assert Accumulator.stop_reason(%{}) == :unknown
    end
  end
end
