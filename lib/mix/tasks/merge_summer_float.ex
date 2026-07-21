defmodule Mix.Tasks.MergeSummerFloat do
  use Mix.Task

  @shortdoc "Merges the early summer-float schedule onto 2025-2026 for a continuous timeline"

  @moduledoc """
  Reads `data/2025-2026.csv` and `data/2026-summer-float-early.csv`, replaces the
  June float region of 2025-2026 with the early summer-float columns, and writes
  `data/2025-2026-continuous.csv`.

  Overlapping dates where the two schedules disagree on a real (non-`FLOAT`) cell
  are printed as conflicts; the summer-float value wins in the output.

  Usage:

      mix merge_summer_float
  """

  alias ResidencySchedule.Importer.ScheduleMerger

  @base "2025-2026.csv"
  @addon "2026-summer-float-early.csv"
  @output "2025-2026-continuous.csv"

  def run(_args) do
    data_dir = Path.join(File.cwd!(), "data")
    base = data_dir |> Path.join(@base) |> File.read!()
    addon = data_dir |> Path.join(@addon) |> File.read!()

    case ScheduleMerger.merge(base, addon) do
      {:ok, %{csv: csv, conflicts: conflicts}} ->
        File.write!(Path.join(data_dir, @output), csv)
        report_conflicts(conflicts)
        Mix.shell().info("Wrote #{@output}")

      {:error, reason} ->
        Mix.raise("merge_summer_float failed: #{inspect(reason)}")
    end
  end

  defp report_conflicts([]), do: Mix.shell().info("No overlap conflicts.")

  defp report_conflicts(conflicts) do
    Mix.shell().info("#{length(conflicts)} overlap conflict(s) (summer-float value kept):")

    Enum.each(conflicts, fn %{
                              position_code: code,
                              name: name,
                              date: date,
                              base: base,
                              addon: addon
                            } ->
      Mix.shell().info(
        "  #{code} #{name} #{Date.to_iso8601(date)}: 2025-2026=#{base} -> float=#{addon}"
      )
    end)
  end
end
