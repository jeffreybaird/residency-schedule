defmodule ResidencySchedule.Importer.Adapters.Csv do
  @moduledoc "Adapts the existing roster parser into domain import input."
  @behaviour ResidencySchedule.Importer.Adapter

  alias ResidencySchedule.Importer.{CsvParser, ImportDocument}
  alias ResidencySchedule.Importer.ImportDocument.Resident

  @doc """
  Parses roster replacement or literal date-update facts without writing records.

  A whole-year roster produces rotation blocks under domain resident input.
  Other source collections remain empty; the scope describes the covered roster
  positions and date ranges. This example uses a year outside the configured
  name roster so the supplied name is preserved.

      iex> csv = Enum.join([",Dates,2099-07-06", ",,2099-07-10", ",,", "R1-1,Iris Reed,GYN"], <<10>>)
      iex> {:ok, document} = ResidencySchedule.Importer.Adapters.Csv.parse(csv, [])
      iex> document
      %ResidencySchedule.Importer.ImportDocument{
        source: :csv,
        kind: :rotations,
        academic_year: 2099,
        residents: [
          %ResidencySchedule.Importer.ImportDocument.Resident{
            position_code: "R1-1",
            residency_year: 1,
            schedule_number: 1,
            name: "Iris Reed",
            rotations: [
              %{
                rotation_type: :strong_gynecology,
                start_date: ~D[2099-07-06],
                end_date: ~D[2099-07-10],
                slot_index: 0
              }
            ],
            date_updates: []
          }
        ],
        assignments: [],
        header_dates: [],
        notes: [],
        unlinked_notes: [],
        warnings: [],
        scope: %{
          completeness: :complete,
          record_kinds: [:rotations],
          people: ["R1-1"],
          dates: [~D[2099-07-06], ~D[2099-07-10]],
          date_ranges: [{~D[2099-07-06], ~D[2099-07-10]}]
        },
        preview_only: false
      }
  """
  @impl true
  def parse(binary, options) do
    mode = Keyword.get(options, :mode, :replace_year)

    with {:ok, residents, warnings} <- parse_mode(binary, mode, options),
         {:ok, year} <- academic_year(residents, mode, options) do
      {:ok,
       %ImportDocument{
         source: :csv,
         kind: :rotations,
         academic_year: year,
         residents: Enum.map(residents, &struct!(Resident, Map.from_struct(&1))),
         warnings: warnings,
         scope: scope(residents, mode)
       }}
    end
  end

  defp parse_mode(binary, :replace_year, _options), do: CsvParser.parse(binary)

  defp parse_mode(binary, :update_dates, options),
    do: CsvParser.parse_date_update(binary, Keyword.get(options, :academic_year))

  defp parse_mode(_binary, _mode, _options), do: {:error, "Unknown import mode"}

  defp academic_year(_residents, :update_dates, options),
    do: {:ok, Keyword.fetch!(options, :academic_year)}

  defp academic_year(residents, :replace_year, _options) do
    case boundary_dates(residents) do
      [] -> {:error, "No residents or rotations to import"}
      dates -> {:ok, CsvParser.derive_academic_year(dates)}
    end
  end

  defp scope(residents, mode) do
    %{
      completeness: if(mode == :replace_year, do: :complete, else: :partial),
      record_kinds: [:rotations],
      people: Enum.map(residents, & &1.position_code),
      dates: boundary_dates(residents),
      date_ranges: Enum.flat_map(residents, &resident_ranges/1)
    }
  end

  defp boundary_dates(residents) do
    residents
    |> Enum.flat_map(&resident_ranges/1)
    |> Enum.flat_map(fn {first, last} -> [first, last] end)
    |> Enum.uniq()
    |> Enum.sort(Date)
  end

  defp resident_ranges(resident) do
    entries = if resident.date_updates == [], do: resident.rotations, else: resident.date_updates
    Enum.map(entries, &{&1.start_date, &1.end_date})
  end
end
