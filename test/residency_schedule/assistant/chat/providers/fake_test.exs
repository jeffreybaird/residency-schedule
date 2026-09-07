defmodule ResidencySchedule.Assistant.Chat.Providers.FakeTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.Chat.{Message, Providers.Fake, Request, ToolCall}

  doctest Fake

  @request Request.new(messages: [Message.user("Who is on onc today?")])

  defp on_event, do: &send(self(), {:event, &1})

  defp events do
    receive do
      {:event, event} -> [event | events()]
    after
      0 -> []
    end
  end

  describe "stream/3 with no script" do
    test "echoes the last user message" do
      request =
        Request.new(
          messages: [
            Message.user("First"),
            Message.assistant([{:text, "ok"}]),
            Message.user("Second")
          ]
        )

      assert {:ok, reply, meta} = Fake.stream(request, [], on_event())
      assert Message.text(reply) == "fake: Second"

      assert meta == %{
               stop: :end_turn,
               usage: %{input_tokens: 0, output_tokens: 0},
               model: "fake"
             }
    end

    test "echoes an empty string when there is no user message" do
      assert {:ok, reply, _meta} = Fake.stream(Request.new([]), [], on_event())
      assert Message.text(reply) == "fake: "
    end
  end

  describe "stream/3 turns" do
    test "text streams word by word then finishes" do
      assert {:ok, _reply, _meta} =
               Fake.stream(@request, [script: {:text, "Nora is on."}], on_event())

      assert events() == [
               text_delta: "Nora ",
               text_delta: "is ",
               text_delta: "on.",
               done: %{
                 stop: :end_turn,
                 usage: %{input_tokens: 0, output_tokens: 0},
                 model: "fake"
               }
             ]
    end

    test "text honours an explicit stop reason" do
      assert {:ok, reply, %{stop: :max_tokens}} =
               Fake.stream(@request, [script: {:text, "Nora is", :max_tokens}], on_event())

      assert Message.text(reply) == "Nora is"
    end

    test "tool calls without lead-in text emit only calls" do
      call = ToolCall.new("toolu_1", "who_is_on", %{"rotation" => "onc"})

      assert {:ok, reply, %{stop: :tool_use}} =
               Fake.stream(@request, [script: {:tool_calls, nil, [call]}], on_event())

      assert reply.parts == [call]

      assert events() == [
               tool_call: call,
               done: %{
                 stop: :tool_use,
                 usage: %{input_tokens: 0, output_tokens: 0},
                 model: "fake"
               }
             ]
    end

    test "error turns fail without emitting events" do
      assert Fake.stream(@request, [script: {:error, :boom}], on_event()) == {:error, :boom}
      assert events() == []
    end

    test "a function turn sees the request" do
      script = fn %Request{messages: [message]} ->
        {:text, "You said: " <> Message.text(message)}
      end

      assert {:ok, reply, _meta} = Fake.stream(@request, [script: script], on_event())
      assert Message.text(reply) == "You said: Who is on onc today?"
    end
  end

  describe "script/1" do
    test "turns are consumed in order and then exhausted" do
      Fake.script([{:text, "One"}, {:error, :nope}])
      assert {:ok, reply, _meta} = Fake.stream(@request, [], on_event())
      assert Message.text(reply) == "One"
      assert Fake.stream(@request, [], on_event()) == {:error, :nope}
      assert Fake.stream(@request, [], on_event()) == {:error, :script_exhausted}
    end

    test "takes precedence over the config script" do
      Fake.script([{:text, "From script"}])

      assert {:ok, reply, _meta} =
               Fake.stream(@request, [script: {:text, "From config"}], on_event())

      assert Message.text(reply) == "From script"
    end

    test "is visible from processes the test spawns" do
      Fake.script([{:text, "Seen from a task"}])
      reply = Task.async(fn -> Fake.stream(@request, [], fn _ -> :ok end) end) |> Task.await()
      assert {:ok, %Message{} = message, _meta} = reply
      assert Message.text(message) == "Seen from a task"
    end

    test "ignores a caller that has already exited" do
      parent = self()

      spawn(fn ->
        Process.put(:"$callers", [spawn(fn -> :ok end)])
        Process.sleep(10)
        send(parent, Fake.stream(@request, [], fn _ -> :ok end))
      end)

      assert_receive {:ok, %Message{} = message, _meta}
      assert Message.text(message) == "fake: Who is on onc today?"
    end
  end
end
