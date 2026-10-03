defmodule ResidencySchedule.Importer.QgendaWorkbook do
  @moduledoc "Bounded, in-memory reader for QGenda's XLSX calendar exports."
  import Bitwise

  @limit 20_000_000

  @doc """
  Reads worksheet cells without executing formulas or resolving external resources.

      iex> {:ok, sheets} = ResidencySchedule.Importer.QgendaWorkbook.read(File.read!("test/fixtures/qgenda/shared.xlsx"))
      iex> hd(sheets).name
      "Page 1"
  """
  def read(binary) when is_binary(binary) and byte_size(binary) <= 5_000_000 do
    case :zip.table(binary) do
      {:ok, table} -> {:ok, read_sheets(extract_members(binary, table))}
      _ -> {:error, "The file is not a supported XLSX workbook."}
    end
  rescue
    _ -> {:error, "The workbook is invalid, unsafe, or exceeds the preview limits."}
  catch
    _, _ -> {:error, "The workbook is invalid, unsafe, or exceeds the preview limits."}
  end

  def read(_), do: {:error, "The workbook exceeds the 5 MB upload limit."}

  defp read_sheets(files) do
    workbook = parse_xml(Map.fetch!(files, "xl/workbook.xml"))
    relationships = parse_xml(Map.fetch!(files, "xl/_rels/workbook.xml.rels"))
    strings = read_shared_strings(files)
    relations = read_relationships(relationships)

    sheets =
      workbook
      |> descendants("sheet")
      |> Enum.map(fn sheet ->
        path = Map.fetch!(relations, sheet.attrs["id"])
        xml = files |> Map.fetch!(path) |> parse_xml()
        %{name: sheet.attrs["name"], rows: read_rows(xml, strings)}
      end)

    if sheets == [], do: raise(ArgumentError)
    sheets
  end

  defp extract_members(binary, table) do
    entries = Enum.filter(table, &(elem(&1, 0) == :zip_file))
    if length(entries) > 200, do: raise(ArgumentError)

    {files, _size} =
      Enum.reduce(entries, {%{}, 0}, fn {:zip_file, name, info, _, offset, compressed},
                                        {files, total} ->
        name = to_string(name)
        expected = elem(info, 1)
        if not safe_path?(name) or Map.has_key?(files, name), do: raise(ArgumentError)
        if total + expected > @limit, do: raise(ArgumentError)
        content = extract_member(binary, name, offset, compressed, @limit - total)
        if byte_size(content) != expected, do: raise(ArgumentError)
        {Map.put(files, name, content), total + byte_size(content)}
      end)

    files
  end

  defp extract_member(binary, name, offset, compressed, budget) do
    <<_::binary-size(offset), 0x04034B50::little-32, _version::little-16, flags::little-16,
      method::little-16, _time::little-16, _date::little-16, crc::little-32,
      _compressed::little-32, _size::little-32, name_size::little-16, extra_size::little-16,
      local_name::binary-size(name_size), _extra::binary-size(extra_size),
      payload::binary-size(compressed), _::binary>> = binary

    if local_name != name or (flags &&& bnot(0x080E)) != 0, do: raise(ArgumentError)
    content = inflate_member(method, payload, budget)
    if (flags &&& 8) == 0 and :erlang.crc32(content) != crc, do: raise(ArgumentError)
    content
  end

  defp inflate_member(0, payload, budget) when byte_size(payload) <= budget, do: payload

  defp inflate_member(8, payload, budget) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      result = bounded_inflate(z, :zlib.safeInflate(z, payload), budget, [])
      :ok = :zlib.inflateEnd(z)
      result
    after
      :zlib.close(z)
    end
  end

  defp inflate_member(_, _, _), do: raise(ArgumentError)

  defp bounded_inflate(z, {status, output}, budget, acc) when status in [:continue, :finished] do
    remaining = budget - IO.iodata_length(output)
    if remaining < 0, do: raise(ArgumentError)

    case status do
      :finished -> [output | acc] |> Enum.reverse() |> IO.iodata_to_binary()
      :continue -> bounded_inflate(z, :zlib.safeInflate(z, []), remaining, [output | acc])
    end
  end

  defp safe_path?(path) do
    not String.starts_with?(path, "/") and
      not String.contains?(path, ["\\", ":", <<0>>]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["..", "."]))
  end

  defp parse_xml(xml) do
    if not String.valid?(xml) or String.contains?(xml, <<0>>) or
         Regex.match?(~r/<!\s*(DOCTYPE|ENTITY)/i, xml),
       do: raise(ArgumentError)

    {:ok, %{stack: [], root: root}, rest} =
      :xmerl_sax_parser.stream(xml,
        event_fun: &xml_event/3,
        event_state: %{stack: [], root: nil, count: 0}
      )

    if root == nil or String.trim(to_string(rest)) != "", do: raise(ArgumentError)
    root
  end

  defp xml_event({:startElement, _, name, _, attributes}, _, state) do
    if length(state.stack) >= 64 or state.count >= 250_000, do: raise(ArgumentError)

    attrs =
      Map.new(attributes, fn {_, _, key, value} -> {to_string(key), to_string(value)} end)

    node = %{name: to_string(name), attrs: attrs, children: [], text: []}
    %{state | stack: [node | state.stack], count: state.count + 1}
  end

  defp xml_event({:characters, chars}, _, %{stack: [node | tail]} = state) do
    %{state | stack: [%{node | text: [to_string(chars) | node.text]} | tail]}
  end

  defp xml_event({:endElement, _, _, _}, _, %{stack: [node | tail]} = state) do
    node = %{
      node
      | children: Enum.reverse(node.children),
        text: node.text |> Enum.reverse() |> Enum.join()
    }

    case tail do
      [] -> %{state | stack: [], root: node}
      [parent | rest] -> %{state | stack: [%{parent | children: [node | parent.children]} | rest]}
    end
  end

  defp xml_event(event, _, state) when event in [:startDocument, :endDocument], do: state
  defp xml_event({:ignorableWhitespace, _}, _, state), do: state
  defp xml_event({:startPrefixMapping, _, _}, _, state), do: state
  defp xml_event({:endPrefixMapping, _}, _, state), do: state
  defp xml_event({:comment, _}, _, state), do: state
  defp xml_event(_, _, _), do: raise(ArgumentError)

  defp descendants(node, name) do
    own = if node.name == name, do: [node], else: []
    own ++ Enum.flat_map(node.children, &descendants(&1, name))
  end

  defp read_relationships(root) do
    root
    |> descendants("Relationship")
    |> Enum.reduce(%{}, fn node, acc ->
      id = node.attrs["Id"]
      target = node.attrs["Target"]

      if Map.has_key?(acc, id) or node.attrs["TargetMode"] == "External" or
           not is_binary(target) or not safe_path?(target),
         do: raise(ArgumentError)

      Map.put(acc, id, "xl/" <> target)
    end)
  end

  defp read_shared_strings(files) do
    case Map.get(files, "xl/sharedStrings.xml") do
      nil ->
        %{}

      xml ->
        xml
        |> parse_xml()
        |> descendants("si")
        |> Enum.with_index()
        |> Map.new(fn {node, index} -> {Integer.to_string(index), read_text(node)} end)
    end
  end

  defp read_text(node), do: node |> descendants("t") |> Enum.map_join(& &1.text)

  defp read_rows(root, strings) do
    {rows, _seen} =
      root
      |> descendants("row")
      |> Enum.map_reduce(MapSet.new(), fn row, seen ->
        Enum.map_reduce(row.children, seen, &read_unique_cell(&1, &2, strings))
      end)

    rows
  end

  defp read_unique_cell(cell, seen, strings) do
    reference = cell.attrs["r"]
    if MapSet.member?(seen, reference), do: raise(ArgumentError)
    {{reference, read_cell(cell, strings)}, MapSet.put(seen, reference)}
  end

  defp read_cell(cell, strings) do
    if descendants(cell, "f") != [], do: raise(ArgumentError)
    value = cell |> descendants("v") |> Enum.map_join(& &1.text)

    case cell.attrs["t"] do
      "s" -> Map.fetch!(strings, value)
      "inlineStr" -> read_text(cell)
      _ -> value
    end
  end
end
