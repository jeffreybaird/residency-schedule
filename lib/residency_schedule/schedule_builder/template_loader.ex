defmodule ResidencySchedule.ScheduleBuilder.TemplateLoader do
  @moduledoc """
  Loads the schedule rotation template from `priv/templates/schedule_template.csv`.

  The template is the 2025–2026 schedule with real names stripped (replaced by
  position codes) and individual-specific absences (LOA) cleared. It defines the
  rotation pattern for each resident position across all 100 slots.

  When generating a schedule for a new academic year, this pattern is applied to
  that year's slot calendar — same slot_indices, new dates.
  """

  alias ResidencySchedule.Importer.CsvParser

  @doc """
  Returns the template rotation pattern grouped by position code.

  Each entry maps a list of `{slot_index, rotation_type}` tuples to a position
  code string. Slots where the template has no assignment (blank cells, LOA,
  or unknown values) are omitted.

      iex> pattern = ResidencySchedule.ScheduleBuilder.TemplateLoader.load_pattern()
      iex> is_map(pattern)
      true
      iex> Map.has_key?(pattern, "R1-1")
      true
  """
  def load_pattern do
    template_path()
    |> File.read!()
    |> CsvParser.parse()
    |> build_pattern_map()
  end

  # --- Private ---

  defp template_path do
    case :code.priv_dir(:residency_schedule) do
      {:error, _} ->
        # Fallback for development — relative to project root
        Path.join([File.cwd!(), "priv", "templates", "schedule_template.csv"])

      priv_dir ->
        Path.join([to_string(priv_dir), "templates", "schedule_template.csv"])
    end
  end

  defp build_pattern_map({:ok, residents, _warnings}) do
    Map.new(residents, fn resident ->
      slot_pairs =
        Enum.map(resident.rotations, fn r -> {r.slot_index, r.rotation_type} end)

      {resident.position_code, slot_pairs}
    end)
  end

  defp build_pattern_map({:error, _reason}), do: %{}
end
