defmodule ResidencySchedule.Assistant.Chat.ConversationTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.Chat.{
    Conversation,
    Message,
    Providers.Fake,
    Tool,
    ToolCall,
    ToolResult
  }

  alias ResidencySchedule.Assistant.LocalDate

  doctest Conversation

  defmodule Toolbox do
    @behaviour ResidencySchedule.Assistant.Chat.Toolbox

    @impl true
    def tools do
      [
        Tool.new("who_is_on", "Who is on", %{type: "object", properties: %{}}),
        Tool.new("request_coverage", "File a request", %{type: "object", properties: %{}})
      ]
    end

    @impl true
    def mutating?("request_coverage"), do: true
    def mutating?(_name), do: false

    @impl true
    def run(%ToolCall{} = call, user) do
      send(user, {:ran, call.name})
      ToolResult.ok(call.id, "ran " <> call.name)
    end
  end

  defp conversation(opts \\ []) do
    Conversation.new([toolbox: Toolbox, user: self(), system: "Be terse."] ++ opts)
  end

  defp on_event, do: &send(self(), {:event, &1})

  defp events do
    receive do
      {:event, event} -> [event | events()]
    after
      0 -> []
    end
  end

  defp read_call(id \\ "toolu_r"), do: ToolCall.new(id, "who_is_on", %{"rotation" => "onc"})

  defp write_call(id \\ "toolu_w"),
    do: ToolCall.new(id, "request_coverage", %{"covering" => "Nora"})

  describe "new/1" do
    test "defaults the system prompt to today's" do
      conversation = Conversation.new(toolbox: Toolbox)

      assert conversation.system =~
               "Today is #{Date.to_iso8601(LocalDate.today())}"
    end

    test "requires a toolbox" do
      assert_raise ArgumentError, fn -> Conversation.new([]) end
    end
  end

  describe "send/3 without tools" do
    test "appends the user and assistant turns and records the stop" do
      Fake.script([{:text, "Nora."}])
      assert {:ok, conversation} = Conversation.send(conversation(), "Who is on onc?", on_event())
      assert Enum.map(conversation.messages, & &1.role) == [:user, :assistant]
      assert conversation.last_stop == :end_turn
      assert conversation.usage == %{input_tokens: 0, output_tokens: 0}
      assert [text_delta: "Nora.", done: _] = events()
    end

    test "offers the toolbox's tools to the model" do
      Fake.script([fn request -> {:text, Enum.map_join(request.tools, ",", & &1.name)} end])
      assert {:ok, conversation} = Conversation.send(conversation(), "Hi", on_event())
      assert Message.text(List.last(conversation.messages)) == "who_is_on,request_coverage"
    end

    test "a truncated answer is still a completed turn" do
      Fake.script([{:text, "Nora is", :max_tokens}])

      assert {:ok, %{last_stop: :max_tokens}} =
               Conversation.send(conversation(), "Hi", on_event())
    end

    test "accumulates usage across turns" do
      Fake.script([{:text, "ok"}])
      conversation = %{conversation() | usage: %{input_tokens: 5, cache_read_input_tokens: 2}}
      assert {:ok, conversation} = Conversation.send(conversation, "Hi", on_event())

      assert conversation.usage == %{
               input_tokens: 5,
               output_tokens: 0,
               cache_read_input_tokens: 2
             }
    end

    test "a provider failure keeps the user message and reports the reason" do
      Fake.script([{:error, :boom}])
      assert {:error, :boom, conversation} = Conversation.send(conversation(), "Hi", on_event())
      assert [%Message{role: :user}] = conversation.messages
    end
  end

  describe "send/3 with read-only tools" do
    test "runs the calls and continues until the model answers" do
      Fake.script([{:tool_calls, "Checking.", [read_call()]}, {:text, "Nora."}])
      assert {:ok, conversation} = Conversation.send(conversation(), "Who is on onc?", on_event())

      assert Enum.map(conversation.messages, & &1.role) == [:user, :assistant, :user, :assistant]

      assert [%ToolResult{call_id: "toolu_r", content: "ran who_is_on", error?: false}] =
               Enum.at(conversation.messages, 2).parts

      assert_received {:ran, "who_is_on"}

      assert [
               {:text_delta, "Checking."},
               {:tool_call, %ToolCall{name: "who_is_on"}},
               {:done, %{stop: :tool_use}},
               {:tool_result, %ToolCall{id: "toolu_r"}, %ToolResult{content: "ran who_is_on"}},
               {:text_delta, "Nora."},
               {:done, %{stop: :end_turn}}
             ] = events()
    end

    test "a tool_use stop with no surviving calls ends the turn" do
      Fake.script([{:tool_calls, "Hmm.", []}])

      assert {:ok, %{last_stop: :tool_use, pending: []}} =
               Conversation.send(conversation(), "Hi", on_event())

      refute_received {:ran, _}
    end

    test "stops after the round limit with the history left valid" do
      Fake.script(List.duplicate({:tool_calls, nil, [read_call()]}, 3))

      assert {:error, :max_tool_rounds, conversation} =
               Conversation.send(conversation(max_tool_rounds: 2), "Hi", on_event())

      assert %Message{role: :user, parts: [%ToolResult{error?: true, content: content}]} =
               List.last(conversation.messages)

      assert content =~ "limit reached"
      assert Enum.count(events(), &match?({:tool_result, _, %ToolResult{error?: false}}, &1)) == 2
    end

    test "a provider failure after a tool round keeps the tool results" do
      Fake.script([{:tool_calls, nil, [read_call()]}, {:error, :boom}])
      assert {:error, :boom, conversation} = Conversation.send(conversation(), "Hi", on_event())
      assert Enum.map(conversation.messages, & &1.role) == [:user, :assistant, :user]
    end
  end

  describe "the approval gate" do
    test "pauses on a mutating call without running anything in the batch" do
      Fake.script([{:tool_calls, "Filing.", [read_call(), write_call()]}])

      assert {:ok, conversation} =
               Conversation.send(conversation(), "Cover me Friday", on_event())

      assert Conversation.awaiting_approval?(conversation)
      assert Enum.map(conversation.pending, & &1.name) == ["who_is_on", "request_coverage"]
      assert Enum.map(conversation.messages, & &1.role) == [:user, :assistant]
      refute_received {:ran, _}
      assert {:approval_required, [_, _]} = List.last(events())
    end

    test "refuses new messages while paused" do
      conversation = %{conversation() | pending: [write_call()]}

      assert {:error, :awaiting_approval, ^conversation} =
               Conversation.send(conversation, "Hi", on_event())
    end

    test "approve runs every pending call and resumes" do
      Fake.script([{:text, "Filed."}])
      conversation = %{conversation() | pending: [read_call(), write_call()]}
      assert {:ok, conversation} = Conversation.approve(conversation, on_event())

      refute Conversation.awaiting_approval?(conversation)
      assert_received {:ran, "who_is_on"}
      assert_received {:ran, "request_coverage"}

      assert [%ToolResult{error?: false}, %ToolResult{error?: false}] =
               Enum.at(conversation.messages, -2).parts

      assert Message.text(List.last(conversation.messages)) == "Filed."
    end

    test "deny declines mutating calls, runs read-only ones, and resumes" do
      Fake.script([{:text, "Okay, not filed."}])
      conversation = %{conversation() | pending: [read_call(), write_call()]}
      assert {:ok, conversation} = Conversation.deny(conversation, on_event())

      assert_received {:ran, "who_is_on"}
      refute_received {:ran, "request_coverage"}

      assert [
               %ToolResult{call_id: "toolu_r", error?: false},
               %ToolResult{call_id: "toolu_w", error?: true, content: declined}
             ] = Enum.at(conversation.messages, -2).parts

      assert declined =~ "declined"
      assert Message.text(List.last(conversation.messages)) == "Okay, not filed."
    end

    test "approve and deny need something pending" do
      conversation = conversation()

      assert {:error, :nothing_pending, ^conversation} =
               Conversation.approve(conversation, on_event())

      assert {:error, :nothing_pending, ^conversation} =
               Conversation.deny(conversation, on_event())
    end

    test "a second mutating call after approval pauses again" do
      Fake.script([{:tool_calls, nil, [write_call("toolu_w2")]}])
      conversation = %{conversation() | pending: [write_call()]}
      assert {:ok, conversation} = Conversation.approve(conversation, on_event())
      assert [%ToolCall{id: "toolu_w2"}] = conversation.pending
    end
  end
end
