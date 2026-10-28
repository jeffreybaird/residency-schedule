defmodule ResidencySchedule.Timings do
  @moduledoc """
  Additive timing precision for saved source occurrences.

  Each saved assignment records whether its source stated exact instants, a
  part of the day or only a date. A period label never establishes hours, and
  no stored date is adjusted. Existing importers, projections, calendar
  exports and assistant queries remain authoritative and do not consult this
  representation.
  """
  alias ResidencySchedule.Timings.{Backfill, Interpreter}

  @doc """
  Interprets stored timing facts without touching the database.

      iex> {:ok, result} = ResidencySchedule.Timings.interpret(%{date: ~D[2026-12-30], period: "PM"})
      iex> {result.source_date, result.precision, result.period}
      {~D[2026-12-30], :period, "PM"}

      iex> {:ok, result} = ResidencySchedule.Timings.interpret(%{date: ~D[2026-12-30], period: nil})
      iex> {result.precision, result.policy}
      {:date_only, "date_only"}
  """
  defdelegate interpret(facts), to: Interpreter

  @doc """
  Fills missing timing rows in restartable batches of 1–1000 (default 500).

  Existing rows are never updated: rows whose stored facts or rule version
  moved are reported as conflicting and retained, and reviewed/custom rows
  stay unchanged. No source record is rewritten.

      iex> _ctx = ResidencySchedule.TimingDoctestFixtures.source()
      iex> {:ok, counts} = ResidencySchedule.Timings.backfill(batch_size: 1)
      iex> {counts.processed, counts.period, counts.date_only, counts.unchanged}
      {1, 1, 0, 0}
  """
  def backfill(options \\ []), do: Backfill.run(options)
end
