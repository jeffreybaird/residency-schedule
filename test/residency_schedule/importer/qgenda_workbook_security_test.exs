defmodule ResidencySchedule.Importer.QgendaWorkbookSecurityTest do
  use ExUnit.Case, async: true
  alias ResidencySchedule.Importer.QgendaWorkbook

  test "duplicate ZIP members are rejected" do
    entries = entries()
    assert_rejected([hd(entries) | entries])
  end

  test "duplicate worksheet cell coordinates are rejected" do
    mutate("xl/worksheets/sheet1.xml", fn xml ->
      String.replace(
        xml,
        "</sheetData>",
        "<row r=\"100\"><c r=\"B6\" t=\"inlineStr\"><is><t>Conflicting assignment</t></is></c></row></sheetData>"
      )
    end)
    |> assert_rejected()
  end

  test "external worksheet relationships are rejected" do
    mutate("xl/_rels/workbook.xml.rels", fn xml ->
      String.replace(
        xml,
        "Target=\"worksheets/sheet1.xml\"",
        "TargetMode=\"External\" Target=\"https://example.invalid/worksheet.xml\""
      )
    end)
    |> assert_rejected()
  end

  test "duplicate relationship IDs are rejected" do
    mutate("xl/_rels/workbook.xml.rels", fn xml ->
      String.replace(
        xml,
        "</Relationships>",
        "<Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/></Relationships>"
      )
    end)
    |> assert_rejected()
  end

  test "formulas are rejected even when a cached value exists" do
    mutate("xl/worksheets/sheet1.xml", fn xml ->
      String.replace(
        xml,
        "<c r=\"B6\" t=\"s\">",
        "<c r=\"B6\" t=\"s\"><f>HYPERLINK(\"https://example.invalid\")</f>"
      )
    end)
    |> assert_rejected()
  end

  test "excessively nested XML is rejected before constructing an unbounded tree" do
    mutate("xl/sharedStrings.xml", fn _ ->
      String.duplicate("<node>", 70) <> "text" <> String.duplicate("</node>", 70)
    end)
    |> assert_rejected()
  end

  test "UTF16 entity-bearing XML is rejected" do
    mutate("xl/sharedStrings.xml", fn _ ->
      xml =
        "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE s [<!ENTITY payload SYSTEM 'file:///not-a-real-secret'>]><s>&payload;</s>"

      <<255, 254>> <> :unicode.characters_to_binary(xml, :utf8, {:utf16, :little})
    end)
    |> assert_rejected()
  end

  defp entries do
    {:ok, entries} = :zip.extract(File.read!("test/fixtures/qgenda/shared.xlsx"), [:memory])
    entries
  end

  defp mutate(path, fun) do
    Enum.map(entries(), fn {name, content} ->
      {name, if(to_string(name) == path, do: fun.(content), else: content)}
    end)
  end

  defp assert_rejected(entries) do
    {:ok, {_, binary}} = :zip.create(~c"unsafe.xlsx", entries, [:memory])
    assert {:error, reason} = QgendaWorkbook.read(binary)
    assert is_binary(reason)
  end
end
