defmodule ResidencySchedule.Importer.ImportDocument.Resident do
  @moduledoc "Domain input for one roster membership, independent of any file parser."

  defstruct [
    :position_code,
    :residency_year,
    :schedule_number,
    :name,
    :rotations,
    date_updates: []
  ]
end
