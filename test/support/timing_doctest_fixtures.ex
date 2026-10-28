defmodule ResidencySchedule.TimingDoctestFixtures do
  @moduledoc "Explicit synthetic source occurrences for sandboxed timing metadata examples."

  alias ResidencySchedule.DetailedSchedules.Activity
  alias ResidencySchedule.IdentityMappingDoctestFixtures
  alias ResidencySchedule.Repo
  alias ResidencySchedule.TaskMappingDoctestFixtures

  @doc """
  Seeds one saved QGenda source occurrence whose stored period is `period`
  (default `"PM"`). Returns the fixture context with `:source`, `:activity`
  and `:batch`.
  """
  def source(period \\ "PM") do
    IdentityMappingDoctestFixtures.seed()
    |> add_source(period: period)
  end

  @doc """
  Seeds one saved source occurrence whose stored activity has no period.
  """
  def date_only_source do
    IdentityMappingDoctestFixtures.seed()
    |> add_source(period: nil)
  end

  @doc """
  Adds one saved source occurrence to `ctx` with an explicit stored period.

  Options: `:period` (default `"PM"`, may be `nil`), `:raw_task`
  (default `"SMH GYN R2 Day"`), `:date` (default December 30 of the fixture
  academic year) and `:source_kind` (default `"qgenda"`).
  """
  def add_source(ctx, options \\ []) do
    date = Keyword.get(options, :date, Date.new!(ctx.schedule.academic_year, 12, 30))
    raw_task = Keyword.get(options, :raw_task, "SMH GYN R2 Day")

    activity =
      Repo.insert!(%Activity{
        schedule_resident_id: ctx.member.id,
        date: date,
        raw_task: raw_task,
        period: Keyword.get(options, :period, "PM"),
        site: "SMH"
      })

    TaskMappingDoctestFixtures.add_source(ctx, raw_task,
      activity: activity,
      date: date,
      source_kind: Keyword.get(options, :source_kind, "qgenda")
    )
  end
end
