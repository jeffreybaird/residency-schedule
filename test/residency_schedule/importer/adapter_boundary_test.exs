defmodule ResidencySchedule.Importer.AdapterBoundaryTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Importer.Adapters.{Csv, Json, Qgenda}
  alias ResidencySchedule.Importer.{CsvParser, ImportDocument, QgendaParser}

  doctest Csv
  doctest Qgenda
  doctest Json

  test "CSV adapter preserves parsed facts while returning format-independent resident input" do
    binary = File.read!("test/fixtures/sample.csv")
    assert {:ok, parsed, warnings} = CsvParser.parse(binary)
    assert {:ok, document} = Csv.parse(binary, [])
    assert is_struct(document, ImportDocument)
    assert document.source == :csv
    assert document.kind == :rotations
    assert document.warnings == warnings
    assert document.scope.completeness == :complete
    assert document.scope.record_kinds == [:rotations]
    assert document.assignments == []

    assert Enum.map(document.residents, &Map.from_struct/1) ==
             Enum.map(parsed, &Map.from_struct/1)

    assert Enum.all?(document.residents, &is_struct(&1, ImportDocument.Resident))
    refute Enum.any?(document.residents, &is_struct(&1, CsvParser))
  end

  test "CSV date patches retain OFF, blank and unknown distinctions and literal night dates" do
    binary =
      Enum.join(
        [
          ",Dates,2026-12-14,2026-12-15,2026-12-16,2026-12-17",
          ",,2026-12-14,2026-12-15,2026-12-16,2026-12-17",
          ",,,,,",
          "R1-1,Iris Reed,HNF,,Mystery Service,OFF"
        ],
        "\n"
      )

    assert {:ok, parsed, warnings} = CsvParser.parse_date_update(binary, 2026)
    assert {:ok, document} = Csv.parse(binary, mode: :update_dates, academic_year: 2026)
    assert document.academic_year == 2026
    assert document.scope.completeness == :partial
    assert document.warnings == warnings
    assert {"R1-1", 2, "Mystery Service"} in warnings
    assert Map.from_struct(hd(document.residents)) == Map.from_struct(hd(parsed))
    assert hd(hd(document.residents).rotations).start_date == ~D[2026-12-14]
  end

  test "CSV adapter preserves parser failures and rejects unsupported modes" do
    assert {:error, _} = Csv.parse("", [])
    assert {:error, _} = Csv.parse("", mode: :unsupported)
    assert {:error, _} = Csv.parse("", mode: :update_dates)
  end

  test "QGenda adapter preserves simultaneous duties, notes, unknown labels and source facts" do
    binary = File.read!("test/fixtures/qgenda/shared.xlsx")
    assert {:ok, parsed} = QgendaParser.parse(binary)
    assert {:ok, document} = Qgenda.parse(binary, academic_year: 2026)
    assert is_struct(document, ImportDocument)
    assert document.source == :qgenda
    assert document.kind == :activities
    assert document.academic_year == 2026
    assert document.scope.completeness == :partial
    assert document.scope.record_kinds == [:activities]
    assert document.residents == []
    assert document.assignments == parsed.assignments
    assert document.header_dates == parsed.header_dates
    assert document.notes == parsed.notes
    assert document.unlinked_notes == parsed.unlinked_notes
    assert Enum.any?(document.assignments, &(&1.raw_task == "Mystery Service"))
    assert length(Enum.filter(document.assignments, &(&1.date == ~D[2026-12-28]))) > 1
    assert {:error, _} = Qgenda.parse("not a workbook", academic_year: 2026)
  end

  test "JSON activity input preserves literal labels, simultaneous activities and notes" do
    assert {:ok, document} = Json.parse(json(), [])
    assert is_struct(document, ImportDocument)
    assert document.source == :json
    assert document.kind == :activities
    assert document.academic_year == 2026
    assert document.scope.completeness == :partial
    assert document.scope.record_kinds == [:activities]
    assert document.preview_only
    assert document.header_dates == [~D[2026-12-28], ~D[2026-12-29]]
    assert Enum.map(document.assignments, & &1.raw_task) == ["Mystery Service", "Clinic AM"]
    assert Enum.map(document.assignments, & &1.date) == [~D[2026-12-28], ~D[2026-12-28]]
    assert hd(document.assignments).notes == ["Bring kit"]
    assert hd(document.assignments).source_cell == "entry-1"
    assert hd(document.assignments).source_sheet == "custom"
  end

  test "JSON rejects malformed structures, invalid dates, year conflicts and unsupported modes" do
    invalid = [
      "{",
      "[]",
      Jason.encode!(%{academic_year: 2026, assignments: "wrong"}),
      Jason.encode!(%{academic_year: 2026, assignments: [%{date: "2026-02-30"}]}),
      Jason.encode!(%{
        academic_year: 2026,
        assignments: [%{date: "2026-12-28", raw_staff: 12, raw_task: "Clinic"}]
      }),
      Jason.encode!(%{
        academic_year: 2026,
        assignments: [
          %{date: "2026-12-28", raw_staff: "Iris Reed", raw_task: "Clinic", notes: [12]}
        ]
      })
    ]

    for binary <- invalid, do: assert({:error, _} = Json.parse(binary, []))
    assert {:error, _} = Json.parse(json(), academic_year: 2025)
    assert {:error, _} = Json.parse(json(), mode: :replace_year)
    assert {:error, _} = Json.parse(json(), mode: :unsupported)
  end

  test "JSON applies bounded input and record limits before preview" do
    assert {:error, _} = Json.parse(String.duplicate(" ", 5_000_001), [])
    assignment = %{date: "2026-12-28", raw_staff: "Iris Reed", raw_task: "Clinic"}

    binary =
      Jason.encode!(%{academic_year: 2026, assignments: List.duplicate(assignment, 10_001)})

    assert {:error, _} = Json.parse(binary, [])
  end

  test "JSON validates its year, header dates and note metadata without exceptions" do
    payload = Jason.decode!(json())

    for year <- [nil, "2026", 0, -1, 9999] do
      assert {:error, _} = Json.parse(Jason.encode!(Map.put(payload, "academic_year", year)), [])
    end

    for {key, value} <- [
          {"header_dates", "2026-12-28"},
          {"header_dates", ["not a date"]},
          {"notes", "not a list"},
          {"notes", [12]},
          {"notes", [%{"text" => 12}]},
          {"unlinked_notes", "not a list"}
        ] do
      assert {:error, _} = Json.parse(Jason.encode!(Map.put(payload, key, value)), [])
    end

    assert {:error, _} = Json.parse(nil, [])
    assert {:error, _} = Json.parse(Jason.encode!(%{academic_year: 2026, assignments: []}), [])
  end

  test "JSON header dates include all assignments even when explicit headers omit them" do
    payload = Jason.decode!(json())

    for headers <- [[], ["2026-12-29"], ["2026-12-29", "2026-12-29"]] do
      assert {:ok, document} =
               Json.parse(Jason.encode!(Map.put(payload, "header_dates", headers)), [])

      expected =
        [~D[2026-12-28] | Enum.map(headers, &Date.from_iso8601!/1)]
        |> Enum.uniq()
        |> Enum.sort(Date)

      assert document.header_dates == expected
      assert document.scope.dates == expected
    end
  end

  test "JSON retains standalone notes as reviewable unlinked notes" do
    note = %{"text" => "Ask coordinator", "source_sheet" => "custom", "source_cell" => "note-1"}
    payload = json() |> Jason.decode!() |> Map.put("notes", [note])
    assert {:ok, document} = Json.parse(Jason.encode!(payload), [])
    assert hd(document.notes).text == "Ask coordinator"
    assert hd(document.unlinked_notes).text == "Ask coordinator"
    assert hd(document.notes).source_cell == "note-1"
    assert hd(document.notes).source_sheet == "custom"
  end

  test "JSON parsing does not intern arbitrary uploaded labels or object keys" do
    assert {:ok, _} = Json.parse(json(), [])
    suffix = Integer.to_string(System.unique_integer([:positive]))
    task = "unknown_task_" <> suffix
    key = "unknown_key_" <> suffix

    binary =
      Jason.encode!(%{
        "academic_year" => 2026,
        "assignments" => [
          %{
            "date" => "2026-12-28",
            "raw_staff" => "Iris Reed",
            "raw_task" => task,
            key => "value"
          }
        ]
      })

    # Either preserve or reject unrecognized metadata; neither path may create atoms.
    Json.parse(binary, [])
    assert_raise ArgumentError, fn -> String.to_existing_atom(task) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end

  defp json do
    Jason.encode!(%{
      academic_year: 2026,
      header_dates: ["2026-12-28", "2026-12-29"],
      assignments: [
        %{
          date: "2026-12-28",
          raw_staff: "Iris Reed",
          raw_task: "Mystery Service",
          notes: ["Bring kit"],
          source_cell: "entry-1",
          source_sheet: "custom"
        },
        %{
          date: "2026-12-28",
          raw_staff: "Iris Reed",
          raw_task: "Clinic AM",
          notes: [],
          source_cell: "entry-2",
          source_sheet: "custom"
        }
      ]
    })
  end
end
