defmodule ResidencySchedule.Assistant.Chat.Providers.AnthropicTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.Chat.{
    Message,
    Providers.Anthropic,
    Request,
    Tool,
    ToolCall,
    ToolResult
  }

  doctest Anthropic

  @tool Tool.new("who_is_on", "Who is on a service", %{
          type: "object",
          properties: %{rotation: %{type: "string"}},
          required: ["rotation"]
        })
  @request Request.new(
             system: "You help with schedules.",
             messages: [Message.user("Who is on onc?")],
             tools: [@tool]
           )

  defp config(plug, extra \\ []) do
    [
      api_key: "sk-test",
      model: "claude-sonnet-5",
      req_options: [plug: plug, retry_delay: fn _ -> 0 end]
    ] ++ extra
  end

  defp on_event, do: &send(self(), {:event, &1})

  defp events do
    receive do
      {:event, event} -> [event | events()]
    after
      0 -> []
    end
  end

  defp sse(events),
    do: Enum.map_join(events, &"event: #{&1["type"]}\ndata: #{Jason.encode!(&1)}\n\n")

  defp stream_plug(events, test_pid) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.req_headers, Jason.decode!(body)})
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, sse(events))
      conn
    end
  end

  defp error_plug(status, body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end
  end

  defp start(index, block),
    do: %{"type" => "content_block_start", "index" => index, "content_block" => block}

  defp delta(index, delta),
    do: %{"type" => "content_block_delta", "index" => index, "delta" => delta}

  defp stop(index), do: %{"type" => "content_block_stop", "index" => index}

  defp text_turn(text, stop_reason \\ "end_turn") do
    [
      %{
        "type" => "message_start",
        "message" => %{"model" => "claude-sonnet-5", "usage" => %{"input_tokens" => 12}}
      },
      start(0, %{"type" => "text", "text" => ""}),
      delta(0, %{"type" => "text_delta", "text" => text}),
      stop(0),
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => stop_reason},
        "usage" => %{"output_tokens" => 4}
      },
      %{"type" => "message_stop"}
    ]
  end

  describe "stream/3 happy paths" do
    test "streams text, emits done, and returns the message with raw blocks" do
      plug = stream_plug(text_turn("Nora is on."), self())

      assert {:ok, reply, meta} = Anthropic.stream(@request, config(plug), on_event())
      assert Message.text(reply) == "Nora is on."
      assert reply.raw == [%{"type" => "text", "text" => "Nora is on."}]

      assert meta == %{
               stop: :end_turn,
               usage: %{input_tokens: 12, output_tokens: 4},
               model: "claude-sonnet-5"
             }

      assert events() == [text_delta: "Nora is on.", done: meta]
    end

    test "sends auth headers and a cacheable body" do
      plug = stream_plug(text_turn("ok"), self())
      {:ok, _reply, _meta} = Anthropic.stream(@request, config(plug, effort: "low"), on_event())

      assert_received {:request, headers, body}
      assert {"x-api-key", "sk-test"} in headers
      assert {"anthropic-version", "2023-06-01"} in headers
      assert body["model"] == "claude-sonnet-5"
      assert body["stream"] == true
      assert body["max_tokens"] == 16_000
      assert body["output_config"] == %{"effort" => "low"}

      assert body["system"] == [
               %{
                 "type" => "text",
                 "text" => "You help with schedules.",
                 "cache_control" => %{"type" => "ephemeral"}
               }
             ]

      assert [%{"name" => "who_is_on", "input_schema" => %{"required" => ["rotation"]}}] =
               body["tools"]

      assert body["messages"] == [
               %{"role" => "user", "content" => [%{"type" => "text", "text" => "Who is on onc?"}]}
             ]
    end

    test "emits parallel tool calls as they complete" do
      events = [
        start(0, %{"type" => "text", "text" => ""}),
        delta(0, %{"type" => "text_delta", "text" => "Checking."}),
        stop(0),
        start(1, %{"type" => "tool_use", "id" => "toolu_1", "name" => "who_is_on", "input" => %{}}),
        delta(1, %{"type" => "input_json_delta", "partial_json" => ~s({"rotation": "onc"})}),
        stop(1),
        start(2, %{"type" => "tool_use", "id" => "toolu_2", "name" => "whoami", "input" => %{}}),
        stop(2),
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "tool_use"},
          "usage" => %{"output_tokens" => 30}
        }
      ]

      assert {:ok, reply, %{stop: :tool_use}} =
               Anthropic.stream(@request, config(stream_plug(events, self())), on_event())

      first = ToolCall.new("toolu_1", "who_is_on", %{"rotation" => "onc"})
      second = ToolCall.new("toolu_2", "whoami", %{})
      assert Message.tool_calls(reply) == [first, second]
      assert [text_delta: "Checking.", tool_call: ^first, tool_call: ^second, done: _] = events()
    end

    test "reports a refusal stop" do
      assert {:ok, _reply, %{stop: :refusal}} =
               Anthropic.stream(
                 @request,
                 config(stream_plug(text_turn("", "refusal"), self())),
                 on_event()
               )
    end

    test "ignores undecodable events" do
      plug = fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        {:ok, conn} =
          Plug.Conn.chunk(conn, "event: junk\ndata: {nope\n\n" <> sse(text_turn("fine")))

        conn
      end

      assert {:ok, reply, _meta} = Anthropic.stream(@request, config(plug), on_event())
      assert Message.text(reply) == "fine"
    end

    test "an empty 200 body yields an empty message" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 200, "") end

      assert {:ok, %Message{parts: [], raw: []}, %{stop: :unknown}} =
               Anthropic.stream(@request, config(plug), on_event())
    end

    test "retries overload once and then succeeds" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)
      good = stream_plug(text_turn("after retry"), self())

      plug = fn conn ->
        case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
          0 ->
            error_plug(529, ~s({"error":{"type":"overloaded_error","message":"Overloaded"}})).(
              conn
            )

          _ ->
            good.(conn)
        end
      end

      assert {:ok, reply, _meta} = Anthropic.stream(@request, config(plug), on_event())
      assert Message.text(reply) == "after retry"
      assert Agent.get(attempts, & &1) == 2
    end
  end

  describe "stream/3 failures" do
    test "fails fast without a key" do
      assert Anthropic.stream(@request, [model: "m"], on_event()) == {:error, :missing_api_key}

      assert Anthropic.stream(@request, [model: "m", api_key: ""], on_event()) ==
               {:error, :missing_api_key}

      assert events() == []
    end

    test "surfaces a structured API error" do
      plug =
        error_plug(
          400,
          ~s({"type":"error","error":{"type":"invalid_request_error","message":"bad"}})
        )

      assert Anthropic.stream(@request, config(plug), on_event()) ==
               {:error,
                {:api_error, %{status: 400, type: "invalid_request_error", message: "bad"}}}

      assert events() == []
    end

    test "keeps a non-JSON error body as the message" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 502, "<html>Bad Gateway</html>") end

      assert Anthropic.stream(@request, config(plug), on_event()) ==
               {:error,
                {:api_error, %{status: 502, type: nil, message: "<html>Bad Gateway</html>"}}}
    end

    test "gives up after the retry budget" do
      plug = error_plug(429, ~s({"error":{"type":"rate_limit_error","message":"slow down"}}))

      assert {:error, {:api_error, %{status: 429, type: "rate_limit_error"}}} =
               Anthropic.stream(@request, config(plug), on_event())
    end

    test "wraps transport errors" do
      plug = fn conn -> Req.Test.transport_error(conn, :econnrefused) end

      assert {:error, {:transport, %Req.TransportError{reason: :econnrefused}}} =
               Anthropic.stream(@request, config(plug), on_event())
    end

    test "a mid-stream error event fails the turn after partial text" do
      events = [
        start(0, %{"type" => "text", "text" => ""}),
        delta(0, %{"type" => "text_delta", "text" => "part"}),
        %{
          "type" => "error",
          "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
        }
      ]

      assert Anthropic.stream(@request, config(stream_plug(events, self())), on_event()) ==
               {:error,
                {:api_error, %{status: nil, type: "overloaded_error", message: "Overloaded"}}}

      assert events() == [text_delta: "part"]
    end
  end

  describe "build_body/2" do
    test "omits system, tools, and effort when absent" do
      body =
        Anthropic.build_body(Request.new(messages: [Message.user("Hi")]),
          model: "m",
          max_tokens: 500
        )

      refute Map.has_key?(body, :system)
      refute Map.has_key?(body, :tools)
      refute Map.has_key?(body, :output_config)
      assert body.max_tokens == 500
    end

    test "requires a model" do
      assert_raise KeyError, fn -> Anthropic.build_body(@request, []) end
    end
  end

  describe "to_wire/1" do
    test "replays an assistant turn from raw blocks" do
      raw = [
        %{"type" => "thinking", "thinking" => "", "signature" => "s"},
        %{"type" => "text", "text" => "Hi"}
      ]

      assert Anthropic.to_wire(Message.assistant([{:text, "other"}], raw)) == %{
               role: "assistant",
               content: raw
             }
    end

    test "builds an assistant turn from parts when raw is absent or empty" do
      call = ToolCall.new("toolu_1", "who_is_on", %{"rotation" => "onc"})

      expected = %{
        role: "assistant",
        content: [
          %{type: "text", text: "Checking."},
          %{type: "tool_use", id: "toolu_1", name: "who_is_on", input: %{"rotation" => "onc"}}
        ]
      }

      assert Anthropic.to_wire(Message.assistant([{:text, "Checking."}, call])) == expected
      assert Anthropic.to_wire(Message.assistant([{:text, "Checking."}, call], [])) == expected
    end

    test "drops empty text and omits is_error on successful results" do
      message = %Message{role: :user, parts: [{:text, ""}, ToolResult.ok("toolu_1", "[]")]}

      assert Anthropic.to_wire(message) == %{
               role: "user",
               content: [%{type: "tool_result", tool_use_id: "toolu_1", content: "[]"}]
             }
    end
  end

  describe "retry?/2" do
    test "never retries exceptions" do
      refute Anthropic.retry?(%Req.Request{}, %Req.TransportError{reason: :timeout})
    end

    test "retries every server error status" do
      for status <- [429, 500, 502, 503, 504, 529] do
        assert Anthropic.retry?(%Req.Request{}, %Req.Response{status: status})
      end
    end
  end
end
