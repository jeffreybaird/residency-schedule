defmodule ResidencySchedule.Importer.Adapters.Qgenda do
  @moduledoc "Adapts literal QGenda activity facts without changing parser semantics."
  @behaviour ResidencySchedule.Importer.Adapter

  alias ResidencySchedule.Importer.{ImportDocument, QgendaParser}

  @doc """
  Parses an XLSX calendar as a partial activity document.

      iex> binary = File.read!("test/fixtures/qgenda/shared.xlsx")
      iex> {:ok, document} = ResidencySchedule.Importer.Adapters.Qgenda.parse(binary, academic_year: 2026)
      iex> document.kind
      :activities
  """
  @impl true
  def parse(binary, options) do
    with {:ok, parsed} <- QgendaParser.parse(binary) do
      {:ok,
       struct!(
         ImportDocument,
         Map.merge(parsed, %{
           source: :qgenda,
           kind: :activities,
           academic_year: Keyword.get(options, :academic_year),
           scope: %{
             completeness: :partial,
             record_kinds: [:activities],
             dates: parsed.header_dates,
             people: parsed.assignments |> Enum.map(& &1.raw_staff) |> Enum.uniq()
           }
         })
       )}
    end
  end
end
