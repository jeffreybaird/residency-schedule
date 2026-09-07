defmodule ResidencySchedule.Assistant.Chat.Providers.Anthropic do
  @moduledoc """
  Streams one turn through the Anthropic Messages API over Req.

  Config keys (under `config :residency_schedule, :chat`):

    * `:api_key` — required at call time; `{:error, :missing_api_key}` without it
    * `:model` — required, e.g. `"claude-sonnet-5"`
    * `:max_tokens` — default 16_000
    * `:effort` — optional `"low" | "medium" | "high" | "xhigh" | "max"`
    * `:base_url` — default `https://api.anthropic.com`
    * `:receive_timeout` — milliseconds, default 120_000
    * `:req_options` — merged into the Req client (tests pass `plug:` here)

  The system prompt carries the prompt-cache breakpoint, so tools and system
  are served from cache on every turn after the first. Assistant turns are
  replayed from their raw content blocks, so thinking blocks survive.
  """

  @behaviour ResidencySchedule.Assistant.Chat.Provider

  alias ResidencySchedule.Assistant.Chat.{Message, Request, Tool, ToolCall, ToolResult}
  alias ResidencySchedule.Assistant.Chat.Providers.Anthropic.{Accumulator, SSE}

  @default_base_url "https://api.anthropic.com"
  @api_version "2023-06-01"
  @default_max_tokens 16_000
  @default_receive_timeout 120_000
  @retry_statuses [429, 500, 502, 503, 504, 529]

  @doc """
  Streams the turn, emitting provider events as they arrive.

  Exempt from doctest — performs HTTP. See `AnthropicTest`.
  """
  @impl true
  def stream(%Request{} = request, config, on_event) when is_function(on_event, 1) do
    with {:ok, api_key} <- fetch_api_key(config) do
      config
      |> client(api_key)
      |> Req.post(url: "/v1/messages", json: build_body(request, config), into: collect(on_event))
      |> handle_response(on_event)
    end
  end

  @doc """
  Builds the JSON body for one turn.

      iex> alias ResidencySchedule.Assistant.Chat.{Message, Request, Tool}
      iex> tool = Tool.new("who_is_on", "Who is on a service", %{type: "object", properties: %{}})
      iex> request = Request.new(system: "You help with schedules.", messages: [Message.user("Hi")], tools: [tool])
      iex> body = ResidencySchedule.Assistant.Chat.Providers.Anthropic.build_body(request, model: "claude-sonnet-5", effort: "low")
      iex> {body.model, body.stream, body.output_config, hd(body.system).cache_control}
      {"claude-sonnet-5", true, %{effort: "low"}, %{type: "ephemeral"}}
  """
  def build_body(%Request{} = request, config) do
    %{
      model: Keyword.fetch!(config, :model),
      max_tokens: Keyword.get(config, :max_tokens, @default_max_tokens),
      stream: true,
      messages: Enum.map(request.messages, &to_wire/1)
    }
    |> put_system(request.system)
    |> put_tools(request.tools)
    |> put_effort(Keyword.get(config, :effort))
  end

  @doc """
  Converts a message to its Messages API form. Assistant turns with a raw
  payload are replayed verbatim.

      iex> alias ResidencySchedule.Assistant.Chat.{Message, ToolResult}
      iex> ResidencySchedule.Assistant.Chat.Providers.Anthropic.to_wire(Message.user("Hi"))
      %{role: "user", content: [%{type: "text", text: "Hi"}]}

      iex> alias ResidencySchedule.Assistant.Chat.{Message, ToolResult}
      iex> msg = Message.tool_results([ToolResult.error("toolu_1", "No such resident.")])
      iex> ResidencySchedule.Assistant.Chat.Providers.Anthropic.to_wire(msg)
      %{role: "user", content: [%{type: "tool_result", tool_use_id: "toolu_1", content: "No such resident.", is_error: true}]}
  """
  def to_wire(%Message{role: :assistant, raw: raw}) when is_list(raw) and raw != [] do
    %{role: "assistant", content: raw}
  end

  def to_wire(%Message{role: role, parts: parts}) do
    %{role: Atom.to_string(role), content: Enum.flat_map(parts, &part_to_wire/1)}
  end

  @doc """
  Converts a tool definition to its Messages API form.

      iex> alias ResidencySchedule.Assistant.Chat.Tool
      iex> tool = Tool.new("who_is_on", "Who is on a service", %{type: "object", properties: %{}})
      iex> ResidencySchedule.Assistant.Chat.Providers.Anthropic.tool_to_wire(tool)
      %{name: "who_is_on", description: "Who is on a service", input_schema: %{type: "object", properties: %{}}}
  """
  def tool_to_wire(%Tool{} = tool) do
    %{name: tool.name, description: tool.description, input_schema: tool.input_schema}
  end

  @doc """
  Whether Req should retry: only rate limits, overload, and server errors.
  Transport errors are never retried, since a stream may already have
  emitted events.

      iex> ResidencySchedule.Assistant.Chat.Providers.Anthropic.retry?(%Req.Request{}, %Req.Response{status: 529})
      true

      iex> ResidencySchedule.Assistant.Chat.Providers.Anthropic.retry?(%Req.Request{}, %Req.Response{status: 400})
      false
  """
  def retry?(_request, %Req.Response{status: status}), do: status in @retry_statuses
  def retry?(_request, _exception), do: false

  # ── Request ────────────────────────────────────────────────────────────────

  defp fetch_api_key(config) do
    case Keyword.get(config, :api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end

  defp client(config, api_key) do
    [
      base_url: Keyword.get(config, :base_url, @default_base_url),
      headers: [{"x-api-key", api_key}, {"anthropic-version", @api_version}],
      receive_timeout: Keyword.get(config, :receive_timeout, @default_receive_timeout),
      retry: &retry?/2,
      max_retries: 2,
      retry_log_level: :info
    ]
    |> Req.new()
    |> Req.merge(Keyword.get(config, :req_options, []))
  end

  defp put_system(body, ""), do: body

  defp put_system(body, system),
    do:
      Map.put(body, :system, [%{type: "text", text: system, cache_control: %{type: "ephemeral"}}])

  defp put_tools(body, []), do: body
  defp put_tools(body, tools), do: Map.put(body, :tools, Enum.map(tools, &tool_to_wire/1))

  defp put_effort(body, nil), do: body
  defp put_effort(body, effort), do: Map.put(body, :output_config, %{effort: effort})

  defp part_to_wire({:text, ""}), do: []
  defp part_to_wire({:text, text}), do: [%{type: "text", text: text}]

  defp part_to_wire(%ToolCall{} = call),
    do: [%{type: "tool_use", id: call.id, name: call.name, input: call.args}]

  defp part_to_wire(%ToolResult{error?: true} = result),
    do: [
      %{type: "tool_result", tool_use_id: result.call_id, content: result.content, is_error: true}
    ]

  defp part_to_wire(%ToolResult{} = result),
    do: [%{type: "tool_result", tool_use_id: result.call_id, content: result.content}]

  # ── Response ───────────────────────────────────────────────────────────────

  defp collect(on_event) do
    fn
      {:data, chunk}, {req, %Req.Response{status: 200} = resp} ->
        {:cont, {req, consume_chunk(resp, chunk, on_event)}}

      {:data, chunk}, {req, resp} ->
        {:cont, {req, Req.Response.update_private(resp, :error_body, chunk, &(&1 <> chunk))}}
    end
  end

  defp consume_chunk(resp, chunk, on_event) do
    {events, buffer} = SSE.parse(Req.Response.get_private(resp, :buffer, ""), chunk)

    acc =
      Enum.reduce(events, Req.Response.get_private(resp, :acc, Accumulator.new()), fn event,
                                                                                      acc ->
        apply_event(acc, SSE.decode(event), on_event)
      end)

    resp
    |> Req.Response.put_private(:buffer, buffer)
    |> Req.Response.put_private(:acc, acc)
  end

  defp apply_event(acc, {:ok, payload}, on_event) do
    {acc, emitted} = Accumulator.apply(acc, payload)
    Enum.each(emitted, on_event)
    acc
  end

  defp apply_event(acc, {:error, _bad_event}, _on_event), do: acc

  defp handle_response({:ok, %Req.Response{status: 200} = resp}, on_event) do
    resp
    |> Req.Response.get_private(:acc, Accumulator.new())
    |> Accumulator.finish()
    |> emit_done(on_event)
  end

  defp handle_response({:ok, %Req.Response{status: status} = resp}, _on_event) do
    {:error, api_error(status, Req.Response.get_private(resp, :error_body, ""))}
  end

  defp handle_response({:error, exception}, _on_event), do: {:error, {:transport, exception}}

  defp emit_done({:ok, message, meta}, on_event) do
    on_event.({:done, meta})
    {:ok, message, meta}
  end

  defp emit_done({:error, reason}, _on_event), do: {:error, reason}

  defp api_error(status, body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"type" => type, "message" => message}}} ->
        {:api_error, %{status: status, type: type, message: message}}

      _ ->
        {:api_error, %{status: status, type: nil, message: body}}
    end
  end
end
