defmodule ResidencySchedule.Importer.ImportDocument do
  @moduledoc """
  Format-independent source facts awaiting application reconciliation.

  Rotation blocks and dated activities remain separate kinds. Scope records
  completeness, people and record kinds; `date_ranges` preserves block extents
  while `dates` contains their boundary dates (or literal activity header dates).
  Source facts do not resolve identities or authorize writes. New adapters remain
  preview-only until their persistence policy is implemented separately.
  """

  defstruct source: nil,
            kind: nil,
            academic_year: nil,
            residents: [],
            assignments: [],
            header_dates: [],
            notes: [],
            unlinked_notes: [],
            warnings: [],
            scope: %{},
            preview_only: false

  @type t :: %__MODULE__{}
end
