defmodule ResidencySchedule.Importer.QgendaNoteSectionsTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Importer.QgendaParser

  test "assignment tags terminate notes without discarding genuine orphan notes" do
    workbook = File.read!("test/fixtures/qgenda/shared.xlsx")
    {:ok, entries} = :zip.extract(workbook, [:memory])

    entries =
      Enum.map(entries, fn
        {~c"xl/sharedStrings.xml" = name, xml} ->
          xml =
            xml
            |> String.replace("Phone Numbers:", "Assignment Tags")
            |> String.replace("Reed, Iris 555-0100", "Synthetic Tag Metadata")
            |> String.replace(
              "Reed, Iris SMH GYN R2 Day Coverage discussion",
              "Reed, Unknown SMH GYN R2 Day Coverage discussion"
            )

          {name, xml}

        entry ->
          entry
      end)

    {:ok, {_, binary}} = :zip.create(~c"sections.xlsx", entries, [:memory])
    assert {:ok, parsed} = QgendaParser.parse(binary)
    assert Enum.any?(parsed.unlinked_notes, &String.contains?(&1.text, "Coverage discussion"))
    assert Enum.any?(parsed.assignments, &("Bring simulation kit" in &1.notes))
    refute inspect(parsed.notes) =~ "Synthetic Tag Metadata"
    refute inspect(parsed.unlinked_notes) =~ "Synthetic Tag Metadata"
    refute inspect(parsed.notes) =~ "Assignment Tags"
    refute inspect(parsed.unlinked_notes) =~ "Assignment Tags"
  end
end
