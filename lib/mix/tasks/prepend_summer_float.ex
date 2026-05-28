defmodule Mix.Tasks.PrependSummerFloat do
  use Mix.Task

  @shortdoc "Prepends the late summer-float schedule onto 2026-2027 for a continuous timeline"

  @moduledoc """
  Reads `data/2026-2027.csv` and `data/2026-summer-float-late.csv`, inserts the
  late summer-float columns (06-18 onward) ahead of 2026-2027's first date, and
  writes `data/2026-2027-continuous.csv`.

  Overlapping dates where the two schedules disagree on a real cell are printed as
  conflicts; the 2026-2027 value wins in the output.

  Usage:

      mix prepend_summer_float
  """

  alias ResidencySchedule.Importer.ScheduleMerger

  @base "2026-2027.csv"
  @addon "2026-summer-float-late.csv"
  @output "2026-2027-continuous.csv"

  def run(_args) do
    data_dir = Path.join(File.cwd!(), "data")
    base = data_dir |> Path.join(@base) |> File.read!()
    addon = data_dir |> Path.join(@addon) |> File.read!()

    case ScheduleMerger.prepend(base, addon) do
      {:ok, %{csv: csv, conflicts: conflicts}} ->
        File.write!(Path.join(data_dir, @output), csv)
        report_conflicts(conflicts)
        Mix.shell().info("Wrote #{@output}")

      {:error, reason} ->
        Mix.raise("prepend_summer_float failed: #{inspect(reason)}")
    end
  end

  defp report_conflicts([]), do: Mix.shell().info("No overlap conflicts.")

  defp report_conflicts(conflicts) do
    Mix.shell().info("#{length(conflicts)} overlap conflict(s) (2026-2027 value kept):")

    Enum.each(conflicts, fn %{position_code: code, name: name, date: date, base: base, addon: addon} ->
      Mix.shell().info("  #{code} #{name} #{Date.to_iso8601(date)}: float=#{addon} -> 2026-2027=#{base}")
    end)
  end
end
