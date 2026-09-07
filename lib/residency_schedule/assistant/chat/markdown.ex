defmodule ResidencySchedule.Assistant.Chat.Markdown do
  @moduledoc """
  Renders the subset of Markdown the assistant uses into safe HTML:
  paragraphs, bullet and numbered lists, headings, bold, italic, and
  inline code. Every character of input is HTML-escaped before any tag is
  added, so text the model echoes from tool results can never inject
  markup. Anything outside the subset renders as literal text.
  """

  @bullet ~r/^\s*[-*]\s+(.*)$/
  @numbered ~r/^\s*\d+[.)]\s+(.*)$/
  @heading ~r/^\s*\#{1,6}\s+(.*)$/
  @code_span ~r/(`[^`]+`)/
  @bold ~r/\*\*(.+?)\*\*/
  @italic ~r/(?<![\w*])[*_]([^*_]+?)[*_](?![\w*])/

  @doc """
  Renders Markdown text to a `Phoenix.HTML` safe value.

      iex> alias ResidencySchedule.Assistant.Chat.Markdown
      iex> Markdown.to_html("Nora is on **onc**.\\n\\n- Clare: strong OB\\n- Mary: NF") |> Phoenix.HTML.safe_to_string()
      "<p>Nora is on <strong>onc</strong>.</p><ul><li>Clare: strong OB</li><li>Mary: NF</li></ul>"
  """
  def to_html(text) when is_binary(text) do
    text
    |> String.split(~r/\r?\n/)
    |> group_blocks()
    |> Enum.map_join(&render_block/1)
    |> Phoenix.HTML.raw()
  end

  @doc """
  Renders inline Markdown (bold, italic, code) in one line of escaped text.

      iex> ResidencySchedule.Assistant.Chat.Markdown.render_inline("call `whoami` for **me** or _my_")
      "call <code>whoami</code> for <strong>me</strong> or <em>my</em>"
  """
  def render_inline(line) do
    @code_span
    |> Regex.split(line, include_captures: true)
    |> Enum.map_join(&render_segment/1)
  end

  # ── Blocks ─────────────────────────────────────────────────────────────────

  defp group_blocks(lines) do
    lines
    |> Enum.map(&classify_line/1)
    |> Enum.chunk_by(&block_kind/1)
    |> Enum.reject(&(block_kind(hd(&1)) == :blank))
    |> Enum.flat_map(&split_headings/1)
  end

  defp classify_line(line) do
    cond do
      String.trim(line) == "" -> {:blank, ""}
      match = Regex.run(@bullet, line) -> {:bullet, Enum.at(match, 1)}
      match = Regex.run(@numbered, line) -> {:numbered, Enum.at(match, 1)}
      match = Regex.run(@heading, line) -> {:heading, Enum.at(match, 1)}
      true -> {:text, String.trim(line)}
    end
  end

  defp block_kind({kind, _content}), do: kind

  # Headings are one line each; consecutive headings must not merge.
  defp split_headings([{:heading, _} | _] = lines), do: Enum.map(lines, &[&1])
  defp split_headings(lines), do: [lines]

  defp render_block([{:bullet, _} | _] = items), do: render_list("ul", items)
  defp render_block([{:numbered, _} | _] = items), do: render_list("ol", items)
  defp render_block([{:heading, text}]), do: "<h4>" <> render_inline(escape(text)) <> "</h4>"

  defp render_block([{:text, _} | _] = lines) do
    "<p>" <>
      Enum.map_join(lines, "<br>", fn {:text, text} -> render_inline(escape(text)) end) <> "</p>"
  end

  defp render_list(tag, items) do
    "<#{tag}>" <> Enum.map_join(items, &render_item/1) <> "</#{tag}>"
  end

  defp render_item({_kind, text}), do: "<li>" <> render_inline(escape(text)) <> "</li>"

  # ── Inline ─────────────────────────────────────────────────────────────────

  defp render_segment("`" <> rest) do
    "<code>" <> String.trim_trailing(rest, "`") <> "</code>"
  end

  defp render_segment(segment) do
    segment
    |> String.replace(@bold, "<strong>\\1</strong>")
    |> String.replace(@italic, "<em>\\1</em>")
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
