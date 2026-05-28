defmodule Mix.Tasks.SplitSummerFloat do
  use Mix.Task

  @shortdoc "Splits data/2026-summer-float.csv into early/late importable CSVs"

  @moduledoc """
  Reads `data/2026-summer-float.csv`, splits it at the graduating R4s' last day
  (`2026-06-17`), and writes two importable schedule CSVs:

    * `data/2026-summer-float-early.csv` — dates through the cutoff, rostered as
      the outgoing academic year (graduating R4s kept, interns dropped); and
    * `data/2026-summer-float-late.csv` — dates after the cutoff, rostered as the
      incoming academic year (graduating R4s dropped, interns kept).

  Usage:

      mix split_summer_float
  """

  alias ResidencySchedule.Importer.SummerFloatSplitter

  @input "2026-summer-float.csv"
  @early "2026-summer-float-early.csv"
  @late "2026-summer-float-late.csv"

  def run(_args) do
    data_dir = Path.join(File.cwd!(), "data")

    case data_dir |> Path.join(@input) |> File.read!() |> SummerFloatSplitter.split() do
      {:ok, %{early: early, late: late}} ->
        File.write!(Path.join(data_dir, @early), early)
        File.write!(Path.join(data_dir, @late), late)
        Mix.shell().info("Wrote #{@early} and #{@late}")

      {:error, reason} ->
        Mix.raise("split_summer_float failed: #{inspect(reason)}")
    end
  end
end
