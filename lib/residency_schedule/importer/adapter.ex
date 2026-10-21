defmodule ResidencySchedule.Importer.Adapter do
  @moduledoc "Contract for bounded source parsing without identity resolution or persistence."

  alias ResidencySchedule.Importer.ImportDocument

  @callback parse(binary(), keyword()) :: {:ok, ImportDocument.t()} | {:error, term()}
end
