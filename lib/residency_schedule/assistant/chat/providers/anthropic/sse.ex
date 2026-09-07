defmodule ResidencySchedule.Assistant.Chat.Providers.Anthropic.SSE do
  @moduledoc """
  Incremental Server-Sent Events parser. Feed it chunks as they arrive; it
  returns complete events and keeps the unfinished tail as the new buffer.
  """

  @type event :: %{event: String.t(), data: String.t()}

  @doc """
  Parses the buffered bytes plus a new chunk into complete events.

      iex> chunk = "event: ping\\ndata: {\\"type\\": \\"ping\\"}\\n\\nevent: message_stop\\ndata: {\\"type\\": \\"mes"
      iex> {events, rest} = ResidencySchedule.Assistant.Chat.Providers.Anthropic.SSE.parse("", chunk)
      iex> {Enum.map(events, & &1.event), rest}
      {["ping"], "event: message_stop\\ndata: {\\"type\\": \\"mes"}
  """
  def parse(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    {complete, rest} = split_blocks(buffer <> chunk)
    {Enum.flat_map(complete, &parse_block/1), rest}
  end

  @doc """
  Decodes one event's JSON payload.

      iex> event = %{event: "ping", data: ~s({"type": "ping"})}
      iex> ResidencySchedule.Assistant.Chat.Providers.Anthropic.SSE.decode(event)
      {:ok, %{"type" => "ping"}}
  """
  def decode(%{data: data}) do
    case Jason.decode(data) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, {:bad_event, data}}
    end
  end

  defp split_blocks(data) do
    data
    |> String.split(~r/\r?\n\r?\n/)
    |> List.pop_at(-1)
    |> swap()
  end

  defp swap({rest, complete}), do: {complete, rest}

  defp parse_block(block) do
    block
    |> String.split(~r/\r?\n/)
    |> Enum.reduce(%{event: "message", data: []}, &apply_line/2)
    |> finish_block()
  end

  defp apply_line(":" <> _comment, acc), do: acc
  defp apply_line("event:" <> value, acc), do: %{acc | event: strip_space(value)}
  defp apply_line("data:" <> value, acc), do: %{acc | data: [strip_space(value) | acc.data]}
  defp apply_line(_other, acc), do: acc

  defp strip_space(value), do: String.replace_prefix(value, " ", "")

  defp finish_block(%{data: []}), do: []

  defp finish_block(%{event: event, data: data}),
    do: [%{event: event, data: Enum.join(Enum.reverse(data), "\n")}]
end
